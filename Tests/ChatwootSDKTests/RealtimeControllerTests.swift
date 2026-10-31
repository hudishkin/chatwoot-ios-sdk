import Combine
import XCTest
@testable import ChatwootSDK

final class RealtimeControllerTests: XCTestCase {
    private var socket: FakeSocketManaging!
    private var cable: RoomChannelClient!
    private var api: MockChatwootAPI!
    private var database: ChatwootDatabase!
    private var store: SessionStore!
    private var sessionGuard: SessionGuard!
    private var sync: SyncManager!
    private var wanted: CurrentValueSubject<Bool, Never>!
    private var controller: RealtimeController!

    override func setUp() async throws {
        try await super.setUp()
        socket = FakeSocketManaging()
        cable = RoomChannelClient(
            socket: socket,
            timers: RoomChannelClient.Timers(
                pingTimeoutMs: 60_000,
                confirmTimeoutMs: 60_000,
                presenceIntervalMs: 60_000,
                rejectBaseDelayMs: 60_000,
                rejectMaxDelayMs: 60_000
            )
        )
        api = MockChatwootAPI()
        database = try ChatwootDatabase.inMemory()
        store = SessionStore(directory: Fixtures.makeTempDirectory())
        try store.write(Fixtures.session)
        sessionGuard = SessionGuard()
        sync = SyncManager(
            api: api,
            inboxIdentifier: "inbox-1",
            inboxId: 1,
            store: store,
            messageDAO: database.messages,
            sessionGuard: sessionGuard
        )
        wanted = CurrentValueSubject<Bool, Never>(false)
        controller = RealtimeController(
            socket: socket,
            cable: cable,
            connectionWanted: wanted,
            store: store,
            sync: sync,
            messageDAO: database.messages,
            conversationDAO: database.conversations,
            inboxId: 1,
            typingTimeoutMs: 60
        )
        await controller.bind()
        socket.state.send(.connected(since: 0))
    }

    private func sleepMs(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await sleepMs(10)
        }
        XCTAssertTrue(condition(), "условие не наступило за 2с", file: file, line: line)
    }

    private func sendText(_ text: String) {
        socket.frames.send(.text(text))
    }

    private func sendEvent(name: String, data: [String: Any], pubsubToken: String = "tok-1") {
        let frame = try! JSONSerialization.data(withJSONObject: [
            "identifier": CableCodec.identifier(pubsubToken: pubsubToken),
            "message": ["event": name, "data": data]
        ])
        sendText(String(data: frame, encoding: .utf8)!)
    }

    private func startRealtime(file: StaticString = #filePath, line: UInt = #line) async {
        wanted.send(true)
        await eventually(file: file, line: line) {
            self.socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok-1"))
        }
    }

    func testStartsCableWhenWantedAndSessionPresent() async {
        await startRealtime()
        XCTAssertEqual(socket.desiredHistory, [true], "кабель стартовал до открытия сокета")
    }

    func testStopsWhenNoLongerWanted() async {
        await startRealtime()
        wanted.send(false)
        await eventually { self.socket.desiredHistory == [true, false] }
    }

    func testTokenChangeResubscribes() async {
        await startRealtime()
        try! store.write(Session(identifier: "user-42", identifierHash: "hash-42", sourceID: "src-1", pubsubToken: "tok-2", contactID: 9))
        await eventually {
            self.socket.sent.contains(CableCodec.unsubscribeFrame(pubsubToken: "tok-1"))
                && self.socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok-2"))
        }
    }

    func testStopNowStopsSocket() async {
        await startRealtime()
        await controller.stopNow()
        XCTAssertEqual(socket.desiredHistory, [true, false])
        XCTAssertFalse(controller.closedByServer.value)
        XCTAssertEqual(controller.typing.value, [:])
    }

    func testMessageCreatedAppliedToDatabase() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        await startRealtime()
        sendEvent(name: "message.created", data: [
            "id": 101, "content": "привет", "message_type": 1, "conversation_id": 7, "inbox_id": 1,
            "sender": ["type": "user"]
        ])
        await eventually { (try? self.database.messages.get(101)) != nil }
        let message = try database.messages.get(101)
        XCTAssertEqual(message?.content, "привет")
        XCTAssertEqual(message?.conversationId, 7)
    }

    func testForeignInboxMessageDropped() async {
        await startRealtime()
        sendEvent(name: "message.created", data: [
            "id": 101, "content": "чужое", "message_type": 1, "conversation_id": 7, "inbox_id": 2,
            "sender": ["type": "user"]
        ])
        await sleepMs(150)
        XCTAssertNil(try? database.messages.get(101))
        XCTAssertEqual(api.conversationsCalls, 0, "чужое событие не должно будить синк")
    }

    func testUnknownConversationTriggersDiscoverSync() async throws {
        api.conversationsStub = .success([
            ConversationDTO(id: 7, uuid: nil, inboxID: 1, status: "open", contactLastSeenAt: 0, agentLastSeenAt: 0, messages: nil, contact: nil)
        ])
        await startRealtime()
        sendEvent(name: "message.created", data: [
            "id": 101, "content": "привет", "message_type": 1, "conversation_id": 7, "inbox_id": 1,
            "sender": ["type": "user"]
        ])
        await eventually { (try? self.database.conversations.get(7)) != nil }
        XCTAssertGreaterThanOrEqual(api.conversationsCalls, 1, "незнакомый разговор нашего инбокса → discover-синк")
    }

    func testStatusChangedUpdatesDatabase() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7, status: "open"))
        await startRealtime()
        sendEvent(name: "conversation.status_changed", data: ["id": 7, "status": "resolved", "inbox_id": 1])
        await eventually { (try? self.database.conversations.get(7))?.status == "resolved" }
    }

    func testTypingOnAndExpiry() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        await startRealtime()
        sendEvent(name: "conversation.typing_on", data: [
            "conversation": ["id": 7, "inbox_id": 1], "is_private": false
        ])
        await eventually { self.controller.typing.value[7] == true }
        await eventually { self.controller.typing.value[7] == false }
    }

    func testTypingForeignInboxDropped() async {
        await startRealtime()
        sendEvent(name: "conversation.typing_on", data: [
            "conversation": ["id": 7, "inbox_id": 2], "is_private": false
        ])
        await sleepMs(150)
        XCTAssertNil(controller.typing.value[7])
    }

    func testStaleEpochEventDropped() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        await startRealtime()
        await sync.invalidate {}
        sendEvent(name: "message.created", data: [
            "id": 101, "content": "протухшее", "message_type": 1, "conversation_id": 7, "inbox_id": 1,
            "sender": ["type": "user"]
        ])
        await sleepMs(150)
        XCTAssertNil(try? database.messages.get(101), "событие протухшего поколения не применяется")
    }

    func testConfirmedSubscriptionTriggersSync() async {
        api.conversationsStub = .success([])
        await startRealtime()
        let confirm = try! JSONSerialization.data(withJSONObject: [
            "type": "confirm_subscription",
            "identifier": CableCodec.identifier(pubsubToken: "tok-1")
        ])
        sendText(String(data: confirm, encoding: .utf8)!)
        await eventually { self.api.conversationsCalls == 1 }
    }
}
