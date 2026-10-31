import XCTest
@testable import ChatwootSDK

final class SocketStateMachineTests: XCTestCase {
    private var machine: SocketStateMachine!
    private var plan: RetryPlan!

    override func setUp() {
        super.setUp()
        machine = SocketStateMachine(initial: .disconnected)
        plan = RetryPlan(attempt: 0, delayMs: 1_000)
    }

    private func transition(_ event: SocketMachineEvent) -> SocketTransition {
        machine.transition(event) { self.plan }
    }

    func testDisconnectedToConnectingOnStart() {
        let t = transition(.desiredChanged(.started))
        XCTAssertEqual(t.state, .connecting)
        XCTAssertEqual(t.effects, [.openConnection])
    }

    func testStoppedStaysDisconnected() {
        let t = transition(.desiredChanged(.stopped))
        XCTAssertEqual(t.state, .disconnected)
        XCTAssertEqual(t.effects, [])
    }

    func testOpenedMovesToConnected() {
        _ = transition(.desiredChanged(.started))
        let t = transition(.connectionOpened(atMs: 100))
        XCTAssertEqual(t.state, .connected(since: 100))
        XCTAssertEqual(t.effects, [.publishStatus(.opened), .startWatchdog])
    }

    func testFailureWhileConnectingRetriesWhenStarted() {
        _ = transition(.desiredChanged(.started))
        struct E: Error {}
        let t = transition(.connectionFailed(E()))
        XCTAssertEqual(t.state, .waitingToRetry(attempt: 0, delayMs: 1_000))
        XCTAssertEqual(t.effects, [.publishStatus(.failed), .scheduleRetry(attempt: 0, delayMs: 1_000)])
    }

    func testFailureWhileConnectingStopsWhenStopped() {
        _ = transition(.desiredChanged(.started))
        _ = transition(.desiredChanged(.stopped))
        struct E: Error {}
        let t = transition(.connectionFailed(E()))
        XCTAssertEqual(t.state, .disconnected)
        XCTAssertEqual(t.effects, [.publishStatus(.closed)], "закрытие по нашей инициативе при .stopped публикует CLOSED")
    }

    func testConnectedFailureRetriesWithWatchdogStop() {
        _ = transition(.desiredChanged(.started))
        _ = transition(.connectionOpened(atMs: 100))
        struct E: Error {}
        let t = transition(.connectionFailed(E()))
        XCTAssertEqual(t.state, .waitingToRetry(attempt: 0, delayMs: 1_000))
        XCTAssertEqual(t.effects, [.publishStatus(.failed), .stopWatchdog, .scheduleRetry(attempt: 0, delayMs: 1_000)])
    }

    func testConnectedStopClosesGracefully() {
        _ = transition(.desiredChanged(.started))
        _ = transition(.connectionOpened(atMs: 100))
        let t = transition(.desiredChanged(.stopped))
        XCTAssertEqual(t.state, .disconnecting)
        XCTAssertEqual(t.effects, [.closeConnection(code: normalClosureCode), .stopWatchdog])
        let closed = transition(.connectionClosed(code: normalClosureCode))
        XCTAssertEqual(closed.state, .disconnected)
        XCTAssertEqual(closed.effects, [.publishStatus(.closed)])
    }

    func testForceReconnectDoesNotPublishClosed() {
        _ = transition(.desiredChanged(.started))
        _ = transition(.connectionOpened(atMs: 100))
        let t = transition(.forceReconnect(reason: "silence"))
        XCTAssertEqual(t.state, .disconnecting)
        XCTAssertEqual(t.effects, [.closeConnection(code: normalClosureCode)], "без stopWatchdog: флаг поднимется снова")
        let closed = transition(.connectionClosed(code: normalClosureCode))
        XCTAssertEqual(closed.state, .connecting)
        XCTAssertEqual(closed.effects, [.openConnection], "без CLOSED при .started: баннер не мигает на реконнекте")
    }

    func testRetryTimerFiredReconnects() {
        _ = transition(.desiredChanged(.started))
        struct E: Error {}
        _ = transition(.connectionFailed(E()))
        let t = transition(.retryTimerFired)
        XCTAssertEqual(t.state, .connecting)
        XCTAssertEqual(t.effects, [.openConnection])
    }

    func testWaitingToRetryStopCancelsTimer() {
        _ = transition(.desiredChanged(.started))
        struct E: Error {}
        _ = transition(.connectionFailed(E()))
        let t = transition(.desiredChanged(.stopped))
        XCTAssertEqual(t.state, .disconnected)
        XCTAssertEqual(t.effects, [.cancelRetryTimer])
    }

    func testCloseTimedOutCancelsAndReconnects() {
        _ = transition(.desiredChanged(.started))
        _ = transition(.connectionOpened(atMs: 100))
        _ = transition(.forceReconnect(reason: "watchdog"))
        let t = transition(.closeTimedOut)
        XCTAssertEqual(t.state, .connecting)
        XCTAssertEqual(t.effects, [.cancelConnection, .openConnection])
    }

    func testInvalidTransitionIsLogged() {
        let t = transition(.connectionOpened(atMs: 1))
        XCTAssertEqual(t.state, .disconnected)
        guard case .some(.logInvalidTransition(let state, let event)) = t.effects.first else {
            return XCTFail("expected logInvalidTransition, got \(t.effects)")
        }
        XCTAssertEqual(state, "Disconnected")
        XCTAssertEqual(event, "ConnectionOpened")
    }
}
