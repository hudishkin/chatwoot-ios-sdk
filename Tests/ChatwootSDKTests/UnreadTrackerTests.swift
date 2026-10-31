import Combine
import XCTest
@testable import ChatwootSDK

final class UnreadTrackerTests: XCTestCase {
    private var api: MockChatwootAPI!
    private var database: ChatwootDatabase!
    private var store: SessionStore!
    private var sessionGuard: SessionGuard!
    private var generation: SessionGeneration!
    private var retryTriggers: PassthroughSubject<Void, Never>!
    private var tracker: UnreadTracker!
    private var contactVerdict: StaleSessionVerifier.Verdict = .unknown

    override func setUp() {
        super.setUp()
        api = MockChatwootAPI()
        database = try! ChatwootDatabase.inMemory()
        store = SessionStore(directory: Fixtures.makeTempDirectory())
        try! store.write(Fixtures.session)
        sessionGuard = SessionGuard()
        generation = SessionGeneration()
        retryTriggers = PassthroughSubject()
        contactVerdict = .unknown
        tracker = UnreadTracker(
            api: api,
            inboxIdentifier: "inbox-1",
            inboxId: 1,
            store: store,
            conversationDAO: database.conversations,
            messageDAO: database.messages,
            sessionGuard: sessionGuard,
            changes: database.changes,
            debounceMs: 30,
            generation: generation,
            retryTriggers: retryTriggers.eraseToAnyPublisher(),
            backoff: SocketBackoffStrategy(random: { 1.0 }),
            contactCheck: { [unowned self] _ in self.contactVerdict }
        )
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

    func testShownMarksLocallyAndSendsAfterDebounce() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7, contactLastSeenAt: 100))
        await tracker.onMessagesShown(conversationId: 7, lastCreatedAt: 500)
        await eventually { (try? self.database.conversations.get(7))??.contactLastSeenAt == 500 }
        XCTAssertEqual(api.updateLastSeenCalls.count, 0, "до дебаунса запроса нет")
        await eventually { self.api.updateLastSeenCalls.count == 1 }
        XCTAssertEqual(api.updateLastSeenCalls[0].conversationID, 7)
    }

    func testDebounceCollapsesPerConversation() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        await tracker.onMessagesShown(conversationId: 7, lastCreatedAt: 500)
        await tracker.onMessagesShown(conversationId: 7, lastCreatedAt: 600)
        await eventually { self.api.updateLastSeenCalls.count == 1 }
        await sleepMs(80)
        XCTAssertEqual(api.updateLastSeenCalls.count, 1, "вторая отметка отменила первую")
    }

    func testUnreadRefreshesOnDatabaseChanges() async throws {
        await tracker.start()
        XCTAssertEqual(tracker.unread.value, 0)
        try database.conversations.upsert(StorageFixtures.conversation(7, contactLastSeenAt: 100))
        try database.messages.applyServerMessage(
            StorageFixtures.message(11, conversationId: 7, content: "ответ", type: 1, createdAt: 200),
            attachments: [], echoId: nil
        )
        await eventually { self.tracker.unread.value == 1 }
    }

    func testNetworkFailureRetriedOnTrigger() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        api.updateLastSeenStub = .failure(ChatwootError.network)
        await tracker.start()
        await tracker.onMessagesShown(conversationId: 7, lastCreatedAt: 500)
        await eventually { self.api.updateLastSeenCalls.count == 1 }
        api.updateLastSeenStub = .success(())
        retryTriggers.send()
        await eventually { self.api.updateLastSeenCalls.count == 2 }
    }

    func testBackoffRetriesUnacknowledged() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        api.updateLastSeenStub = .failure(ChatwootError.network)
        await tracker.onMessagesShown(conversationId: 7, lastCreatedAt: 500)
        await eventually { self.api.updateLastSeenCalls.count >= 2 }
    }

    func test404HealthyContactDropsConversation() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        api.updateLastSeenStub = .failure(ChatwootError.http(code: 404))
        contactVerdict = .healthy
        await tracker.onMessagesShown(conversationId: 7, lastCreatedAt: 500)
        await eventually { (try? self.database.conversations.get(7)) ?? nil == nil }
    }

    func test404StaleContactReportsAndKeepsHistory() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        api.updateLastSeenStub = .failure(ChatwootError.http(code: 404))
        contactVerdict = .stale
        var cancellable: AnyCancellable?
        var reasons: [String] = []
        cancellable = sessionGuard.reidentifyRequests.sink { reasons.append($0) }
        defer { cancellable?.cancel() }
        await tracker.onMessagesShown(conversationId: 7, lastCreatedAt: 500)
        await eventually { reasons == ["http_404"] }
        XCTAssertNotNil(try database.conversations.get(7), "история сохранена: протухшая сессия, а не удалённый разговор")
    }

    func testCancelAllDropsPending() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        await tracker.onMessagesShown(conversationId: 7, lastCreatedAt: 500)
        await tracker.cancelAll()
        await sleepMs(100)
        XCTAssertEqual(api.updateLastSeenCalls.count, 0, "отменённая квитанция не уходит")
    }

    func testInvalidatedGenerationSkipsSend() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        await tracker.onMessagesShown(conversationId: 7, lastCreatedAt: 500)
        generation.invalidate {}
        await sleepMs(100)
        XCTAssertEqual(api.updateLastSeenCalls.count, 0, "квитанция прежнего поколения не отправляется")
    }
}
