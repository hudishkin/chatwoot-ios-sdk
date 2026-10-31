import Combine
import Foundation

protocol SocketManaging: Sendable {
    nonisolated var frames: PassthroughSubject<SocketFrame, Never> { get }
    nonisolated var status: PassthroughSubject<SocketStatus, Never> { get }
    nonisolated var state: CurrentValueSubject<SocketConnectionState, Never> { get }

    func setDesired(_ connected: Bool) async
    @discardableResult
    func send(_ text: String) async -> Bool
    func reconnectNow(reason: String) async
    func startWatchdog() async
    func stopWatchdog() async
    func networkAvailable() async
    func stop() async
}

actor SocketConnectionManager: SocketManaging {
    nonisolated let frames = PassthroughSubject<SocketFrame, Never>()
    nonisolated let status = PassthroughSubject<SocketStatus, Never>()
    nonisolated let state: CurrentValueSubject<SocketConnectionState, Never>

    private let transport: WebSocketTransport
    private var backoff: SocketBackoffStrategy
    private let machine: SocketStateMachine
    private let now: () -> UInt64

    private var connectionTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var closeTimeoutTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var silentTicks = 0
    private var attempt = 0

    private var watchdogEnabled = true
    private var stopped = false

    static let silenceThresholdMs: UInt64 = 90_000
    static let closeTimeoutMs: UInt64 = 5_000
    private static let watchdogTickMs: UInt64 = 1_000

    init(
        transport: WebSocketTransport,
        backoff: SocketBackoffStrategy = SocketBackoffStrategy(),
        now: @escaping () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.transport = transport
        self.backoff = backoff
        self.machine = SocketStateMachine(initial: .disconnected)
        self.state = CurrentValueSubject(.disconnected)
        self.now = now
    }

    func setDesired(_ connected: Bool) {
        guard !stopped else { return }
        let desired: DesiredState = connected ? .started : .stopped
        guard desired != machine.desired else { return }
        CWLog.i(.ws, "desired=\(desired == .started ? "Started" : "Stopped")")
        process(.desiredChanged(desired))
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        let sent = transport.send(text)
        if !sent { CWLog.d(.ws, "send failed: no active connection") }
        return sent
    }

    func reconnectNow(reason: String) {
        process(.forceReconnect(reason: reason))
    }

    func startWatchdog() {
        watchdogEnabled = true
        runStartWatchdog()
    }

    func stopWatchdog() {
        watchdogEnabled = false
        runStopWatchdog()
    }

    func networkAvailable() {
        switch machine.state {
        case .waitingToRetry:
            CWLog.i(.ws, "netAvailable -> retry now")
            cancelRetryTimer()
            attempt = 0
            process(.retryTimerFired)
        case .connected:
            CWLog.i(.ws, "netAvailable -> reconnect")
            process(.forceReconnect(reason: "network-back"))
        default:
            break
        }
    }

    func stop() {
        stopped = true
        connectionTask?.cancel()
        connectionTask = nil
        retryTask?.cancel()
        retryTask = nil
        closeTimeoutTask?.cancel()
        closeTimeoutTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        transport.cancel()
    }

    private func process(_ event: SocketMachineEvent) {
        if case .desiredChanged(.started) = event {
            attempt = 0
        }
        if case .connectionOpened(let atMs) = event {
            backoff.onConnectionOpened(atMs: atMs)
        }
        if isTermination(event) {
            closeTimeoutTask?.cancel()
            closeTimeoutTask = nil
            if backoff.onConnectionClosed(atMs: now()) {
                attempt = 0
            }
        }
        let previous = machine.state
        let transition = machine.transition(event) { self.nextRetryPlan() }
        if previous != transition.state {
            CWLog.i(.ws, "state \(previous.label)->\(transition.state.label) on=\(event.label)")
        }
        state.send(transition.state)
        let closeReason: String
        if case .forceReconnect(let reason) = event {
            closeReason = reason
        } else {
            closeReason = "user"
        }
        for effect in transition.effects {
            execute(effect, closeReason: closeReason)
        }
    }

    private func isTermination(_ event: SocketMachineEvent) -> Bool {
        switch event {
        case .connectionClosed, .connectionFailed, .closeTimedOut:
            return true
        default:
            return false
        }
    }

    private func execute(_ effect: SocketSideEffect, closeReason: String) {
        switch effect {
        case .openConnection:
            openConnection()
        case .closeConnection(let code):
            closeConnection(code: code, reason: closeReason)
        case .cancelConnection:
            cancelConnection()
        case .scheduleRetry(let retryAttempt, let delayMs):
            scheduleRetry(attempt: retryAttempt, delayMs: delayMs)
        case .cancelRetryTimer:
            cancelRetryTimer()
        case .startWatchdog:
            if watchdogEnabled { runStartWatchdog() }
        case .stopWatchdog:
            runStopWatchdog()
        case .publishStatus(let socketStatus):
            status.send(socketStatus)
        case .logInvalidTransition(let stateLabel, let eventLabel):
            CWLog.w(.ws, "invalid transition: state=\(stateLabel) event=\(eventLabel)")
        }
    }

    private func openConnection() {
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.transport.connect()
            for await frame in stream {
                await self.dispatch(frame)
            }
        }
    }

    private func dispatch(_ frame: SocketFrame) {
        switch frame {
        case .opened:
            silentTicks = 0
            process(.connectionOpened(atMs: now()))
        case .text:
            silentTicks = 0
        case .closed(let code, _):
            process(.connectionClosed(code: code))
        case .failed(let error):
            process(.connectionFailed(error))
        }
        frames.send(frame)
    }

    private func closeConnection(code: Int, reason: String) {
        CWLog.i(.ws, "closing code=\(code) reason=\(reason)")
        transport.close(code: code, reason: reason)
        armCloseTimeout()
    }

    private func armCloseTimeout() {
        closeTimeoutTask?.cancel()
        closeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.closeTimeoutMs * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.process(.closeTimedOut)
        }
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        closeTimeoutTask?.cancel()
        closeTimeoutTask = nil
        transport.cancel()
        if machine.state == .disconnecting {
            process(.connectionClosed(code: normalClosureCode))
        }
    }

    private func scheduleRetry(attempt retryAttempt: Int, delayMs: UInt64) {
        CWLog.i(.ws, "retry attempt=\(retryAttempt) in=\(delayMs)")
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.process(.retryTimerFired)
        }
    }

    private func cancelRetryTimer() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func runStartWatchdog() {
        watchdogTask?.cancel()
        silentTicks = 0
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.watchdogTickMs * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.processWatchdogTick()
            }
        }
    }

    private func runStopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        silentTicks = 0
    }

    private func processWatchdogTick() {
        guard case .connected = machine.state else {
            runStopWatchdog()
            return
        }
        silentTicks += 1
        if UInt64(silentTicks) * Self.watchdogTickMs >= Self.silenceThresholdMs {
            silentTicks = 0
            CWLog.w(.ws, "watchdog silence=\(Self.silenceThresholdMs / 1000)s -> reconnect")
            process(.forceReconnect(reason: "silence"))
        }
    }

    private func nextRetryPlan() -> RetryPlan {
        let plan = RetryPlan(attempt: attempt, delayMs: backoff.nextDelayMs(attempt: attempt))
        attempt += 1
        return plan
    }
}
