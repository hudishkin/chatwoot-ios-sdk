import Combine
import Foundation

/// Entry point of the SDK. Call `initialize(_:)` once (for example in the root
/// `App`'s `init` or in `AppDelegate`); before that `identify` returns
/// `.failure(.notInitialized)` and `reset` traps with `preconditionFailure`.
/// All members are safe to call from any thread; neither disk nor network is
/// touched on the calling thread.
public enum Chatwoot {
    private static let installLock = NSLock()
    private static var installedCore: ChatwootCore?

    static var core: ChatwootCore? {
        installLock.lock()
        defer { installLock.unlock() }
        return installedCore
    }

    /// Stores the (validated at creation) configuration and installs the SDK logger;
    /// files and network are opened later, in the background, on first use.
    /// Repeated calls are ignored.
    public static func initialize(_ config: ChatwootConfig) {
        installLock.lock()
        guard installedCore == nil else {
            installLock.unlock()
            CWLog.w(.app, "initialize called again, ignored")
            return
        }
        CWLog.install(sink: config.logSink, console: config.debugConsoleLogging)
        installedCore = ChatwootCore(config: config)
        installLock.unlock()
        CWLog.i(.app, "init sdk=\(ChatwootSDK.version)")
    }

    /// Identifies the user. Idempotent for the same identifier; a different
    /// identifier first wipes the previous user's local data. Call it after the
    /// user signs in **and on every app launch** for the signed-in user.
    /// Before `initialize` returns `.failure(.notInitialized)`.
    ///
    /// A successful identify assembles the local stack (database, offline queue,
    /// realtime) and starts a catch-up sync.
    public static func identify(user: ChatwootUser, identity provider: IdentityProvider) async -> Result<Void, ChatwootError> {
        guard let core = core else { return .failure(.notInitialized) }
        return await core.identify(user: user, identityProvider: provider)
    }

    /// Sign-out: resets the session and deletes the SDK's local data. A cleanup
    /// interrupted by a crash is finished by the next `identify`.
    public static func reset() async {
        guard let core = core else {
            preconditionFailure("Chatwoot.reset used before Chatwoot.initialize(_:)")
        }
        await core.reset()
    }

    static func installForTesting(_ core: ChatwootCore?) {
        installLock.lock()
        installedCore = core
        installLock.unlock()
    }
}

actor ChatwootCore {
    let config: ChatwootConfig

    private let apiOverride: ChatwootAPI?
    private let storeOverride: SessionStore?
    private let directoryOverride: URL?
    private let socketOverride: (any SocketManaging)?

    private(set) lazy var dataDirectory: URL = directoryOverride ?? SDKDirectory.data()
    private(set) lazy var sessionStore: SessionStore = storeOverride ?? SessionStore(directory: dataDirectory)
    private lazy var api: ChatwootAPI = apiOverride ?? URLSessionChatwootAPI(config: config)
    private lazy var interactor: IdentifyInteractor = IdentifyInteractor(api: api, store: sessionStore, resetLocalData: wipeLocalData)

    nonisolated let sessionGuard = SessionGuard()

    private lazy var networkMonitor = NetworkAvailabilityMonitor()
    private(set) lazy var socket: any SocketManaging = socketOverride ?? SocketConnectionManager(
        transport: URLSessionWebSocketTransport(baseURL: config.baseURL)
    )
    private(set) lazy var cable: RoomChannelClient = RoomChannelClient(socket: socket)

    private let connectionWanted = CurrentValueSubject<Bool, Never>(true)

    private(set) var stack: SessionStack?

    struct SessionStack {
        let database: ChatwootDatabase
        let sync: SyncManager
        let sendQueue: SendQueue
        let realtime: RealtimeController
        let unreadTracker: UnreadTracker
        let surveyRepository: SurveyRepository
    }

    private var remembered: (user: ChatwootUser, provider: IdentityProvider)?

    private var guardTasks: [Task<Void, Never>] = []

    private var attachmentsDir: URL { dataDirectory.appendingPathComponent("attachments") }
    private var databaseFile: URL { dataDirectory.appendingPathComponent("chatwoot.db") }

    init(
        config: ChatwootConfig,
        api: ChatwootAPI? = nil,
        sessionStore: SessionStore? = nil,
        dataDirectory: URL? = nil,
        socket: (any SocketManaging)? = nil
    ) {
        self.config = config
        self.apiOverride = api
        self.storeOverride = sessionStore
        self.directoryOverride = dataDirectory
        self.socketOverride = socket
    }

    deinit {
        guardTasks.forEach { $0.cancel() }
    }

    var session: Session? { sessionStore.current }

    func identify(user: ChatwootUser, identityProvider: IdentityProvider) async -> Result<Void, ChatwootError> {
        remembered = (user, identityProvider)
        let result = await runIdentify(user: user, provider: identityProvider, force: false)
        if case .success = result {
            await startSessionStack()
        }
        return result
    }

    func makeChatRepository(request: ChatRequest) -> ChatRepository? {
        guard let stack else { return nil }
        return GraphChatRepository(
            stack: stack,
            inboxId: config.inboxID,
            request: request,
            transportAvailable: networkMonitor.transportAvailable.eraseToAnyPublisher(),
            socketState: socket.state
        )
    }

    func reset() async {
        remembered = nil
        if let stack {
            await stack.realtime.stopNow()
        }
        networkMonitor.stop()
        do {
            try await wipeLocalData()
            CWLog.i(.auth, "reset")
        } catch {
            CWLog.w(.auth, "reset: local data not cleared (\(type(of: error))), finished before the next identify")
        }
    }

    private func runIdentify(user: ChatwootUser, provider: IdentityProvider, force: Bool) async -> Result<Void, ChatwootError> {
        let identity: Identity
        switch await provider.fetch() {
        case .success(let fetched):
            identity = fetched
        case .failure(let error):
            return .failure(error)
        }
        let result = await interactor.identify(user: user, identity: identity, force: force)
        return result.map { _ in () }
    }

    private func startSessionStack() async {
        guard let stack = await requireStack() else { return }
        networkMonitor.start { [weak self] in
            Task { await self?.socket.networkAvailable() }
        }
        Task { [sync = stack.sync] in
            _ = await sync.sync(.identify)
        }
    }

    private func requireStack() async -> SessionStack? {
        if let stack { return stack }
        do {
            let database = try ChatwootDatabase.open(directory: dataDirectory)
            let verifier = StaleSessionVerifier(api: api, inboxIdentifier: config.inboxIdentifier)
            let sync = SyncManager(
                api: api,
                inboxIdentifier: config.inboxIdentifier,
                inboxId: config.inboxID,
                store: sessionStore,
                messageDAO: database.messages,
                sessionGuard: sessionGuard
            )
            let realtime = RealtimeController(
                socket: socket,
                cable: cable,
                connectionWanted: connectionWanted,
                store: sessionStore,
                sync: sync,
                messageDAO: database.messages,
                conversationDAO: database.conversations,
                inboxId: config.inboxID
            )
            let sendQueue = SendQueue(
                api: api,
                inboxIdentifier: config.inboxIdentifier,
                inboxId: config.inboxID,
                store: sessionStore,
                pendingDAO: database.pending,
                messageDAO: database.messages,
                conversationDAO: database.conversations,
                sync: sync,
                sessionGuard: sessionGuard,
                attachmentsDir: attachmentsDir,
                contactCheck: { session in
                    switch await verifier.verify(session: session) {
                    case .healthy: return .healthy
                    case .stale: return .stale
                    case .unknown: return .unknown
                    }
                },
                realtimeLive: { realtime.isLive }
            )
            let retryTriggers = Publishers.Merge(
                socket.status.filter { $0 == .opened }.map { _ in () },
                sync.lastSuccessAt.compactMap { $0 }.map { _ in () }
            ).eraseToAnyPublisher()
            let unreadTracker = UnreadTracker(
                api: api,
                inboxIdentifier: config.inboxIdentifier,
                inboxId: config.inboxID,
                store: sessionStore,
                conversationDAO: database.conversations,
                messageDAO: database.messages,
                sessionGuard: sessionGuard,
                changes: database.changes,
                generation: sync.generation,
                retryTriggers: retryTriggers,
                contactCheck: { session in await verifier.verify(session: session) }
            )
            let surveyRepository = SurveyRepository(
                api: api,
                inboxIdentifier: config.inboxIdentifier,
                store: sessionStore,
                messageDAO: database.messages,
                sync: sync,
                sessionGuard: sessionGuard
            )
            await sendQueue.start()
            await realtime.bind()
            await unreadTracker.start()
            observeSessionGuard(verifier: verifier)
            let assembled = SessionStack(
                database: database, sync: sync, sendQueue: sendQueue, realtime: realtime,
                unreadTracker: unreadTracker, surveyRepository: surveyRepository
            )
            stack = assembled
            return assembled
        } catch {
            CWLog.e(.app, "session stack not assembled: \(type(of: error))")
            return nil
        }
    }

    private func observeSessionGuard(verifier: StaleSessionVerifier) {
        guard guardTasks.isEmpty else { return }
        guardTasks.append(Task { [sessionGuard, missed = cable.missedConfirms] in
            for await count in missed.values {
                sessionGuard.onMissedConfirms(count)
            }
        })
        guardTasks.append(Task { [sessionGuard, disconnects = cable.terminalDisconnects] in
            for await reason in disconnects.values {
                sessionGuard.onTerminalDisconnect(reason: reason)
            }
        })
        guardTasks.append(Task { [weak self, sessionGuard, store = sessionStore, verifier] in
            for await reason in sessionGuard.reidentifyRequests.values {
                guard let stale = store.current else { continue }
                let verdict = await verifier.verify(session: stale)
                guard verdict == .stale else { continue }
                await self?.reidentify(staleSession: stale, reason: reason, verifier: verifier)
            }
        })
    }

    private func reidentify(staleSession: Session, reason: String, verifier: StaleSessionVerifier) async {
        guard sessionStore.current == staleSession else {
            CWLog.d(.auth, "reidentify request dropped: session already changed")
            return
        }
        guard verifier.tryAcquire() else {
            CWLog.w(.auth, "reidentify capped: one ran recently")
            return
        }
        guard let remembered else {
            CWLog.w(.auth, "reidentify skipped: identify not called yet")
            return
        }
        CWLog.w(.auth, "reidentify: \(reason)")
        let result = await runIdentify(user: remembered.user, provider: remembered.provider, force: true)
        if case .success = result, let sync = stack?.sync {
            _ = await sync.sync(.identify)
        }
    }

    private func wipeLocalData() async throws {
        let marked: Bool
        do {
            try sessionStore.markCleanupRequired()
            marked = true
        } catch {
            CWLog.w(.auth, "cleanup marker not written, session kept until wiped")
            marked = false
        }
        if let stack {
            await stack.unreadTracker.cancelAll()
            let store = sessionStore
            let database = stack.database
            try await stack.sync.invalidate {
                if marked {
                    store.clear()
                    try database.wipe()
                } else {
                    try database.wipe()
                    store.clear()
                }
            }
        } else {
            sessionStore.clear()
            try? FileManager.default.removeItem(at: databaseFile)
        }
        sessionStore.clearCleanupRequired()
        try? FileManager.default.removeItem(at: attachmentsDir)
    }
}
