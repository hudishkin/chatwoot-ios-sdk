import Combine
import Foundation

actor SyncManager {
    enum SyncTrigger {
        case identify, subscribed, refresh, retry
        case discover

        var needsFull: Bool { self == .identify || self == .discover }
    }

    private let api: ChatwootAPI
    private let inboxIdentifier: String
    private let inboxId: Int
    private let store: SessionStore
    private let messageDAO: MessageDAO
    private let sessionGuard: SessionGuard
    private let now: () -> UInt64

    let generation = SessionGeneration()

    nonisolated let lastSuccessAt = CurrentValueSubject<UInt64?, Never>(nil)

    private struct Inflight {
        var getStarted = false
        var pending = 0
        var fullRequested = false
        var waiters: [CheckedContinuation<Result<Void, ChatwootError>, Never>] = []
    }

    private var inflight: Inflight?
    private var passIsFull = false
    private var lastFullAt: UInt64?
    private var lastFullGeneration = -1
    private var realtimeWrites: UInt64 = 0

    init(
        api: ChatwootAPI,
        inboxIdentifier: String,
        inboxId: Int,
        store: SessionStore,
        messageDAO: MessageDAO,
        sessionGuard: SessionGuard,
        now: @escaping () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.api = api
        self.inboxIdentifier = inboxIdentifier
        self.inboxId = inboxId
        self.store = store
        self.messageDAO = messageDAO
        self.sessionGuard = sessionGuard
        self.now = now
    }

    func sync(_ trigger: SyncTrigger) async -> Result<Void, ChatwootError> {
        if inflight != nil {
            if trigger.needsFull { inflight?.fullRequested = true }
            if inflight?.getStarted == true || (trigger.needsFull && !passIsFull) {
                inflight?.pending += 1
            }
            return await withCheckedContinuation { continuation in
                inflight?.waiters.append(continuation)
            }
        }
        inflight = Inflight(fullRequested: trigger.needsFull)
        var result: Result<Void, ChatwootError> = .failure(.unknown)
        var pass = 0
        var rerun: Bool
        repeat {
            inflight?.pending = 0
            inflight?.getStarted = false
            pass += 1
            result = await runGuarded(trigger)
            let pending = inflight?.pending ?? 0
            rerun = pending > 0 && pass < Self.maxPasses
            if pending > 0 && !rerun {
                CWLog.w(.sync, "rerun cap reached, \(pending) pending request dropped")
            }
        } while rerun
        let waiters = inflight?.waiters ?? []
        inflight = nil
        for waiter in waiters {
            waiter.resume(returning: result)
        }
        return result
    }

    func fullPassAgeMs() -> UInt64? {
        guard let lastFullAt, lastFullGeneration == generation.current else { return nil }
        return now() - lastFullAt
    }

    nonisolated var currentEpoch: Int { generation.current }

    func invalidate<T>(_ block: () throws -> T) rethrows -> T {
        try generation.invalidate(block)
    }

    @discardableResult
    func applyRealtime(epoch: Int? = nil, _ block: () throws -> Void) throws -> Bool {
        var ran = false
        try generation.snapshot { current in
            if let epoch, epoch != current {
                CWLog.d(.sync, "local write dropped: local data was reset")
                return
            }
            defer { realtimeWrites += 1 }
            try block()
            ran = true
        }
        return ran
    }

    private func runGuarded(_ trigger: SyncTrigger) async -> Result<Void, ChatwootError> {
        do {
            return try await run(trigger)
        } catch {
            CWLog.w(.sync, "trigger=\(trigger.name) -> failed \(type(of: error))")
            return .failure(.unknown)
        }
    }

    private func run(_ trigger: SyncTrigger) async throws -> Result<Void, ChatwootError> {
        let started = now()
        let name = trigger.name
        let startEpoch = generation.current
        guard let session = store.read() else {
            CWLog.w(.sync, "trigger=\(name) -> no session")
            return .failure(.unknown)
        }
        let requested = inflight?.fullRequested ?? false
        inflight?.fullRequested = false
        passIsFull = requested
        let stale = requested || lastFullGeneration != startEpoch
            || (lastFullAt.map { started - $0 >= Self.fullIntervalMs } ?? true)
        let targets = stale ? [] : (try incrementalTargets())
        if targets.isEmpty {
            passIsFull = true
            return await runFull(name: name, started: started, startEpoch: startEpoch, session: session)
        }
        if let incremental = try await runIncremental(name: name, started: started, startEpoch: startEpoch, session: session, targets: targets) {
            return incremental
        }
        passIsFull = true
        return await runFull(name: name, started: started, startEpoch: startEpoch, session: session)
    }

    private func incrementalTargets() throws -> [StoredConversation] {
        let local = try messageDAO.conversationsOf(inboxId: inboxId)
        guard let latest = local.first else { return [] }
        var seen: Set<Int> = []
        return ([latest] + local.filter { $0.status != Self.resolved }).filter { seen.insert($0.id).inserted }
    }

    private func runFull(name: String, started: UInt64, startEpoch: Int, session: Session) async -> Result<Void, ChatwootError> {
        var attempt = 1
        while true {
            let writesBefore = realtimeWrites
            inflight?.getStarted = true
            let dtos: [ConversationDTO]
            do {
                dtos = try await api.conversations(sourceID: session.sourceID)
            } catch let error as ChatwootError {
                if case .http(let code) = error {
                    sessionGuard.onHttp(code: code, path: Self.conversationsPath)
                }
                return failure(name, started, error.logLabel, error)
            } catch {
                return failure(name, started, "decode \(type(of: error))", .unknown)
            }
            if dtos.contains(where: { dto in
                guard let identifier = dto.contact?.identifier else { return false }
                return identifier != session.identifier
            }) {
                sessionGuard.request(Self.identifierMismatchReason)
                return failure(name, started, "identity mismatch", .identityMismatch)
            }
            let own = dtos.filter { $0.inboxID == inboxId }
            let foreign = dtos.count - own.count
            let bundles = own.compactMap { $0.toEntities() }
            let outcome: Result<Void, ChatwootError>? = generation.snapshot { current in
                if current != startEpoch {
                    return failure(name, started, "local data reset meanwhile", .unknown)
                }
                if realtimeWrites != writesBefore && attempt < Self.maxAttempts { return nil }
                do {
                    try messageDAO.replaceConversations(
                        bundles.map(\.conversation),
                        messages: bundles.flatMap(\.messages),
                        attachments: bundles.flatMap(\.attachments)
                    )
                    return .success(())
                } catch {
                    return failure(name, started, "db \(type(of: error))", .unknown)
                }
            }
            guard let outcome else {
                attempt += 1
                CWLog.d(.sync, "trigger=\(name) snapshot overlapped a realtime write, refetching")
                continue
            }
            if case .success = outcome {
                lastSuccessAt.send(now())
                lastFullAt = started
                lastFullGeneration = startEpoch
                CWLog.i(.sync, "trigger=\(name) conv=\(bundles.count) msg=\(bundles.map(\.messages.count).reduce(0, +)) foreign=\(foreign) -> ok ms=\(now() - started)")
            }
            return outcome
        }
    }

    private func runIncremental(
        name: String,
        started: UInt64,
        startEpoch: Int,
        session: Session,
        targets: [StoredConversation]
    ) async throws -> Result<Void, ChatwootError>? {
        var attempt = 1
        while true {
            let writesBefore = realtimeWrites
            var pages: [(conversationId: Int, dtos: [MessageDTO])] = []
            for conversation in targets {
                switch try await fetchNewMessages(conversationId: conversation.id, session: session) {
                case .fetched(let dtos):
                    pages.append((conversation.id, dtos))
                case .network:
                    return failure(name, started, "network", .network)
                case .mismatch:
                    sessionGuard.request(Self.identifierMismatchReason)
                    return failure(name, started, "identity mismatch", .identityMismatch)
                case .fullNeeded:
                    CWLog.d(.sync, "trigger=\(name) incremental catch-up not possible, full sync")
                    return nil
                }
            }
            let mapped = pages.map { page -> FetchedPages in
                var messages: [StoredMessage] = []
                var attachments: [StoredAttachment] = []
                for dto in page.dtos {
                    guard let (message, messageAttachments) = dto.toEntities() else { continue }
                    var stored = message
                    stored.conversationId = page.conversationId
                    messages.append(stored)
                    attachments.append(contentsOf: messageAttachments)
                }
                return FetchedPages(conversationId: page.conversationId, messages: messages,
                                    attachments: attachments, newestId: page.dtos.compactMap(\.id).max())
            }
            let outcome: Result<Void, ChatwootError>? = generation.snapshot { current in
                if current != startEpoch {
                    return failure(name, started, "local data reset meanwhile", .unknown)
                }
                if realtimeWrites != writesBefore && attempt < Self.maxAttempts { return nil }
                do {
                    for page in mapped {
                        try messageDAO.applyMessagesPage(conversationId: page.conversationId, messages: page.messages,
                                                        attachments: page.attachments, syncedThroughId: page.newestId)
                    }
                    return .success(())
                } catch {
                    return failure(name, started, "db \(type(of: error))", .unknown)
                }
            }
            guard let outcome else {
                attempt += 1
                CWLog.d(.sync, "trigger=\(name) pages overlapped a realtime write, refetching")
                continue
            }
            if case .success = outcome {
                lastSuccessAt.send(now())
                CWLog.i(.sync, "trigger=\(name) mode=messages conv=\(mapped.count) msg=\(mapped.map(\.messages.count).reduce(0, +)) -> ok ms=\(now() - started)")
            }
            return outcome
        }
    }

    private func fetchNewMessages(conversationId: Int, session: Session) async throws -> PageResult {
        let watermark = try messageDAO.syncedThroughId(conversationId: conversationId)
        var collected: [MessageDTO] = []
        var before: Int?
        for _ in 0..<Self.maxPages {
            inflight?.getStarted = true
            let page: [MessageDTO]
            do {
                page = try await api.messages(sourceID: session.sourceID, conversationID: conversationId, before: before)
            } catch let error as ChatwootError {
                if case .network = error { return .network }
                return .fullNeeded
            } catch {
                return .fullNeeded
            }
            if page.contains(where: { dto in
                guard dto.sender?.type == Self.contact, let identifier = dto.sender?.identifier else { return false }
                return identifier != session.identifier
            }) {
                return .mismatch
            }
            collected += page
            let ids = page.compactMap(\.id)
            let reachedStored = watermark.map { mark in ids.contains { $0 <= mark } } ?? false
            if reachedStored || page.count < Self.pageSize || ids.isEmpty {
                return .fetched(collected)
            }
            before = ids.min()
        }
        return .fullNeeded
    }

    private func failure(_ trigger: String, _ started: UInt64, _ what: String, _ error: ChatwootError) -> Result<Void, ChatwootError> {
        CWLog.w(.sync, "trigger=\(trigger) -> \(what) ms=\(now() - started)")
        return .failure(error)
    }

    private enum PageResult {
        case fetched([MessageDTO])
        case network
        case mismatch
        case fullNeeded
    }

    private struct FetchedPages {
        let conversationId: Int
        let messages: [StoredMessage]
        let attachments: [StoredAttachment]
        let newestId: Int?
    }

    static let fullIntervalMs: UInt64 = 30 * 60 * 1000
    static let pageSize = 20
    static let maxPages = 10
    private static let maxAttempts = 2
    private static let maxPasses = 3
    private static let conversationsPath = "/contacts/{id}/conversations"
    private static let identifierMismatchReason = "contact_identifier_mismatch"
    private static let resolved = "resolved"
    private static let contact = "contact"
}

private extension SyncManager.SyncTrigger {
    var name: String {
        switch self {
        case .identify: return "identify"
        case .subscribed: return "subscribed"
        case .refresh: return "refresh"
        case .retry: return "retry"
        case .discover: return "discover"
        }
    }
}

private extension ChatwootError {
    var logLabel: String {
        switch self {
        case .http(let code): return "http \(code)"
        case .network: return "network"
        default: return "\(self)"
        }
    }
}
