import Combine
import XCTest
@testable import ChatwootSDK

final class FakeWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private(set) var sentTexts: [String] = []
    private(set) var closeCalls: [(code: Int, reason: String)] = []
    private(set) var cancelCalls = 0
    private(set) var connectCalls = 0
    private var continuations: [AsyncStream<SocketFrame>.Continuation] = []

    func connect() -> AsyncStream<SocketFrame> {
        connectCalls += 1
        return AsyncStream { continuations.append($0) }
    }

    func emit(_ frame: SocketFrame) {
        continuations.forEach { $0.yield(frame) }
    }

    func send(_ text: String) -> Bool {
        sentTexts.append(text)
        return true
    }

    func close(code: Int, reason: String) {
        closeCalls.append((code, reason))
    }

    func cancel() {
        cancelCalls += 1
    }
}

final class SocketConnectionManagerTests: XCTestCase {
    private var transport: FakeWebSocketTransport!
    private var manager: SocketConnectionManager!
    private var now: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        transport = FakeWebSocketTransport()
        now = 0
        manager = SocketConnectionManager(
            transport: transport,
            backoff: SocketBackoffStrategy(random: { 0.5 }),
            now: { [unowned self] in self.now }
        )
    }

    private func sleepMs(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    func testDesiredTrueOpensConnection() async {
        await manager.setDesired(true)
        await sleepMs(10)
        XCTAssertEqual(transport.connectCalls, 1)
        XCTAssertEqual(manager.state.value, .connecting)
    }

    func testOpenedMovesToConnectedAndPublishesStatus() async {
        let statuses = expectation(description: "statuses")
        var received: [SocketStatus] = []
        manager.status.sink { status in
            received.append(status)
            if status == .opened { statuses.fulfill() }
        }.store(in: &cancellables)

        await manager.setDesired(true)
        await sleepMs(10)
        transport.emit(.opened)
        await fulfillment(of: [statuses], timeout: 1)
        guard case .connected = manager.state.value else {
            return XCTFail("expected connected, got \(manager.state.value)")
        }
        XCTAssertEqual(received, [.opened])
    }

    func testFailureSchedulesRetryAndReconnects() async {
        await manager.setDesired(true)
        await sleepMs(10)
        struct E: Error {}
        transport.emit(.failed(E()))
        await sleepMs(10)
        guard case .waitingToRetry = manager.state.value else {
            return XCTFail("expected waitingToRetry, got \(manager.state.value)")
        }
        await sleepMs(600)
        XCTAssertEqual(transport.connectCalls, 2, "ретрай переоткрыл соединение")
    }

    func testDesiredFalseFromConnectedClosesGracefully() async {
        await manager.setDesired(true)
        await sleepMs(10)
        transport.emit(.opened)
        await sleepMs(10)
        await manager.setDesired(false)
        await sleepMs(10)
        XCTAssertEqual(transport.closeCalls.count, 1)
        XCTAssertEqual(transport.closeCalls[0].code, normalClosureCode)
        transport.emit(.closed(code: normalClosureCode, reason: ""))
        await sleepMs(10)
        XCTAssertEqual(manager.state.value, .disconnected)
    }

    func testSendForwardsToTransport() async {
        let sent = await manager.send("hello")
        XCTAssertTrue(sent)
        XCTAssertEqual(transport.sentTexts, ["hello"])
    }

    func testStableConnectionResetsAttempt() async {
        await manager.setDesired(true)
        await sleepMs(10)
        transport.emit(.opened)
        await sleepMs(10)
        now = SocketBackoffStrategy.stabilityWindowMs + 1
        struct E: Error {}
        transport.emit(.failed(E()))
        await sleepMs(10)
        guard case .waitingToRetry(let attempt, _) = manager.state.value else {
            return XCTFail("expected waitingToRetry, got \(manager.state.value)")
        }
        XCTAssertEqual(attempt, 0, "стабильная сессия сбросила счётчик")
    }
}
