import Combine
import XCTest
@testable import ChatwootSDK

final class SyncManagerTests: XCTestCase {
    private var api: MockChatwootAPI!
    private var database: ChatwootDatabase!
    private var store: SessionStore!
    private var sessionGuard: SessionGuard!
    private var sync: SyncManager!
    private var clock: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        api = MockChatwootAPI()
        database = try! ChatwootDatabase.inMemory()
        store = SessionStore(directory: Fixtures.makeTempDirectory())
        try! store.write(Fixtures.session)
        sessionGuard = SessionGuard()
        clock = 1_000
        sync = SyncManager(
            api: api,
            inboxIdentifier: "inbox-1",
            inboxId: 1,
            store: store,
            messageDAO: database.messages,
            sessionGuard: sessionGuard,
            now: { [unowned self] in self.clock }
        )
    }

    private func messageDTO(_ id: Int, conversationID: Int = 7, createdAt: Int, type: Int = 1, senderIdentifier: String? = nil) -> MessageDTO {
        MessageDTO(
            id: id, content: "m\(id)", messageType: type, contentType: "text", contentAttributes: nil,
            createdAt: createdAt, conversationID: conversationID, inboxID: 1, echoID: nil, attachments: nil,
            sender: senderIdentifier.map { SenderDTO(id: nil, name: nil, availableName: nil, type: "contact", email: nil, phoneNumber: nil, thumbnail: nil, avatarURL: nil, identifier: $0) }
        )
    }

    private func conversationDTO(_ id: Int, inboxID: Int = 1, messages: [MessageDTO]? = nil, contactIdentifier: String? = nil) -> ConversationDTO {
        ConversationDTO(
            id: id, uuid: nil, inboxID: inboxID, status: "open", contactLastSeenAt: 0, agentLastSeenAt: 0,
            messages: messages,
            contact: contactIdentifier.map { ContactDTO(id: 9, name: nil, email: nil, phoneNumber: nil, identifier: $0, customAttributes: nil) }
        )
    }

    private func assertSuccess(_ result: Result<Void, ChatwootError>, file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let error) = result {
            XCTFail("ожидался успех, получена \(error)", file: file, line: line)
        }
    }

    private func assertFailure(_ result: Result<Void, ChatwootError>, _ expected: ChatwootError, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else {
            return XCTFail("ожидалась ошибка \(expected)", file: file, line: line)
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    func testFirstSyncIsFullAndFiltersInbox() async {
        api.conversationsStub = .success([
            conversationDTO(7, inboxID: 1, messages: [messageDTO(11, createdAt: 100), messageDTO(12, createdAt: 200)]),
            conversationDTO(8, inboxID: 2, messages: [messageDTO(13, conversationID: 8, createdAt: 50)])
        ])
        let result = await sync.sync(.subscribed)
        assertSuccess(result)
        XCTAssertEqual(try database.messages.messagesOf(conversationId: 7).map(\.message.id), [11, 12])
        XCTAssertNil(try database.conversations.get(8), "чужой инбокс не сохранён")
        XCTAssertEqual(try database.messages.syncedThroughId(conversationId: 7), 12, "полный снапшот — беспробельный водяной знак")
        XCTAssertEqual(sync.lastSuccessAt.value, clock)
    }

    func testConversationsIdentityMismatch() async {
        var reasons: [String] = []
        sessionGuard.reidentifyRequests.sink { reasons.append($0) }.store(in: &cancellables)
        api.conversationsStub = .success([conversationDTO(7, contactIdentifier: "кто-то-другой")])
        let result = await sync.sync(.subscribed)
        assertFailure(result, .identityMismatch)
        XCTAssertEqual(reasons, ["contact_identifier_mismatch"])
    }

    func testNetworkFailure() async {
        api.conversationsStub = .failure(ChatwootError.network)
        let result = await sync.sync(.subscribed)
        assertFailure(result, .network)
    }

    private func makeFullSnapshot() async {
        api.conversationsStub = .success([
            conversationDTO(7, messages: [messageDTO(11, createdAt: 100)])
        ])
        assertSuccess(await sync.sync(.identify))
        clock += 1_000
    }

    func testSecondSyncIsIncremental() async {
        await makeFullSnapshot()
        api.messagesStub = .success([messageDTO(12, createdAt: 200)])
        let result = await sync.sync(.subscribed)
        assertSuccess(result)
        XCTAssertEqual(api.conversationsCalls, 1, "полный GET не повторялся")
        XCTAssertEqual(api.messagesCalls.count, 1)
        XCTAssertEqual(try database.messages.messagesOf(conversationId: 7).map(\.message.id), [11, 12])
        XCTAssertEqual(try database.messages.syncedThroughId(conversationId: 7), 12)
    }

    func testIncrementalPaginatesUntilWatermark() async {
        await makeFullSnapshot() // watermark = 11
        let fullPage = (12...31).map { messageDTO($0, createdAt: $0) }
        api.messagesHandler = { _, before in
            if before == nil { return .success(fullPage) }
            return .success([self.messageDTO(10, createdAt: 90), self.messageDTO(11, createdAt: 100)])
        }
        let result = await sync.sync(.refresh)
        assertSuccess(result)
        XCTAssertEqual(api.messagesCalls.count, 2, "полная страница без водяного знака → ещё страница")
        XCTAssertEqual(api.messagesCalls[1].before, 12)
        XCTAssertEqual(try database.messages.syncedThroughId(conversationId: 7), 31)
    }

    func testIncrementalFallsBackToFullOnHttp() async {
        await makeFullSnapshot()
        api.messagesStub = .failure(ChatwootError.http(code: 500))
        api.conversationsStub = .success([conversationDTO(7, messages: [messageDTO(12, createdAt: 200)])])
        let result = await sync.sync(.refresh)
        assertSuccess(result)
        XCTAssertEqual(api.conversationsCalls, 2, "HTTP на странице → полный проход")
        XCTAssertEqual(try database.messages.newestMessageId(conversationId: 7), 12)
    }

    func testMessagesIdentityMismatch() async {
        await makeFullSnapshot()
        api.messagesStub = .success([messageDTO(12, createdAt: 200, senderIdentifier: "чужой")])
        let result = await sync.sync(.refresh)
        assertFailure(result, .identityMismatch)
    }

    func testFullAfterFullInterval() async {
        await makeFullSnapshot()
        clock += SyncManager.fullIntervalMs
        let result = await sync.sync(.refresh)
        assertSuccess(result)
        XCTAssertEqual(api.conversationsCalls, 2, "окно вышло — снова полный проход")
    }

    func testConcurrentCallsCollapse() async {
        api.conversationsStub = .success([conversationDTO(7, messages: [messageDTO(11, createdAt: 100)])])
        api.messagesStub = .success([])
        api.conversationsHandler = { [api] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return api!.conversationsStub
        }
        async let first = sync.sync(.identify)
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let second = sync.sync(.refresh)
        let (firstResult, secondResult) = await (first, second)
        assertSuccess(firstResult)
        assertSuccess(secondResult)
        XCTAssertEqual(api.conversationsCalls, 1, "GET лидера ушёл до присоединения: joiner получил rerun-инкрементал")
        XCTAssertGreaterThanOrEqual(api.messagesCalls.count, 1, "второй проход — инкрементальный")
    }

    func testApplyRealtimeDropsStaleEpoch() async throws {
        let epoch = sync.currentEpoch
        await sync.invalidate {}
        let applied = try await sync.applyRealtime(epoch: epoch) {
            XCTFail("запись устаревшего поколения не должна выполняться")
        }
        XCTAssertFalse(applied)
    }

    func testRealtimeWriteDuringGetRefetches() async {
        var wrote = false
        api.conversationsHandler = { [api, database, sync] in
            if !wrote {
                wrote = true
                try? await sync?.applyRealtime {
                    try database?.conversations.upsert(StorageFixtures.conversation(7))
                }
            }
            return api!.conversationsStub
        }
        api.conversationsStub = .success([conversationDTO(7, messages: [messageDTO(11, createdAt: 100)])])
        let result = await sync.sync(.identify)
        assertSuccess(result)
        XCTAssertEqual(api.conversationsCalls, 2, "первая попытка выброшена, снапшот запрошен заново")
    }

    func testInvalidateMovesEpoch() async {
        let before = sync.currentEpoch
        await sync.invalidate {}
        XCTAssertEqual(sync.currentEpoch, before + 1)
    }
}
