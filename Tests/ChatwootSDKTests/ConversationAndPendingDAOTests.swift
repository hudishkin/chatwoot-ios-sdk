import XCTest
@testable import ChatwootSDK

final class ConversationDAOTests: XCTestCase {
    private var database: ChatwootDatabase!
    private var dao: ConversationDAO { database.conversations }

    override func setUp() {
        super.setUp()
        database = try! ChatwootDatabase.inMemory()
    }

    func testUpsertAndGet() throws {
        try dao.upsert(StorageFixtures.conversation(7, inboxId: 1, status: "open"))
        try dao.upsert(StorageFixtures.conversation(7, inboxId: 1, status: "resolved"))
        XCTAssertEqual(try dao.get(7)?.status, "resolved", "upsert обновил строку")
    }

    func testAllOrderedByActivity() throws {
        try dao.upsert(StorageFixtures.conversation(1, lastActivityAt: 100))
        try dao.upsert(StorageFixtures.conversation(2, lastActivityAt: 300))
        try dao.upsert(StorageFixtures.conversation(3, lastActivityAt: 200))
        XCTAssertEqual(try dao.allOrderedByActivity().map(\.id), [2, 3, 1])
    }

    func testSummaries() throws {
        try dao.upsert(StorageFixtures.conversation(7, inboxId: 1, contactLastSeenAt: 50, lastActivityAt: 500))
        let messages = database.messages
        try messages.applyServerMessage(StorageFixtures.message(1, conversationId: 7, content: "последнее", type: 1, createdAt: 400), attachments: [], echoId: nil)
        try messages.applyServerMessage(StorageFixtures.message(2, conversationId: 7, content: "активность", type: 2, createdAt: 500), attachments: [], echoId: nil)

        let summaries = try dao.summaries(inboxId: 1)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].lastMessagePreview, "последнее")
        XCTAssertEqual(summaries[0].unread, 1, "входящее новее seen непрочитано; activity не считается")
    }

    func testInsertIfAbsent() throws {
        let first = try dao.insertIfAbsent(StorageFixtures.conversation(7))
        let second = try dao.insertIfAbsent(StorageFixtures.conversation(7, status: "resolved"))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(try dao.get(7)?.status, "open", "существующая строка не тронута")
    }

    func testMergeFromServerMovesMarkersOnlyForward() throws {
        try dao.upsert(StorageFixtures.conversation(7, contactLastSeenAt: 900, agentLastSeenAt: 800, lastActivityAt: 700))
        try dao.mergeFromServer(id: 7, inboxId: 1, status: "resolved", contactLastSeenAt: 100, agentLastSeenAt: 100, lastActivityAt: 1000)
        let stored = try dao.get(7)
        XCTAssertEqual(stored?.status, "resolved", "статус — серверный")
        XCTAssertEqual(stored?.contactLastSeenAt, 900, "seen не откатился")
        XCTAssertEqual(stored?.lastActivityAt, 1000, "активность пошла вперёд")
    }

    func testUpdateStatusKeepsSeenMarkers() throws {
        try dao.upsert(StorageFixtures.conversation(7, contactLastSeenAt: 900))
        try dao.updateStatus(7, status: "resolved")
        XCTAssertEqual(try dao.get(7)?.contactLastSeenAt, 900)
    }

    func testMarkInboxSeenMovesAll() throws {
        try dao.upsert(StorageFixtures.conversation(7, inboxId: 1, contactLastSeenAt: 50))
        try dao.upsert(StorageFixtures.conversation(8, inboxId: 1, contactLastSeenAt: 150))
        try dao.upsert(StorageFixtures.conversation(9, inboxId: 2, contactLastSeenAt: 50))
        try dao.markInboxSeen(1, at: 100)
        XCTAssertEqual(try dao.get(7)?.contactLastSeenAt, 100)
        XCTAssertEqual(try dao.get(8)?.contactLastSeenAt, 150, "более свежее seen не тронуто")
        XCTAssertEqual(try dao.get(9)?.contactLastSeenAt, 50, "чужой инбокс не тронут")
    }
}

final class PendingDAOTests: XCTestCase {
    private var database: ChatwootDatabase!
    private var dao: PendingDAO { database.pending }

    override func setUp() {
        super.setUp()
        database = try! ChatwootDatabase.inMemory()
    }

    func testUpsertGetGetAllOrdered() throws {
        try dao.upsert(StorageFixtures.pending("b", createdAt: 200))
        try dao.upsert(StorageFixtures.pending("a", createdAt: 100))
        XCTAssertEqual(try dao.getAll().map(\.echoId), ["a", "b"], "по времени создания")
        try dao.upsert(StorageFixtures.pending("a", state: .failed))
        XCTAssertEqual(try dao.get("a")?.state, .failed, "upsert обновил")
    }

    func testMarkQueuedAsFailed() throws {
        try dao.upsert(StorageFixtures.pending("a", state: .queued))
        try dao.upsert(StorageFixtures.pending("b", state: .failed))
        let count = try dao.markQueuedAsFailed()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try dao.get("a")?.state, .failed)
    }

    func testAssignConversationOnlyWhenUnbound() throws {
        try dao.upsert(StorageFixtures.pending("a", conversationId: nil))
        try dao.upsert(StorageFixtures.pending("b", conversationId: 5))
        try dao.assignConversation("a", conversationId: 7)
        try dao.assignConversation("b", conversationId: 9)
        XCTAssertEqual(try dao.get("a")?.conversationId, 7)
        XCTAssertEqual(try dao.get("b")?.conversationId, 5, "привязанная строка не перепривязана")
    }

    func testPostedFlag() throws {
        try dao.upsert(StorageFixtures.pending("a"))
        XCTAssertEqual(try dao.get("a")?.posted, false)
        try dao.markPosted("a")
        XCTAssertEqual(try dao.get("a")?.posted, true)
        try dao.clearPosted("a")
        XCTAssertEqual(try dao.get("a")?.posted, false)
    }

    func testPendingOfConversationIncludesUnbound() throws {
        try dao.upsert(StorageFixtures.pending("a", conversationId: 7))
        try dao.upsert(StorageFixtures.pending("b", conversationId: nil))
        try dao.upsert(StorageFixtures.pending("c", conversationId: 8))
        XCTAssertEqual(try dao.pendingOf(conversationId: 7).map(\.echoId), ["a", "b"])
    }

    func testPendingOfInbox() throws {
        try database.conversations.upsert(StorageFixtures.conversation(7, inboxId: 1))
        try database.conversations.upsert(StorageFixtures.conversation(8, inboxId: 2))
        try dao.upsert(StorageFixtures.pending("a", conversationId: 7))
        try dao.upsert(StorageFixtures.pending("b", conversationId: 8))
        try dao.upsert(StorageFixtures.pending("c", conversationId: nil))
        XCTAssertEqual(try dao.pendingOfInbox(inboxId: 1).map(\.echoId), ["a", "c"])
    }

    func testDelete() throws {
        try dao.upsert(StorageFixtures.pending("a"))
        try dao.delete("a")
        XCTAssertNil(try dao.get("a"))
    }
}

final class ChatwootDatabaseTests: XCTestCase {
    func testWipeClearsAllTables() throws {
        let database = try ChatwootDatabase.inMemory()
        try database.conversations.upsert(StorageFixtures.conversation(7, inboxId: 1))
        try database.messages.applyServerMessage(StorageFixtures.message(1, conversationId: 7, createdAt: 1), attachments: [], echoId: nil)
        try database.pending.upsert(StorageFixtures.pending("a"))

        try database.wipe()

        XCTAssertEqual(try database.conversations.allOrderedByActivity(), [])
        XCTAssertEqual(try database.messages.messagesOfInbox(inboxId: 1), [])
        XCTAssertEqual(try database.pending.getAll(), [])
    }
}
