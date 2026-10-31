import Foundation

enum ConnectionBanner: Equatable {
    case none, connecting, offline, liveUpdatesUnavailable
}

let liveUnavailableAfter = 3

func connectionBanner(
    transportAvailable: Bool,
    socket: SocketConnectionState,
    failedHandshakes: Int = 0,
    closedByServer: Bool = false
) -> ConnectionBanner {
    guard transportAvailable else { return .offline }
    if closedByServer || failedHandshakes >= liveUnavailableAfter {
        if case .connected = socket {} else { return .liveUpdatesUnavailable }
    }
    switch socket {
    case .connecting, .waitingToRetry:
        return .connecting
    case .disconnected, .connected, .disconnecting:
        return .none
    }
}
