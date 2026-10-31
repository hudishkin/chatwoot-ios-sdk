import XCTest
@testable import ChatwootSDK

final class ConnectionBannerTests: XCTestCase {
    func testNoNetworkShowsOfflineWhateverTheSocket() {
        XCTAssertEqual(connectionBanner(transportAvailable: false, socket: .connected(since: 1)), .offline)
        XCTAssertEqual(connectionBanner(transportAvailable: false, socket: .disconnected), .offline)
    }

    func testNetworkAndReconnectingSocketShowsConnecting() {
        XCTAssertEqual(connectionBanner(transportAvailable: true, socket: .connecting), .connecting)
        XCTAssertEqual(
            connectionBanner(transportAvailable: true, socket: .waitingToRetry(attempt: 2, delayMs: 1000)),
            .connecting
        )
    }

    func testFailingHandshakesShowLiveUpdatesUnavailableUnlessOfflineOrConnected() {
        let waiting = SocketConnectionState.waitingToRetry(attempt: 3, delayMs: 4000)
        XCTAssertEqual(connectionBanner(transportAvailable: true, socket: waiting, failedHandshakes: 2), .connecting)
        XCTAssertEqual(connectionBanner(transportAvailable: true, socket: waiting, failedHandshakes: 3), .liveUpdatesUnavailable)
        XCTAssertEqual(
            connectionBanner(transportAvailable: true, socket: .connecting, failedHandshakes: 5),
            .liveUpdatesUnavailable
        )
        XCTAssertEqual(connectionBanner(transportAvailable: false, socket: waiting, failedHandshakes: 5), .offline)
        XCTAssertEqual(
            connectionBanner(transportAvailable: true, socket: .connected(since: 1), failedHandshakes: 5),
            .none
        )
    }

    func testConnectedOrStoppedSocketShowsNoBanner() {
        XCTAssertEqual(connectionBanner(transportAvailable: true, socket: .connected(since: 1)), .none)
        XCTAssertEqual(connectionBanner(transportAvailable: true, socket: .disconnected), .none)
    }

    func testServerClosedCableShowsLiveUpdatesUnavailableUnlessOffline() {
        XCTAssertEqual(
            connectionBanner(transportAvailable: true, socket: .disconnected, closedByServer: true),
            .liveUpdatesUnavailable
        )
        XCTAssertEqual(
            connectionBanner(transportAvailable: false, socket: .disconnected, closedByServer: true),
            .offline
        )
        XCTAssertEqual(
            connectionBanner(transportAvailable: true, socket: .connected(since: 1), closedByServer: true),
            .none
        )
    }
}
