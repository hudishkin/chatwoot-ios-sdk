import Combine
import Foundation

actor RealtimeController {
    nonisolated let typing = CurrentValueSubject<[Int: Bool], Never>([:])

    nonisolated let failedHandshakes = CurrentValueSubject<Int, Never>(0)

    nonisolated let closedByServer = CurrentValueSubject<Bool, Never>(false)

    nonisolated var isLive: Bool {
        if case .connected = socket.state.value, cable.subscription.value == .confirmed {
            return true
        }
        return false
    }

    private let socket: any SocketManaging
    private let cable: RoomChannelClient
    private let connectionWanted: CurrentValueSubject<Bool, Never>
    private let store: SessionStore
    private let sync: SyncManager
    private let messageDAO: MessageDAO
    private let conversationDAO: ConversationDAO
    private let inboxId: Int

    private var running = false
    private var token: String?
    private var epoch = 0
    private var typingTimeouts: [Int: Task<Void, Never>] = [:]
    private var bindTasks: [Task<Void, Never>] = []
    private let typingTimeoutMs: UInt64

    init(
        socket: any SocketManaging,
        cable: RoomChannelClient,
        connectionWanted: CurrentValueSubject<Bool, Never>,
        store: SessionStore,
        sync: SyncManager,
        messageDAO: MessageDAO,
        conversationDAO: ConversationDAO,
        inboxId: Int,
        typingTimeoutMs: UInt64 = RealtimeController.typingTimeoutMs
    ) {
        self.socket = socket
        self.cable = cable
        self.connectionWanted = connectionWanted
        self.store = store
        self.sync = sync
        self.messageDAO = messageDAO
        self.conversationDAO = conversationDAO
        self.inboxId = inboxId
        self.typingTimeoutMs = typingTimeoutMs
    }

    deinit {
        bindTasks.forEach { $0.cancel() }
    }

    func bind() {
        guard bindTasks.isEmpty else { return }
        _ = store.read()

        let status = socket.status.eagerValues()
        bindTasks.append(Task { [weak self] in
            for await value in status {
                guard let self else { return }
                switch value {
                case .failed: self.failedHandshakes.send(self.failedHandshakes.value + 1)
                case .opened: self.failedHandshakes.send(0)
                case .closed: break
                }
            }
        })

        bindTasks.append(Task { [weak self, wanted = connectionWanted, sessions = store.currentSubject] in
            let stream = Publishers.CombineLatest(wanted, sessions).map { ($0.0, $0.1) }.values
            for await (wanted, session) in stream {
                await self?.reconcile(wanted: wanted, session: session)
            }
        })

        bindTasks.append(Task { [weak self, subscription = cable.subscription] in
            for await state in subscription.values {
                guard let self else { return }
                if state == .confirmed {
                    _ = await self.sync.sync(.subscribed)
                } else {
                    self.typing.send([:])
                }
            }
        })

        let disconnects = cable.terminalDisconnects.eagerValues()
        bindTasks.append(Task { [weak self] in
            for await _ in disconnects {
                await self?.onTerminalDisconnect()
            }
        })

        let events = cable.events.eagerValues()
        bindTasks.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                let receivedUnder = await self.epoch
                do {
                    try await self.handle(event, epoch: receivedUnder)
                } catch {
                    CWLog.w(.cable, "event handling failed: \(type(of: error))")
                }
            }
        })
    }

    func stopNow() async {
        if running {
            await socket.setDesired(false)
            await cable.stop()
        }
        running = false
        token = nil
        typing.send([:])
        closedByServer.send(false)
    }

    private func onTerminalDisconnect() async {
        guard running else { return }
        await cable.stop()
        running = false
        token = nil
        typing.send([:])
        closedByServer.send(true)
        CWLog.i(.app, "realtime off: closed by the server")
    }

    private func reconcile(wanted: Bool, session: Session?) async {
        if wanted, let session {
            if !running {
                closedByServer.send(false)
                epoch = sync.currentEpoch
                await cable.start(pubsubToken: session.pubsubToken)
                await socket.setDesired(true)
                running = true
                CWLog.i(.app, "realtime on")
            } else if token != session.pubsubToken {
                epoch = sync.currentEpoch
                await cable.updateToken(session.pubsubToken)
            }
            token = session.pubsubToken
        } else if running {
            await socket.setDesired(false)
            await cable.stop()
            running = false
            token = nil
            typing.send([:])
            CWLog.i(.app, "realtime off")
        }
    }

    private func handle(_ event: RealtimeEvent, epoch: Int) async throws {
        switch event {
        case .messageCreated(let dto, let echoID):
            try await applyMessage(dto, echoID: echoID, epoch: epoch)
        case .messageUpdated(let dto):
            try await applyMessage(dto, echoID: nil, epoch: epoch)
        case .conversationStatusChanged(let id, let status, let inboxID):
            try await onConversation(id, eventInboxId: inboxID) {
                _ = try await self.sync.applyRealtime(epoch: epoch) {
                    try self.conversationDAO.updateStatus(id, status: status.rawValue)
                }
            }
        case .conversationUpdated(let id, let inboxID):
            try await onConversation(id, eventInboxId: inboxID) {}
        case .typing(let conversationID, let on, let inboxID):
            let local = try conversationDAO.get(conversationID)
            if (inboxID ?? local?.inboxId) == inboxId {
                onTyping(conversationID, on: on)
            } else {
                CWLog.d(.cable, "event dropped: other inbox")
            }
        }
    }

    private func onTyping(_ conversationId: Int, on: Bool) {
        typingTimeouts.removeValue(forKey: conversationId)?.cancel()
        if on {
            typingTimeouts[conversationId] = Task { [weak self, timeout = typingTimeoutMs] in
                try? await Task.sleep(nanoseconds: timeout * 1_000_000)
                guard !Task.isCancelled else { return }
                await self?.expireTyping(conversationId)
            }
        }
        var current = typing.value
        current[conversationId] = on
        typing.send(current)
    }

    private func expireTyping(_ conversationId: Int) {
        guard typing.value[conversationId] == true else { return }
        var current = typing.value
        current[conversationId] = false
        typing.send(current)
    }

    func catchUpWhileNotLive() async {
        let stream = Publishers.CombineLatest3(connectionWanted, socket.state, cable.subscription)
            .map { wanted, socketState, subscription -> Bool in
                if !wanted { return true }
                if case .connected = socketState, subscription == .confirmed { return true }
                return false
            }
            .removeDuplicates()
            .values
        var pollTask: Task<Void, Never>?
        defer { pollTask?.cancel() }
        for await idle in stream {
            pollTask?.cancel()
            pollTask = nil
            guard !idle else { continue }
            pollTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.downGraceMs * 1_000_000)
                while !Task.isCancelled {
                    guard let self else { return }
                    CWLog.d(.sync, "realtime down, periodic catch-up")
                    _ = await self.sync.sync(.refresh)
                    try? await Task.sleep(nanoseconds: Self.pollIntervalMs * 1_000_000)
                }
            }
        }
    }

    private func applyMessage(_ dto: MessageDTO, echoID: String?, epoch: Int) async throws {
        guard let conversationId = dto.conversationID else {
            CWLog.d(.cable, "event dropped: no id")
            return
        }
        try await onConversation(conversationId, eventInboxId: dto.inboxID) {
            guard let (entity, attachments) = dto.toEntities() else {
                CWLog.d(.cable, "event dropped: no id")
                return
            }
            _ = try await self.sync.applyRealtime(epoch: epoch) {
                try self.messageDAO.applyServerMessage(entity, attachments: attachments, echoId: echoID)
            }
        }
    }

    private func onConversation(_ id: Int, eventInboxId: Int?, whenKnown: () async throws -> Void) async throws {
        let local = try conversationDAO.get(id)
        guard (eventInboxId ?? local?.inboxId) == inboxId else {
            CWLog.d(.cable, "event dropped: other inbox")
            return
        }
        guard local != nil else {
            Task { [sync] in _ = await sync.sync(.discover) }
            return
        }
        try await whenKnown()
    }

    static let typingTimeoutMs: UInt64 = 30_000
    static let downGraceMs: UInt64 = 15_000
    static let pollIntervalMs: UInt64 = 45_000
}
