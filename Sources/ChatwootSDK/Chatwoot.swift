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
    private static let unreadSubject = CurrentValueSubject<Int, Never>(0)

    /// Unread agent replies, automatic replies, and unanswered surveys for the
    /// identified user. Replays the latest count to each new subscriber. `0`
    /// before a successful `identify` and after `reset`.
    ///
    /// The SDK keeps the count current: a sync when `identify` succeeds, another
    /// when the app returns to the foreground, and a timer while the app is
    /// active and realtime is not delivering events. The host only subscribes.
    public static var unreadCount: AnyPublisher<Int, Never> {
        unreadSubject.removeDuplicates().eraseToAnyPublisher()
    }

    static func noteUnread(_ count: Int) {
        unreadSubject.send(count)
    }

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

    /// Catch-up sync. With no session but a user identified earlier in this
    /// process, identifies that user first. Before `initialize` traps.
    public static func refresh() async {
        guard let core = core else {
            preconditionFailure("Chatwoot.refresh used before Chatwoot.initialize(_:)")
        }
        await core.catchUp()
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
        unreadSubject.send(0)
    }
}

actor ChatwootCore {
    let config: ChatwootConfig

    private let apiOverride: ChatwootAPI?
    private let storeOverride: SessionStore?
    private let directoryOverride: URL?
    private let socketOverride: (any SocketManaging)?
    private let appActivity: AnyPublisher<Bool, Never>
    private let unreadPollIntervalMs: UInt64
    private var unreadMaintenance: UnreadMaintenance?
    private var unreadBridge: AnyCancellable?

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

    let connectionWanted = CurrentValueSubject<Bool, Never>(false)

    private var stackWired = false
    private(set) var stack: SessionStack?

    struct SessionStack {
        let database: ChatwootDatabase
        let sync: SyncManager
        let sendQueue: SendQueue
        let realtime: RealtimeController
        let unreadTracker: UnreadTracker
        let surveyRepository: SurveyRepository
    }

    private struct Remembered {
        let token: UUID
        let user: ChatwootUser
        let provider: IdentityProvider
    }

    private var remembered: Remembered?
    private var reidentifyPending = false
    private var resetEpoch = 0
    private let identifyFlag = IdentifyFlag()
    private let sessionLock = SessionLock()
    private var sessionRecoverer: SessionRecoverer?
    private var cancelBackground: [() -> Void] = []

    private var guardTasks: [Task<Void, Never>] = []
    private var foregroundTask: Task<Void, Never>?
    private var backgroundGrace: Task<Void, Never>?
    private var chatStarts = 0
    private var hideChatTask: Task<Void, Never>?
    private let stopGraceMs: UInt64

    private var attachmentsDir: URL { dataDirectory.appendingPathComponent("attachments") }
    private var databaseFile: URL { dataDirectory.appendingPathComponent("chatwoot.db") }

    init(
        config: ChatwootConfig,
        api: ChatwootAPI? = nil,
        sessionStore: SessionStore? = nil,
        dataDirectory: URL? = nil,
        socket: (any SocketManaging)? = nil,
        appActivity: AnyPublisher<Bool, Never>? = nil,
        unreadPollIntervalMs: UInt64 = RealtimeController.pollIntervalMs,
        stopGraceMs: UInt64 = ChatwootCore.stopGraceMs
    ) {
        self.config = config
        self.apiOverride = api
        self.storeOverride = sessionStore
        self.directoryOverride = dataDirectory
        self.socketOverride = socket
        self.appActivity = appActivity ?? AppActivity.publisher()
        self.unreadPollIntervalMs = unreadPollIntervalMs
        self.stopGraceMs = stopGraceMs
    }

    static let stopGraceMs: UInt64 = 700

    deinit {
        guardTasks.forEach { $0.cancel() }
        cancelBackground.forEach { $0() }
        foregroundTask?.cancel()
        backgroundGrace?.cancel()
        hideChatTask?.cancel()
        unreadMaintenance?.stop()
        unreadBridge?.cancel()
    }

    var session: Session? { sessionStore.current }

    func identify(user: ChatwootUser, identityProvider: IdentityProvider) async -> Result<Void, ChatwootError> {
        identifyFlag.markCalled()
        let epoch = resetEpoch
        let result = await withSessionLock { () -> Result<Void, ChatwootError> in
            self.remembered = Remembered(token: UUID(), user: user, provider: identityProvider)
            let force = self.reidentifyPending
            self.reidentifyPending = false
            if force { CWLog.i(.auth, "identify forces the deferred reidentify") }
            let result = await self.runIdentify(user: user, provider: identityProvider, force: force)
            if force, case .failure = result { self.reidentifyPending = true }
            return result
        }
        if case .success = result, resetEpoch == epoch {
            await startSessionStack()
            // A reused session still catches up; a replaced one must sync after the write, not with the previous token.
            if resetEpoch == epoch {
                _ = await stack?.sync.sync(.identify)
            }
        }
        return result
    }

    /// Syncs the inbox. With no session but a remembered user, identifies that user first.
    func catchUp() async {
        if sessionStore.read() == nil {
            guard let captured = remembered else { return }
            let epoch = resetEpoch
            let task = Task { () -> Result<Void, ChatwootError>? in
                await self.withSessionLock {
                    if Task.isCancelled { return nil }
                    guard let current = self.remembered, current.token == captured.token, self.sessionStore.read() == nil else { return nil }
                    return await self.runIdentify(user: current.user, provider: current.provider, force: false)
                }
            }
            track(task)
            let result = await task.value
            if resetEpoch == epoch, case .success = result {
                await startSessionStack()
                if resetEpoch == epoch {
                    _ = await stack?.sync.sync(.identify)
                }
            }
            return
        }
        await startSessionStack()
        _ = await stack?.sync.sync(.refresh)
    }

    func makeChatRepository(request: ChatRequest) -> ChatRepository? {
        guard let stack else { return nil }
        return GraphChatRepository(
            stack: stack,
            inboxId: config.inboxID,
            request: request,
            transportAvailable: networkMonitor.transportAvailable.eraseToAnyPublisher(),
            socketState: socket.state,
            refreshInbox: { [weak self] in await self?.catchUp() }
        )
    }

    /// The chat screen appeared. Presence turns on at once. With `whileChatOpen` the socket is wanted too.
    func noteChatAppeared() async {
        chatStarts += 1
        hideChatTask?.cancel()
        hideChatTask = nil
        if config.realtime == .whileChatOpen {
            connectionWanted.send(true)
        }
        await cable.setPresenceWanted(true)
    }

    /// The chat screen disappeared. Presence turns off at once. The socket stays wanted for `stopGraceMs`
    /// so a rotation does not drop it.
    func noteChatDisappeared() async {
        chatStarts = max(0, chatStarts - 1)
        await cable.setPresenceWanted(chatStarts > 0)
        guard chatStarts == 0 else { return }
        hideChatTask?.cancel()
        let grace = stopGraceMs
        hideChatTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: grace * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.hideChatIfIdle()
        }
    }

    func reset() async {
        resetEpoch += 1
        remembered = nil
        reidentifyPending = false
        cancelBackground.forEach { $0() }
        cancelBackground.removeAll()
        await withSessionLock {
            self.remembered = nil
            self.reidentifyPending = false
            if let stack = self.stack {
                await stack.sendQueue.forgetFailures()
                await stack.realtime.stopNow()
            }
            self.networkMonitor.stop()
            self.unreadMaintenance?.stop()
            self.unreadMaintenance = nil
            Chatwoot.noteUnread(0)
            do {
                try await self.wipeLocalData()
                CWLog.i(.auth, "reset")
            } catch {
                CWLog.w(.auth, "reset: local data not cleared (\(type(of: error))), finished before the next identify")
            }
        }
    }

    private func runIdentify(user: ChatwootUser, provider: IdentityProvider, force: Bool) async -> Result<Void, ChatwootError> {
        if Task.isCancelled {
            CWLog.i(.auth, "identify cancelled by reset")
            return .failure(.unknown)
        }
        let identity: Identity
        switch await provider.fetch() {
        case .success(let fetched):
            identity = fetched
        case .failure(let error):
            return .failure(error)
        }
        if Task.isCancelled {
            CWLog.i(.auth, "identify cancelled by reset")
            return .failure(.unknown)
        }
        let result = await interactor.identify(user: user, identity: identity, force: force)
        return result.map { _ in () }
    }

    private func startSessionStack() async {
        guard !stackWired else { return }
        stackWired = true
        guard let stack = await requireStack() else {
            stackWired = false
            return
        }
        networkMonitor.start { [weak self] in
            Task { await self?.socket.networkAvailable() }
        }
        startUnreadMaintenance(stack)
        bindRealtimePolicy()
    }

    private func startUnreadMaintenance(_ stack: SessionStack) {
        if unreadMaintenance == nil {
            let sync = stack.sync
            let realtime = stack.realtime
            unreadMaintenance = UnreadMaintenance(
                activity: appActivity,
                pollIntervalMs: unreadPollIntervalMs,
                isRealtimeLive: { [connectionWanted] in
                    if !connectionWanted.value { return true }
                    return realtime.isLive
                },
                sync: { _ = await sync.sync(.refresh) }
            )
        }
        unreadMaintenance?.start()
    }

    private func bindUnread(_ tracker: UnreadTracker) {
        unreadBridge = tracker.unread.sink { Chatwoot.noteUnread($0) }
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
                realtimeLive: { realtime.isLive },
                sessionRecoverer: recoverer(),
                identifyCalled: { [identifyFlag] in identifyFlag.called },
                reopenResolved: config.resolvedConversations == .reopen
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
            bindUnread(unreadTracker)
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
        let disconnects = cable.terminalDisconnects.eagerValues()
        guardTasks.append(Task { [sessionGuard] in
            for await reason in disconnects {
                sessionGuard.onTerminalDisconnect(reason: reason)
            }
        })
        let requests = sessionGuard.reidentifyRequests.eagerValues()
        guardTasks.append(Task { [weak self, store = sessionStore, verifier] in
            for await reason in requests {
                guard let self else { return }
                guard let stale = store.current else { continue }
                let verdict = await verifier.verify(session: stale)
                await self.handleStale(stale, reason: reason, verdict: verdict, verifier: verifier)
            }
        })
    }

    private func handleStale(_ stale: Session, reason: String, verdict: StaleSessionVerifier.Verdict, verifier: StaleSessionVerifier) async {
        guard verdict == .stale else { return }
        guard sessionStore.current == stale else {
            CWLog.d(.auth, "reidentify request dropped: session already changed")
            return
        }
        guard remembered != nil else {
            reidentifyPending = true
            CWLog.w(.auth, "reidentify deferred: identify not called yet")
            return
        }
        guard verifier.tryAcquire() else {
            CWLog.w(.auth, "reidentify capped: one ran recently")
            return
        }
        CWLog.w(.auth, "reidentify: \(reason)")
        let task = Task { await self.forcedIdentify(stale) }
        track(task)
        await task.value
    }

    /// Replaces `stale` only while it is still the current session. A send that already replaced it wins.
    private func forcedIdentify(_ stale: Session) async {
        let result: Result<Void, ChatwootError>? = await withSessionLock {
            if Task.isCancelled {
                CWLog.i(.auth, "identify cancelled by reset")
                return nil
            }
            guard let remembered = self.remembered else {
                CWLog.w(.auth, "reidentify skipped: identify not called yet")
                return nil
            }
            guard self.sessionStore.current == stale else {
                CWLog.i(.auth, "reidentify skipped: session already changed")
                return nil
            }
            return await self.runIdentify(user: remembered.user, provider: remembered.provider, force: true)
        }
        if case .success = result, let sync = stack?.sync {
            _ = await sync.sync(.identify)
        }
    }

    /// One identify for a send: the remembered user when there is no session, or a forced one that replaces `stale`.
    private func identifyForSend(stale: Session?) async -> SessionRecovery {
        let epoch = resetEpoch
        guard let captured = remembered else { return .notIdentified }
        let task = Task { () -> SessionRecovery in
            await self.identifyForSendLocked(capturedToken: captured.token, stale: stale)
        }
        track(task)
        let recovery = await task.value
        if resetEpoch != epoch { return .aborted }
        return recovery
    }

    private func identifyForSendLocked(capturedToken: UUID, stale: Session?) async -> SessionRecovery {
        await withSessionLock {
            if Task.isCancelled {
                CWLog.i(.auth, "identify cancelled by reset")
                return .aborted
            }
            guard let current = self.remembered else { return .notIdentified }
            if let existing = self.sessionStore.current, existing != stale {
                return .done
            }
            let result: Result<Void, ChatwootError>
            if stale != nil {
                guard self.sessionStore.current == stale else {
                    CWLog.i(.auth, "reidentify skipped: session already changed")
                    return .done
                }
                result = await self.runIdentify(user: current.user, provider: current.provider, force: true)
            } else if current.token != capturedToken {
                return .done
            } else {
                result = await self.runIdentify(user: current.user, provider: current.provider, force: false)
            }
            switch result {
            case .success:
                if let sync = self.stack?.sync {
                    Task { _ = await sync.sync(.identify) }
                }
                return .done
            case .failure(let error):
                return .failed(error)
            }
        }
    }

    private func hideChatIfIdle() {
        guard chatStarts == 0, config.realtime == .whileChatOpen else { return }
        connectionWanted.send(false)
    }

    private func bindRealtimePolicy() {
        guard config.realtime == .whileForeground, foregroundTask == nil else { return }
        let activity = appActivity
        foregroundTask = Task { [weak self] in
            for await active in activity.removeDuplicates().eagerValues() {
                await self?.setForeground(active)
            }
        }
    }

    private func setForeground(_ active: Bool) {
        guard config.realtime == .whileForeground else { return }
        if active {
            backgroundGrace?.cancel()
            backgroundGrace = nil
            connectionWanted.send(true)
        } else {
            backgroundGrace?.cancel()
            let grace = stopGraceMs
            backgroundGrace = Task { [weak self] in
                try? await Task.sleep(nanoseconds: grace * 1_000_000)
                guard !Task.isCancelled else { return }
                await self?.setConnectionWanted(false)
            }
        }
    }

    private func setConnectionWanted(_ wanted: Bool) {
        connectionWanted.send(wanted)
    }

    private func withSessionLock<T>(_ body: () async -> T) async -> T {
        await sessionLock.acquire()
        let value = await body()
        sessionLock.release()
        return value
    }

    private func track<T>(_ task: Task<T, Never>) {
        cancelBackground.append { task.cancel() }
    }

    private func recoverer() -> SessionRecoverer {
        if let sessionRecoverer { return sessionRecoverer }
        let created = SessionRecoverer(
            identifyOnce: { [weak self] in
                await self?.identifyForSend(stale: nil) ?? .notIdentified
            },
            reidentifyOnce: { [weak self] stale in
                await self?.identifyForSend(stale: stale) ?? .notIdentified
            }
        )
        sessionRecoverer = created
        return created
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

/// Set when the host calls `identify` in this process. Stays set after `reset`:
/// a send before any identify is an integration bug and is logged once.
final class IdentifyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markCalled() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var called: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// One identify or reset at a time. A logout waits until the identify that already
/// holds it finishes, then wipes, so that identify cannot write a session afterwards.
private final class SessionLock: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        lock.lock()
        if !busy {
            busy = true
            lock.unlock()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
