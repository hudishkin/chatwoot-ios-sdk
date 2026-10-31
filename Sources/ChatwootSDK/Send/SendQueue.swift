import Combine
import Foundation
import UniformTypeIdentifiers

actor SendQueue {
    enum ContactVerdict {
        case healthy, stale, unknown
    }

    private let api: ChatwootAPI
    private let inboxIdentifier: String
    private let inboxId: Int
    private let store: SessionStore
    private let pendingDAO: PendingDAO
    private let messageDAO: MessageDAO
    private let conversationDAO: ConversationDAO
    private let sync: SyncManager
    private let sessionGuard: SessionGuard
    private let attachmentsDir: URL
    private let now: () -> UInt64
    private let newEchoId: () -> String
    private let tracker: InFlightTracker
    private let contactCheck: (Session) async -> ContactVerdict
    private let realtimeLive: () -> Bool
    private let fileManager: FileManager

    private var generation: SessionGeneration { sync.generation }

    nonisolated var inFlight: CurrentValueSubject<Set<String>, Never> { tracker.sending }

    private let outbox: AsyncStream<Dispatch>.Continuation
    private let outboxStream: AsyncStream<Dispatch>
    private var recoveryTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?

    init(
        api: ChatwootAPI,
        inboxIdentifier: String,
        inboxId: Int,
        store: SessionStore,
        pendingDAO: PendingDAO,
        messageDAO: MessageDAO,
        conversationDAO: ConversationDAO,
        sync: SyncManager,
        sessionGuard: SessionGuard,
        attachmentsDir: URL,
        now: @escaping () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) },
        newEchoId: @escaping () -> String = { UUID().uuidString },
        tracker: InFlightTracker = InFlightTracker(),
        contactCheck: @escaping (Session) async -> ContactVerdict = { _ in .unknown },
        realtimeLive: @escaping () -> Bool = { false },
        fileManager: FileManager = .default
    ) {
        self.api = api
        self.inboxIdentifier = inboxIdentifier
        self.inboxId = inboxId
        self.store = store
        self.pendingDAO = pendingDAO
        self.messageDAO = messageDAO
        self.conversationDAO = conversationDAO
        self.sync = sync
        self.sessionGuard = sessionGuard
        self.attachmentsDir = attachmentsDir
        self.now = now
        self.newEchoId = newEchoId
        self.tracker = tracker
        self.contactCheck = contactCheck
        self.realtimeLive = realtimeLive
        self.fileManager = fileManager

        var continuation: AsyncStream<Dispatch>.Continuation!
        let stream = AsyncStream<Dispatch> { continuation = $0 }
        self.outbox = continuation
        self.outboxStream = stream
        self.recoveryTask = nil
        self.consumerTask = nil
    }

    func start() {
        guard consumerTask == nil else { return }
        recoveryTask = Task { [weak self] in
            await self?.runRecovery()
        }
        consumerTask = Task { [weak self, outboxStream] in
            for await item in outboxStream {
                await self?.process(item)
            }
            self?.tracker.clear()
        }
    }

    deinit {
        recoveryTask?.cancel()
        consumerTask?.cancel()
    }

    func enqueueText(_ text: String, kind: StoredPendingMessage.Kind = .text, conversationAttributes: [String: JSONValue]? = nil) async {
        let owner = generation.current
        await recoveryTask?.value
        let echoId = newEchoId()
        let row = StoredPendingMessage(
            echoId: echoId, conversationId: nil, content: text, attachmentPath: nil, attachmentMime: nil,
            kind: kind, state: .queued, createdAt: nowSeconds(),
            conversationAttributes: Self.attributesString(conversationAttributes), posted: false
        )
        guard insert(owner: owner, row: row) else { return }
        CWLog.i(.send, "enqueue echo=\(echoId) kind=\(kind.rawValue)")
        dispatch(Dispatch(echoId: echoId, retry: false, owner: owner))
    }

    @discardableResult
    func enqueueFile(
        url: URL,
        mime: String?,
        conversationAttributes: [String: JSONValue]? = nil,
        caption: String? = nil,
        owner: Int? = nil
    ) async -> Result<Void, ChatwootError> {
        let owner = owner ?? generation.current
        await recoveryTask?.value
        guard generation.isCurrent(owner) else {
            CWLog.w(.send, "enqueue dropped kind=file: local data was reset")
            return .failure(.unknown)
        }
        let echoId = newEchoId()
        let prepared = prepare(url: url, mime: mime, echoId: echoId)
        switch prepared {
        case .rejected(let error):
            CWLog.w(.send, "rejected echo=\(echoId) \(error.logLabel)")
            return .failure(error)
        case .ready(let fileURL, let readyMime):
            let captionText = caption?.isEmpty == false ? caption : nil
            let row = StoredPendingMessage(
                echoId: echoId, conversationId: nil, content: captionText ?? nil, attachmentPath: fileURL.path,
                attachmentMime: readyMime, kind: .text, state: .queued, createdAt: nowSeconds(),
                conversationAttributes: Self.attributesString(conversationAttributes), posted: false
            )
            guard insert(owner: owner, row: row) else {
                discard(echoId)
                return .failure(.unknown)
            }
            CWLog.i(.send, "enqueue echo=\(echoId) kind=file")
            dispatch(Dispatch(echoId: echoId, retry: false, owner: owner))
            return .success(())
        }
    }

    func retry(_ echoId: String) async {
        let owner = generation.current
        await recoveryTask?.value
        let queued: Bool
        do {
            queued = try generation.ifCurrent(owner) { () throws -> Bool in
                guard let pending = try pendingDAO.get(echoId),
                      Self.retryable.contains(pending.state),
                      !tracker.isSending(echoId) else { return false }
                try pendingDAO.setState(echoId, state: .queued)
                return true
            } ?? false
        } catch {
            CWLog.w(.send, "retry read failed echo=\(echoId)")
            return
        }
        guard queued else { return }
        CWLog.i(.send, "retry echo=\(echoId)")
        dispatch(Dispatch(echoId: echoId, retry: true, owner: owner))
    }

    // MARK: - Recovery

    private func runRecovery() async {
        do {
            let failed = try pendingDAO.markQueuedAsFailed()
            if failed > 0 { CWLog.w(.send, "restart: \(failed) queued became failed") }
            try sweepOrphanAttachments()
        } catch {
            CWLog.w(.send, "restart recovery failed \(type(of: error))")
        }
    }

    private func sweepOrphanAttachments() throws {
        let known = Set(try pendingDAO.getAll().map(\.echoId))
        let entries = (try? fileManager.contentsOfDirectory(at: attachmentsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var orphans = 0
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory && !known.contains(entry.lastPathComponent) {
                try? fileManager.removeItem(at: entry)
                orphans += 1
            }
        }
        if orphans > 0 { CWLog.i(.send, "restart: \(orphans) orphan attachment dirs deleted") }
    }

    private func dispatch(_ item: Dispatch) {
        tracker.markSending(item.echoId)
        outbox.yield(item)
    }

    private func process(_ item: Dispatch) async {
        let started = now()
        let echoId = item.echoId
        switch await attempt(echoId, retry: item.retry, owner: item.owner) {
        case .delivered:
            tracker.markDelivered(echoId)
            CWLog.i(.send, "ack echo=\(echoId) via=rest ms=\(now() - started)")
        case .duplicate:
            tracker.markDelivered(echoId)
            CWLog.i(.send, "duplicate found echo=\(echoId), not posted again")
        case .dropped:
            tracker.markBroken(echoId)
            CWLog.w(.send, "dropped echo=\(echoId): local data was reset")
        case .failed(let error):
            CWLog.w(.send, "fail echo=\(echoId) \(error.logLabel)")
            markFailed(echoId)
        case .conversationGone:
            CWLog.w(.send, "fail echo=\(echoId) http 404")
            markFailed(echoId)
        }
    }

    private func markFailed(_ echoId: String) {
        do {
            try pendingDAO.setState(echoId, state: .failed)
        } catch {
            CWLog.w(.send, "state update failed echo=\(echoId)")
        }
        tracker.markBroken(echoId)
    }

    private func attempt(_ echoId: String, retry: Bool, owner: Int) async -> Outcome {
        let read: (StoredPendingMessage?, Session?)?
        do {
            read = try generation.ifCurrent(owner) {
                (try pendingDAO.get(echoId), store.read())
            }
        } catch {
            return .failed(.unknown)
        }
        guard let read else { return .dropped }
        guard var pending = read.0 else { return .delivered }
        guard let session = read.1 else { return .failed(.unknown) }
        if retry {
            let synced = await sync.sync(.retry)
            if case .failure(let error) = synced { return .failed(error) }
            let reread: StoredPendingMessage??
            do {
                reread = try generation.ifCurrent(owner) { try pendingDAO.get(echoId) }
            } catch {
                return .failed(.unknown)
            }
            guard let reread else { return .dropped }
            guard let fresh = reread else { return .delivered }
            pending = fresh
            let known = pending.conversationId ?? findConversation()
            if pending.posted, let known, let duplicate = findDuplicate(pending: pending, conversationId: known) {
                let recorded: Bool
                do {
                    recorded = try generation.ifCurrent(owner) { try messageDAO.recordEcho(messageId: duplicate.id, echoId: echoId) } != nil
                } catch {
                    return .failed(.unknown)
                }
                guard recorded else { return .dropped }
                finish(pending)
                return .duplicate
            }
        }
        let first = await send(pending, session: session, owner: owner)
        guard case .conversationGone(let goneConversationId) = first else { return first }
        switch await checkContact(session) {
        case .healthy:
            break
        case .stale:
            sessionGuard.onHttp(code: 404, path: Self.messagesPath)
            return .failed(.http(code: 404))
        case .unknown:
            return .failed(.http(code: 404))
        }
        CWLog.w(.send, "conversation gone echo=\(echoId), resolving again")
        let deleted: Bool
        do {
            deleted = try await sync.applyRealtime(epoch: owner) {
                try messageDAO.deleteConversation(conversationId: goneConversationId)
            }
        } catch {
            return .failed(.unknown)
        }
        guard deleted else { return .dropped }
        pending.conversationId = nil
        let second = await send(pending, session: session, owner: owner)
        if case .conversationGone = second {
            return .failed(.http(code: 404))
        }
        return second
    }

    private func checkContact(_ session: Session) async -> ContactVerdict {
        await contactCheck(session)
    }

    private func send(_ pending: StoredPendingMessage, session: Session, owner: Int) async -> Outcome {
        let conversationId: Int
        if let known = pending.conversationId {
            conversationId = known
        } else {
            switch await resolveConversation(session: session, epoch: owner, attributes: pending.creationAttributes()) {
            case .success(let resolved):
                conversationId = resolved
            case .failure(let error):
                return generation.isCurrent(owner) ? .failed(error) : .dropped
            }
            let assigned: Bool
            do {
                assigned = try generation.ifCurrent(owner) {
                    try pendingDAO.assignConversation(pending.echoId, conversationId: conversationId)
                } != nil
            } catch {
                return .failed(.unknown)
            }
            guard assigned else { return .dropped }
        }
        guard generation.isCurrent(owner) else { return .dropped }
        return await post(pending, session: session, conversationId: conversationId, epoch: owner)
    }

    private func findDuplicate(pending: StoredPendingMessage, conversationId: Int) -> StoredMessage? {
        let size = pending.attachmentPath.flatMap { path in
            (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int
        }
        do {
            let taken = Set(try messageDAO.echoesOf(conversationId: conversationId)
                .filter { $0.echoId != pending.echoId }
                .map(\.messageId))
            let candidates = try messageDAO.messagesOf(conversationId: conversationId)
                .filter { !taken.contains($0.message.id) }
            return DuplicateMatcher.findWithAttachments(pending: pending, messages: candidates, fileSize: size)
        } catch {
            return nil
        }
    }

    private func latestConversation() -> StoredConversation? {
        let all = (try? conversationDAO.allOrderedByActivity()) ?? []
        return all
            .filter { $0.inboxId == inboxId }
            .max { lhs, rhs in
                (lhs.lastActivityAt, lhs.id) < (rhs.lastActivityAt, rhs.id)
            }
    }

    private func findConversation() -> Int? {
        latestConversation()?.id
    }

    private func reusableConversation() -> Int? {
        guard let latest = latestConversation(), Self.reusable.contains(latest.status) else { return nil }
        return latest.id
    }

    private func statusMayBeStale() async -> Bool {
        if realtimeLive() { return false }
        return await sync.fullPassAgeMs().map { $0 >= Self.statusMaxAgeMs } ?? true
    }

    private func resolveConversation(session: Session, epoch: Int, attributes: [String: JSONValue]?) async -> Result<Int, ChatwootError> {
        let local = reusableConversation()
        if let local, await !statusMayBeStale() {
            return .success(local)
        }
        let synced = await sync.sync(.discover)
        if case .failure(let error) = synced {
            guard let local else { return .failure(error) }
            CWLog.d(.send, "conversation status not refreshed, using the stored one")
            return .success(local)
        }
        if let reusable = reusableConversation() {
            return .success(reusable)
        }
        guard generation.isCurrent(epoch) else { return .failure(.unknown) }
        do {
            let dto = try await api.createConversation(sourceID: session.sourceID, body: ConversationCreateBody(customAttributes: attributes))
            guard let bundle = dto.toEntities() else { return .failure(.unknown) }
            let stored: Bool = try await sync.applyRealtime(epoch: epoch) {
                var fresh = bundle.conversation
                if fresh.inboxId == 0 { fresh.inboxId = inboxId }
                fresh.lastActivityAt = max(fresh.lastActivityAt, nowSeconds())
                if (try? conversationDAO.insertIfAbsent(fresh)) != true {
                    try conversationDAO.mergeFromServer(
                        id: fresh.id, inboxId: fresh.inboxId, status: fresh.status,
                        contactLastSeenAt: fresh.contactLastSeenAt, agentLastSeenAt: fresh.agentLastSeenAt,
                        lastActivityAt: fresh.lastActivityAt
                    )
                }
            }
            return stored ? .success(bundle.conversation.id) : .failure(.unknown)
        } catch let error as ChatwootError {
            if case .http(let code) = error {
                sessionGuard.onHttp(code: code, path: Self.conversationsPath)
            }
            return .failure(error)
        } catch {
            return .failure(.unknown)
        }
    }

    private func post(_ pending: StoredPendingMessage, session: Session, conversationId: Int, epoch: Int) async -> Outcome {
        if let path = pending.attachmentPath, !fileManager.fileExists(atPath: path) {
            return .failed(.unreadable)
        }
        let marked: Bool
        do {
            marked = try generation.ifCurrent(epoch) { try pendingDAO.markPosted(pending.echoId) } != nil
        } catch {
            return .failed(.unknown)
        }
        guard marked else { return .dropped }
        let response: Result<MessageDTO, ChatwootError>
        if let path = pending.attachmentPath {
            do {
                let fileURL = URL(fileURLWithPath: path)
                let data = try Data(contentsOf: fileURL)
                let file = MultipartFile(data: data, filename: fileURL.lastPathComponent, mimeType: pending.attachmentMime ?? "application/octet-stream")
                response = await Self.attempt { try await api.createMessageWithAttachments(
                    sourceID: session.sourceID, conversationID: conversationId,
                    content: pending.content, echoID: pending.echoId, attachments: [file]
                ) }
            } catch let error as ChatwootError {
                response = .failure(error)
            } catch {
                return .failed(.unreadable)
            }
        } else {
            response = await Self.attempt { try await api.createMessage(
                sourceID: session.sourceID, conversationID: conversationId,
                body: MessageCreateBody(content: pending.content ?? "", echoID: pending.echoId)
            ) }
        }
        switch response {
        case .success(let dto):
            guard let mapped = dto.toEntities() else {
                try? pendingDAO.delete(pending.echoId)
                _ = await sync.sync(.refresh)
                cleanup(pending)
                return .delivered
            }
            var entity = mapped.0
            entity.conversationId = dto.conversationID ?? conversationId
            do {
                _ = try await sync.applyRealtime(epoch: epoch) {
                    try messageDAO.applyServerMessage(entity, attachments: mapped.1, echoId: pending.echoId)
                }
            } catch {
                CWLog.w(.send, "ack not stored echo=\(pending.echoId)")
            }
            cleanup(pending)
            return .delivered
        case .failure(.http(let code)):
            if code == 404 {
                return .conversationGone(conversationId)
            }
            if code == 401 {
                sessionGuard.onHttp(code: code, path: Self.messagesPath)
            }
            return .failed(.http(code: code))
        case .failure(.network):
            return .failed(.network)
        case .failure(let error):
            return .failed(error)
        }
    }

    private func finish(_ pending: StoredPendingMessage) {
        try? pendingDAO.delete(pending.echoId)
        cleanup(pending)
    }

    private func cleanup(_ pending: StoredPendingMessage) {
        guard pending.attachmentPath != nil else { return }
        let directory = attachmentsDir.appendingPathComponent(pending.echoId)
        try? fileManager.removeItem(at: directory)
    }

    private func discard(_ echoId: String) {
        try? fileManager.removeItem(at: attachmentsDir.appendingPathComponent(echoId))
    }

    private func insert(owner: Int, row: StoredPendingMessage) -> Bool {
        do {
            let inserted: Void? = try generation.ifCurrent(owner) { try pendingDAO.upsert(row) }
            if inserted == nil {
                CWLog.w(.send, "enqueue dropped echo=\(row.echoId): local data was reset")
                return false
            }
            return true
        } catch {
            CWLog.w(.send, "rejected echo=\(row.echoId) \(type(of: error))")
            return false
        }
    }

    private func nowSeconds() -> Int {
        Int(now() / 1_000)
    }

    private enum Prepared {
        case ready(URL, String?)
        case rejected(ChatwootError)
    }

    private nonisolated func prepare(url: URL, mime: String?, echoId: String) -> Prepared {
        let fileManager = FileManager.default
        let resolvedMime = mime ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        let name = Self.safeName(url.deletingPathExtension().lastPathComponent.isEmpty ? nil : url.lastPathComponent)
        let directory = attachmentsDir.appendingPathComponent(echoId)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .rejected(.unreadable)
        }
        var ready: Prepared?
        defer {
            if ready == nil { try? fileManager.removeItem(at: directory) }
        }
        if AttachmentLimits.isCompressibleImage(resolvedMime), let data = try? Data(contentsOf: url) {
            let jpegURL = directory.appendingPathComponent(Self.jpegName(name))
            switch ImageCompressor.compress(data: data, to: jpegURL) {
            case .done:
                ready = .ready(jpegURL, "image/jpeg")
                return ready!
            case .keepOriginal, .unsupported:
                break
            }
        }
        let declared = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int
        if let declared, declared > AttachmentLimits.maxFileBytes {
            return .rejected(.tooLarge)
        }
        let output = directory.appendingPathComponent(name)
        guard let input = InputStream(url: url) else {
            return .rejected(.unreadable)
        }
        let withinLimit = Self.copyCapped(input: input, to: output)
        guard withinLimit else {
            return .rejected(.tooLarge)
        }
        ready = .ready(output, resolvedMime)
        return ready!
    }

    private nonisolated static func copyCapped(input: InputStream, to output: URL) -> Bool {
        guard let stream = OutputStream(url: output, append: false) else { return false }
        input.open()
        defer { input.close() }
        stream.open()
        defer { stream.close() }
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let read = input.read(&buffer, maxLength: buffer.count)
            if read < 0 { return false }
            if read == 0 { break }
            total += read
            if total > AttachmentLimits.maxFileBytes { return false }
            let written = buffer.withUnsafeBytes { pointer in
                stream.write(pointer.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: read)
            }
            if written < 0 { return false }
        }
        return true
    }

    private nonisolated static func safeName(_ raw: String?) -> String {
        let cleaned = String((raw ?? "").split(separator: "/").last ?? "")
            .map { $0.isLetter || $0.isNumber || "._- ".contains($0) ? $0 : "_" }
            .prefix(100)
        let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "file" : trimmed
    }

    private nonisolated static func jpegName(_ name: String) -> String {
        let base = name.contains(".") ? String(name.split(separator: ".").dropLast().joined(separator: ".")) : name
        return (base.isEmpty ? "image" : base) + ".jpg"
    }

    private static func attributesString(_ attributes: [String: JSONValue]?) -> String? {
        guard let attributes else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: attributes.mapValues(\.bridgedObject)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func attempt(_ call: () async throws -> MessageDTO) async -> Result<MessageDTO, ChatwootError> {
        do {
            return .success(try await call())
        } catch let error as ChatwootError {
            return .failure(error)
        } catch {
            return .failure(.unknown)
        }
    }

    private struct Dispatch {
        let echoId: String
        let retry: Bool
        let owner: Int
    }

    private enum Outcome {
        case delivered
        case duplicate
        case dropped
        case conversationGone(Int)
        case failed(ChatwootError)
    }

    private static let retryable: Set<StoredPendingMessage.State> = [.queued, .failed]
    private static let reusable: Set<String> = [
        ConversationStatus.open.rawValue, ConversationStatus.pending.rawValue, ConversationStatus.snoozed.rawValue
    ]
    static let statusMaxAgeMs: UInt64 = 5 * 60 * 1000
    private static let conversationsPath = "/contacts/{id}/conversations"
    private static let messagesPath = "/contacts/{id}/conversations/{id}/messages"
}

private extension StoredPendingMessage {
    func creationAttributes() -> [String: JSONValue]? {
        guard let conversationAttributes,
              let data = conversationAttributes.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object.compactMapValues(JSONValue.init(bridging:))
    }
}

private extension ChatwootError {
    var logLabel: String {
        switch self {
        case .http(let code): return "http \(code)"
        case .network: return "network"
        case .tooLarge: return "tooLarge"
        case .unreadable: return "unreadable"
        default: return "\(self)"
        }
    }
}
