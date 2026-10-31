import Combine
import Foundation

actor RoomChannelClient {
    struct Timers: Sendable {
        var pingTimeoutMs: UInt64 = 10_000
        var confirmTimeoutMs: UInt64 = 10_000
        var presenceIntervalMs: UInt64 = 15_000
        var rejectBaseDelayMs: UInt64 = 1_000
        var rejectMaxDelayMs: UInt64 = 60_000

        static let `default` = Timers()
    }

    nonisolated let events = PassthroughSubject<RealtimeEvent, Never>()
    nonisolated let subscription = CurrentValueSubject<SubscriptionState, Never>(.idle)
    nonisolated let missedConfirms = CurrentValueSubject<Int, Never>(0)

    nonisolated let terminalDisconnects = PassthroughSubject<String, Never>()

    private let socket: any SocketManaging
    private let timers: Timers

    private var collectTask: Task<Void, Never>?
    private var confirmTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var rejectTask: Task<Void, Never>?
    private var pubsubToken: String?
    private var presenceOn = false

    private static let backoffAfterMisses = 3

    init(socket: any SocketManaging, timers: Timers = .default) {
        self.socket = socket
        self.timers = timers
    }

    func setPresenceWanted(_ wanted: Bool) {
        presenceOn = wanted
        syncPresence()
    }

    func start(pubsubToken: String) {
        stopInternal()
        self.pubsubToken = pubsubToken
        missedConfirms.send(0)
        let frames = socket.frames
        collectTask = Task { [weak self] in
            for await frame in frames.values {
                await self?.handleFrame(frame)
            }
        }
        if case .connected = socket.state.value {
            armWatchdog()
            subscribe()
        }
    }

    func stop() {
        stopInternal()
    }

    func updateToken(_ newToken: String) async {
        guard let old = pubsubToken, old != newToken else { return }
        let wasSubscribed = subscription.value != .idle
        if wasSubscribed {
            await socket.send(CableCodec.unsubscribeFrame(pubsubToken: old))
        }
        cancelRejectTask()
        pubsubToken = newToken
        missedConfirms.send(0)
        resetSubscription()
        if case .connected = socket.state.value {
            subscribe()
        }
        CWLog.i(.cable, "token updated, resubscribing")
    }

    // MARK: - Private

    private func stopInternal() {
        collectTask?.cancel()
        collectTask = nil
        resetSubscription()
        cancelWatchdog()
        cancelRejectTask()
        pubsubToken = nil
    }

    private func handleFrame(_ frame: SocketFrame) {
        switch frame {
        case .opened:
            cancelRejectTask()
            resetSubscription()
            armWatchdog()
        case .closed, .failed:
            cancelRejectTask()
            resetSubscription()
            cancelWatchdog()
        case .text(let text):
            armWatchdog()
            handleText(text)
        }
    }

    private func handleText(_ text: String) {
        guard let message = CableCodec.decode(text) else {
            CWLog.d(.cable, "undecodable frame")
            return
        }
        switch message {
        case .welcome:
            subscribe()
        case .ping:
            break
        case .confirm(let identifier):
            if isOurs(identifier, lenient: false) { onConfirmed() }
        case .reject(let identifier):
            if isOurs(identifier, lenient: false) { onRejected() }
        case .disconnect(let reason, let reconnect):
            onDisconnect(reason: reason, reconnect: reconnect)
        case .event(let name, let data, let identifier):
            if isOurs(identifier) { handleEvent(name: name, data: data) }
        }
    }

    private func onDisconnect(reason: String?, reconnect: Bool) {
        let sanitized = DisconnectReason.sanitize(reason)
        CWLog.w(.cable, "server disconnect reason=\(sanitized) reconnect=\(reconnect)")
        guard !reconnect else { return }
        cancelRejectTask()
        resetSubscription()
        cancelWatchdog()
        Task { await socket.setDesired(false) }
        terminalDisconnects.send(sanitized)
    }

    private func isOurs(_ identifier: String?, lenient: Bool = true) -> Bool {
        guard let token = pubsubToken else { return false }
        let ours = (identifier == nil && lenient) || identifier == CableCodec.identifier(pubsubToken: token)
        if !ours { CWLog.d(.cable, "foreign identifier ignored") }
        return ours
    }

    private func subscribe() {
        guard let token = pubsubToken else { return }
        cancelSubscriptionTasks()
        subscription.send(.subscribing)
        Task {
            let sent = await socket.send(CableCodec.subscribeFrame(pubsubToken: token))
            CWLog.d(.cable, sent ? "subscribe sent" : "subscribe not sent")
        }
        confirmTask = Task { [weak self, timeout = timers.confirmTimeoutMs] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.confirmTimedOut(timeout: timeout)
        }
    }

    private func confirmTimedOut(timeout: UInt64) {
        missedConfirms.send(missedConfirms.value + 1)
        let misses = missedConfirms.value
        if misses < Self.backoffAfterMisses {
            CWLog.w(.cable, "no confirm in \(timeout)ms, reconnecting")
            Task { await socket.reconnectNow(reason: "confirm_timeout") }
        } else {
            let wait = rejectDelayMs(misses: misses - Self.backoffAfterMisses + 1)
            CWLog.w(.cable, "no confirm in \(timeout)ms (\(misses) in a row), reconnecting in \(wait)ms")
            cancelRejectTask()
            rejectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: wait * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.socket.reconnectNow(reason: "confirm_timeout")
            }
        }
    }

    private func onRejected() {
        cancelSubscriptionTasks()
        subscription.send(.rejected)
        missedConfirms.send(missedConfirms.value + 1)
        let delayMs = rejectDelayMs(misses: missedConfirms.value)
        CWLog.w(.cable, "subscription rejected, reconnecting in \(delayMs)ms")
        cancelRejectTask()
        rejectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.socket.reconnectNow(reason: "rejected")
        }
    }

    private func onConfirmed() {
        guard pubsubToken != nil else { return }
        confirmTask?.cancel()
        confirmTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        missedConfirms.send(0)
        subscription.send(.confirmed)
        CWLog.i(.cable, "subscription confirmed")
        syncPresence()
    }

    private func syncPresence() {
        guard presenceOn, let token = pubsubToken, subscription.value == .confirmed else {
            presenceTask?.cancel()
            presenceTask = nil
            return
        }
        guard presenceTask == nil else { return }
        presenceTask = Task { [weak self, interval = timers.presenceIntervalMs] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.socket.send(CableCodec.presenceFrame(pubsubToken: token))
                try? await Task.sleep(nanoseconds: interval * 1_000_000)
            }
        }
    }

    private func armWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self, timeout = timers.pingTimeoutMs] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            CWLog.w(.cable, "no ping in \(timeout)ms, reconnecting")
            await self.socket.reconnectNow(reason: "watchdog")
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func cancelRejectTask() {
        rejectTask?.cancel()
        rejectTask = nil
    }

    private func cancelSubscriptionTasks() {
        confirmTask?.cancel()
        confirmTask = nil
        presenceTask?.cancel()
        presenceTask = nil
    }

    private func resetSubscription() {
        cancelSubscriptionTasks()
        subscription.send(.idle)
    }

    private func handleEvent(name: String, data: [String: JSONValue]) {
        guard let event = RealtimeEvent.fromCableEvent(name: name, data: data) else {
            CWLog.d(.cable, "event dropped: \(name)")
            return
        }
        events.send(event)
    }

    private func rejectDelayMs(misses: Int) -> UInt64 {
        let shift = min(max(misses - 1, 0), 16)
        return min(timers.rejectBaseDelayMs << shift, timers.rejectMaxDelayMs)
    }
}

enum DisconnectReason {
    private static let known: Set<String> = ["unauthorized", "invalid_request", "server_restart", "remote"]

    static func sanitize(_ reason: String?) -> String {
        guard let reason, known.contains(reason) else { return "other" }
        return reason
    }
}
