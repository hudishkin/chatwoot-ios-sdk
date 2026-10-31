import Combine
import XCTest
@testable import ChatwootSDK

final class FakeSocketManaging: SocketManaging, @unchecked Sendable {
    let frames = PassthroughSubject<SocketFrame, Never>()
    let status = PassthroughSubject<SocketStatus, Never>()
    let state = CurrentValueSubject<SocketConnectionState, Never>(.disconnected)

    private(set) var sent: [String] = []
    private(set) var desiredHistory: [Bool] = []
    private(set) var reconnectReasons: [String] = []

    func setDesired(_ connected: Bool) async {
        desiredHistory.append(connected)
    }

    func send(_ text: String) async -> Bool {
        sent.append(text)
        return true
    }

    func reconnectNow(reason: String) async {
        reconnectReasons.append(reason)
    }

    func startWatchdog() async {}
    func stopWatchdog() async {}
    func networkAvailable() async {}
    func stop() async {}
}

final class RoomChannelClientTests: XCTestCase {
    private var socket: FakeSocketManaging!
    private var cable: RoomChannelClient!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        socket = FakeSocketManaging()
        cable = RoomChannelClient(
            socket: socket,
            timers: RoomChannelClient.Timers(
                pingTimeoutMs: 60_000,
                confirmTimeoutMs: 60,
                presenceIntervalMs: 60,
                rejectBaseDelayMs: 10,
                rejectMaxDelayMs: 100
            )
        )
        socket.state.send(.connected(since: 0))
    }

    private func sleepMs(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func sendText(_ text: String) {
        socket.frames.send(.text(text))
    }

    private func waitForSubscription(pubsubToken: String = "tok", file: StaticString = #filePath, line: UInt = #line) async {
        let frame = CableCodec.subscribeFrame(pubsubToken: pubsubToken)
        for _ in 0..<50 {
            if socket.sent.contains(frame) { return }
            sendText(#"{"type":"welcome"}"#)
            await sleepMs(10)
        }
        XCTFail("клиент не подписался", file: file, line: line)
    }

    func testSubscribeAfterWelcome() async {
        await cable.start(pubsubToken: "tok")
        await sleepMs(20)
        XCTAssertTrue(socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok")))
    }

    func testSubscribeWaitsForWelcomeWhenDisconnected() async {
        socket.state.send(.disconnected)
        await cable.start(pubsubToken: "tok")
        await sleepMs(20)
        XCTAssertFalse(socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok")))
        socket.frames.send(.opened)
        await waitForSubscription()
    }

    func testConfirmMovesToConfirmedAndStartsPresence() async {
        await cable.start(pubsubToken: "tok")
        await cable.setPresenceWanted(true)
        await waitForSubscription()
        let identifier = CableCodec.identifier(pubsubToken: "tok")
        let confirm = try! JSONSerialization.data(withJSONObject: ["type": "confirm_subscription", "identifier": identifier])
        sendText(String(data: confirm, encoding: .utf8)!)
        await sleepMs(20)
        XCTAssertEqual(cable.subscription.value, .confirmed)
        XCTAssertTrue(socket.sent.contains(CableCodec.presenceFrame(pubsubToken: "tok")), "presence пошёл после confirm")
    }

    func testNoConfirmReconnects() async {
        await cable.start(pubsubToken: "tok")
        await sleepMs(120)
        XCTAssertEqual(socket.reconnectReasons, ["confirm_timeout"])
        XCTAssertEqual(cable.missedConfirms.value, 1)
    }

    func testRejectReconnectsWithBackoff() async {
        await cable.start(pubsubToken: "tok")
        await waitForSubscription()
        let identifier = CableCodec.identifier(pubsubToken: "tok")
        let reject = try! JSONSerialization.data(withJSONObject: ["type": "reject_subscription", "identifier": identifier])
        sendText(String(data: reject, encoding: .utf8)!)
        await sleepMs(10)
        XCTAssertEqual(cable.subscription.value, .rejected)
        await sleepMs(60)
        XCTAssertEqual(socket.reconnectReasons, ["rejected"])
    }

    func testMessageCreatedEventEmitted() async {
        let received = expectation(description: "event")
        var event: RealtimeEvent?
        cable.events.sink { value in
            event = value
            received.fulfill()
        }.store(in: &cancellables)

        await cable.start(pubsubToken: "tok")
        await waitForSubscription()
        let identifier = CableCodec.identifier(pubsubToken: "tok")
        let frame = try! JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "message": [
                "event": "message.created",
                "data": ["id": 101, "content": "hi", "message_type": 1, "conversation_id": 7, "sender": ["type": "user"]]
            ]
        ])
        sendText(String(data: frame, encoding: .utf8)!)
        await fulfillment(of: [received], timeout: 1)
        guard case .messageCreated(let dto, _)? = event else {
            return XCTFail("expected messageCreated, got \(String(describing: event))")
        }
        XCTAssertEqual(dto.id, 101)
    }

    func testForeignIdentifierIgnored() async {
        await cable.start(pubsubToken: "tok")
        await waitForSubscription()
        let foreignIdentifier = CableCodec.identifier(pubsubToken: "someone-else")
        let confirm = try! JSONSerialization.data(withJSONObject: ["type": "confirm_subscription", "identifier": foreignIdentifier])
        sendText(String(data: confirm, encoding: .utf8)!)
        await sleepMs(20)
        XCTAssertEqual(cable.subscription.value, .subscribing, "чужой confirm проигнорирован")
    }

    func testTerminalDisconnectStopsSocketAndReports() async {
        let received = expectation(description: "terminal")
        var reason: String?
        cable.terminalDisconnects.sink { value in
            reason = value
            received.fulfill()
        }.store(in: &cancellables)

        await cable.start(pubsubToken: "tok")
        await waitForSubscription()
        sendText(#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#)
        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(reason, "unauthorized")
        await sleepMs(10)
        XCTAssertEqual(socket.desiredHistory, [false], "сокет остановлен сервером навсегда")
    }

    func testUnknownReasonSanitized() async {
        var reasons: [String] = []
        cable.terminalDisconnects.sink { reasons.append($0) }.store(in: &cancellables)

        await cable.start(pubsubToken: "tok")
        await waitForSubscription()
        sendText(#"{"type":"disconnect","reason":"weird server text","reconnect":false}"#)
        await sleepMs(50)
        XCTAssertEqual(reasons, ["other"], "свободный текст сервера не пересылается")
    }

    func testUpdateTokenResubscribes() async {
        await cable.start(pubsubToken: "tok")
        await waitForSubscription()
        await cable.updateToken("tok-2")
        await sleepMs(20)
        XCTAssertTrue(socket.sent.contains(CableCodec.unsubscribeFrame(pubsubToken: "tok")))
        XCTAssertTrue(socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok-2")))
    }
}
