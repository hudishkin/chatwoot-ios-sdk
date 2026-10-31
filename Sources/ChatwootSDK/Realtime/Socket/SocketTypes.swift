import Foundation

let normalClosureCode = 1000

enum DesiredState: Equatable {
    case started, stopped
}

enum SocketConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(since: UInt64)
    case waitingToRetry(attempt: Int, delayMs: UInt64)
    case disconnecting
}

enum SocketStatus: String, Sendable {
    case opened = "OPENED"
    case closed = "CLOSED"
    case failed = "FAILED"
}

enum SocketFrame {
    case opened
    case text(String)
    case closed(code: Int, reason: String)
    case failed(Error)
}

enum SocketMachineEvent {
    case desiredChanged(DesiredState)
    case connectionOpened(atMs: UInt64)
    case connectionClosed(code: Int)
    case connectionFailed(Error)
    case retryTimerFired
    case forceReconnect(reason: String)
    case closeTimedOut

    var label: String {
        switch self {
        case .desiredChanged(let desired): return "DesiredChanged(\(desired == .started ? "Started" : "Stopped"))"
        case .connectionOpened: return "ConnectionOpened"
        case .connectionClosed(let code): return "ConnectionClosed(\(code))"
        case .connectionFailed(let error): return "ConnectionFailed(\(type(of: error)))"
        case .retryTimerFired: return "RetryTimerFired"
        case .forceReconnect(let reason): return "ForceReconnect(\(reason))"
        case .closeTimedOut: return "CloseTimedOut"
        }
    }
}

enum SocketSideEffect: Equatable {
    case openConnection
    case closeConnection(code: Int)
    case cancelConnection
    case scheduleRetry(attempt: Int, delayMs: UInt64)
    case cancelRetryTimer
    case startWatchdog
    case stopWatchdog
    case publishStatus(SocketStatus)
    case logInvalidTransition(state: String, event: String)
}

struct SocketTransition {
    let state: SocketConnectionState
    let effects: [SocketSideEffect]
}

struct RetryPlan {
    let attempt: Int
    let delayMs: UInt64
}

extension SocketConnectionState {
    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .waitingToRetry(let attempt, let delayMs): return "WaitingToRetry(\(attempt),\(delayMs))"
        case .disconnecting: return "Disconnecting"
        }
    }
}
