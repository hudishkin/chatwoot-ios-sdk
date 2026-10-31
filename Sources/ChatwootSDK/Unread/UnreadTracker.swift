import Combine
import Foundation

actor UnreadTracker {
    nonisolated let unread = CurrentValueSubject<Int, Never>(0)

    private let api: ChatwootAPI
    private let inboxIdentifier: String
    private let inboxId: Int
    private let store: SessionStore
    private let conversationDAO: ConversationDAO
    private let messageDAO: MessageDAO
    private let sessionGuard: SessionGuard
    private let changes: PassthroughSubject<Void, Never>
    private let debounceMs: UInt64
    private let generation: SessionGeneration
    private let retryTriggers: AnyPublisher<Void, Never>
    private var backoff: SocketBackoffStrategy
    private let contactCheck: (Session) async -> StaleSessionVerifier.Verdict

    private var pendingJobs: [Int: Task<Void, Never>] = [:]
    private var unacknowledged: [Int: Int] = [:]
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var observeTasks: [Task<Void, Never>] = []

    init(
        api: ChatwootAPI,
        inboxIdentifier: String,
        inboxId: Int,
        store: SessionStore,
        conversationDAO: ConversationDAO,
        messageDAO: MessageDAO,
        sessionGuard: SessionGuard,
        changes: PassthroughSubject<Void, Never>,
        debounceMs: UInt64 = UnreadTracker.debounceMs,
        generation: SessionGeneration,
        retryTriggers: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        backoff: SocketBackoffStrategy = SocketBackoffStrategy(),
        contactCheck: @escaping (Session) async -> StaleSessionVerifier.Verdict = { _ in .unknown }
    ) {
        self.api = api
        self.inboxIdentifier = inboxIdentifier
        self.inboxId = inboxId
        self.store = store
        self.conversationDAO = conversationDAO
        self.messageDAO = messageDAO
        self.sessionGuard = sessionGuard
        self.changes = changes
        self.debounceMs = debounceMs
        self.generation = generation
        self.retryTriggers = retryTriggers
        self.backoff = backoff
        self.contactCheck = contactCheck
    }

    func start() {
        guard observeTasks.isEmpty else { return }
        refreshUnread()
        observeTasks.append(Task { [weak self, changes] in
            for await _ in changes.values {
                await self?.refreshUnread()
            }
        })
        observeTasks.append(Task { [weak self, retryTriggers] in
            for await _ in retryTriggers.values {
                await self?.retryUnacknowledged()
            }
        })
    }

    deinit {
        observeTasks.forEach { $0.cancel() }
        pendingJobs.values.forEach { $0.cancel() }
        retryTask?.cancel()
    }

    func onMessagesShown(conversationId: Int, lastCreatedAt: Int) {
        let owner = generation.current
        Task { [weak self] in
            await self?.markLocally(lastCreatedAt, owner: owner)
        }
        pendingJobs.removeValue(forKey: conversationId)?.cancel()
        pendingJobs[conversationId] = Task { [weak self, timeout = debounceMs] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.debouncedFired(conversationId, owner: owner)
        }
    }

    func retryUnacknowledged() {
        retryTask?.cancel()
        retryTask = nil
        let due = unacknowledged
        for (conversationId, owner) in due {
            Task { [weak self] in
                await self?.send(conversationId, owner: owner)
            }
        }
    }

    func cancelAll() {
        pendingJobs.values.forEach { $0.cancel() }
        pendingJobs.removeAll()
        unacknowledged.removeAll()
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
    }

    // MARK: - Private

    private func refreshUnread() {
        do {
            try unread.send(messageDAO.unreadCount(inboxId: inboxId))
        } catch {
            CWLog.w(.sync, "unread count failed \(type(of: error))")
        }
    }

    private func debouncedFired(_ conversationId: Int, owner: Int) async {
        pendingJobs.removeValue(forKey: conversationId)
        await send(conversationId, owner: owner)
    }

    private func markLocally(_ at: Int, owner: Int) {
        do {
            try generation.ifCurrent(owner) {
                try conversationDAO.markInboxSeen(inboxId, at: at)
            }
        } catch {
            CWLog.w(.sync, "update_last_seen local write failed \(type(of: error))")
        }
    }

    private func send(_ conversationId: Int, owner: Int) async {
        guard generation.isCurrent(owner) else { return forget(conversationId) }
        guard let session = store.current else {
            CWLog.w(.sync, "update_last_seen skipped: no session")
            return keepForRetry(conversationId, owner: owner, schedule: false)
        }
        do {
            try await api.updateLastSeen(sourceID: session.sourceID, conversationID: conversationId)
            acknowledged(conversationId)
            CWLog.d(.sync, "update_last_seen ok")
        } catch let error as ChatwootError {
            switch error {
            case .http(let code):
                CWLog.w(.sync, "update_last_seen failed http \(code)")
                switch code {
                case 404:
                    await onNotFound(conversationId, owner: owner, session: session)
                case 401:
                    sessionGuard.onHttp(code: code, path: Self.pathTemplate)
                    keepForRetry(conversationId, owner: owner, schedule: false)
                case 429:
                    keepForRetry(conversationId, owner: owner, schedule: true)
                case let code where code >= 500:
                    keepForRetry(conversationId, owner: owner, schedule: true)
                default:
                    forget(conversationId)
                }
            case .network:
                CWLog.w(.sync, "update_last_seen failed network")
                keepForRetry(conversationId, owner: owner, schedule: true)
            case .unreadable:
                acknowledged(conversationId)
                CWLog.w(.sync, "update_last_seen failed decode")
            default:
                CWLog.w(.sync, "update_last_seen failed \(error)")
                keepForRetry(conversationId, owner: owner, schedule: true)
            }
        } catch {
            CWLog.w(.sync, "update_last_seen failed \(type(of: error))")
            keepForRetry(conversationId, owner: owner, schedule: true)
        }
    }

    private func onNotFound(_ conversationId: Int, owner: Int, session: Session) async {
        switch await contactCheck(session) {
        case .healthy:
            await conversationGone(conversationId, owner: owner)
        case .stale:
            forget(conversationId)
            sessionGuard.onHttp(code: 404, path: Self.pathTemplate)
        case .unknown:
            keepForRetry(conversationId, owner: owner, schedule: true)
        }
    }

    private func conversationGone(_ conversationId: Int, owner: Int) async {
        forget(conversationId)
        do {
            try generation.ifCurrent(owner) {
                try messageDAO.deleteConversation(conversationId: conversationId)
            }
        } catch {
            CWLog.w(.sync, "conversation drop failed \(type(of: error))")
        }
    }

    private func acknowledged(_ conversationId: Int) {
        unacknowledged.removeValue(forKey: conversationId)
        if unacknowledged.isEmpty { retryAttempt = 0 }
    }

    private func forget(_ conversationId: Int) {
        unacknowledged.removeValue(forKey: conversationId)
    }

    private func keepForRetry(_ conversationId: Int, owner: Int, schedule: Bool) {
        guard generation.isCurrent(owner) else { return }
        unacknowledged[conversationId] = owner
        guard schedule, retryTask == nil else { return }
        guard retryAttempt < Self.maxRetryAttempts else {
            CWLog.w(.sync, "update_last_seen retries paused after \(retryAttempt) attempts")
            return
        }
        let wait = backoff.nextDelayMs(attempt: retryAttempt)
        retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.retryUnacknowledged()
        }
    }

    static let maxRetryAttempts = 8
    static let debounceMs: UInt64 = 2_000
    private static let pathTemplate = "/contacts/{id}/conversations/{id}/update_last_seen"
}
