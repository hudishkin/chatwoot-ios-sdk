import Combine
import XCTest
@testable import ChatwootSDK

final class MessageDAOTests: XCTestCase {
    private var database: ChatwootDatabase!
    private var dao: MessageDAO { database.messages }
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        database = try! ChatwootDatabase.inMemory()
        try! database.conversations.upsert(StorageFixtures.conversation(7, inboxId: 1, lastActivityAt: 50))
    }

    func testApplyServerMessageBumpsActivity() throws {
        let message = StorageFixtures.message(101, conversationId: 7, content: "привет", createdAt: 500)
        try dao.applyServerMessage(message, attachments: [StorageFixtures.attachment(1, messageId: 101)], echoId: nil)

        let stored = try dao.get(101)
        XCTAssertEqual(stored?.content, "привет")
        let conversation = try database.conversations.get(7)
        XCTAssertEqual(conversation?.lastActivityAt, 500, "активность разговора сдвинулась на сообщение")
    }

    func testApplyServerMessageWithEchoDeletesPending() throws {
        try database.pending.upsert(StorageFixtures.pending("echo-1", createdAt: 10))
        let message = StorageFixtures.message(102, conversationId: 7, createdAt: 20)
        try dao.applyServerMessage(message, attachments: [], echoId: "echo-1")

        XCTAssertNil(try database.pending.get("echo-1"), "очередь очистилась")
        let echoes = try dao.echoesOf(conversationId: 7)
        XCTAssertEqual(echoes, [StoredEcho(messageId: 102, echoId: "echo-1")])
    }

    func testApplyServerMessageReplacesAttachments() throws {
        let message = StorageFixtures.message(103, conversationId: 7, createdAt: 1)
        try dao.applyServerMessage(message, attachments: [StorageFixtures.attachment(1, messageId: 103)], echoId: nil)
        try dao.applyServerMessage(message, attachments: [StorageFixtures.attachment(2, messageId: 103)], echoId: nil)

        let stored = try dao.messagesOf(conversationId: 7)
        XCTAssertEqual(stored.first?.attachments.map(\.id), [2], "старые вложения заменены, а не продублированы")
    }

    func testReplaceConversationsKeepsNewerContactLastSeen() throws {
        try database.conversations.upsert(StorageFixtures.conversation(8, inboxId: 1, contactLastSeenAt: 900))
        let incoming = StorageFixtures.conversation(8, inboxId: 1, contactLastSeenAt: 100)
        try dao.replaceConversations([incoming], messages: [], attachments: [])

        let stored = try database.conversations.get(8)
        XCTAssertEqual(stored?.contactLastSeenAt, 900, "локальное seen не откатилось старым серверным")
    }

    func testReplaceConversationsAdvancesWatermark() throws {
        let messages = [
            StorageFixtures.message(11, conversationId: 7, createdAt: 100),
            StorageFixtures.message(12, conversationId: 7, createdAt: 200)
        ]
        try dao.replaceConversations([StorageFixtures.conversation(7)], messages: messages, attachments: [])
        XCTAssertEqual(try dao.syncedThroughId(conversationId: 7), 12)
    }

    func testWatermarkMovesOnlyForward() throws {
        let messages = [StorageFixtures.message(15, conversationId: 7, createdAt: 100)]
        try dao.applyMessagesPage(conversationId: 7, messages: messages, attachments: [], syncedThroughId: 15)
        try dao.applyMessagesPage(conversationId: 7, messages: [], attachments: [], syncedThroughId: 10)
        XCTAssertEqual(try dao.syncedThroughId(conversationId: 7), 15, "водяной знак не пошёл назад")
    }

    func testDeleteConversationRemovesEverythingAndDetachesPending() throws {
        try dao.applyServerMessage(StorageFixtures.message(20, conversationId: 7, createdAt: 1),
                                   attachments: [StorageFixtures.attachment(3, messageId: 20)], echoId: "echo-20")
        try database.pending.upsert(StorageFixtures.pending("echo-21", conversationId: 7))

        try dao.deleteConversation(conversationId: 7)

        XCTAssertNil(try dao.get(20))
        XCTAssertNil(try database.conversations.get(7))
        XCTAssertEqual(try dao.echoesOf(conversationId: 7), [])
        let pending = try database.pending.get("echo-21")
        XCTAssertNotNil(pending, "отправка осталась в очереди")
        XCTAssertNil(pending?.conversationId, "и ищет разговор заново")
    }

    func testMessagesOfInboxJoinsConversations() throws {
        try database.conversations.upsert(StorageFixtures.conversation(9, inboxId: 1))
        try database.conversations.upsert(StorageFixtures.conversation(10, inboxId: 2))
        try dao.applyServerMessage(StorageFixtures.message(30, conversationId: 9, createdAt: 2), attachments: [], echoId: nil)
        try dao.applyServerMessage(StorageFixtures.message(31, conversationId: 10, createdAt: 1), attachments: [], echoId: nil)

        let inboxOne = try dao.messagesOfInbox(inboxId: 1)
        XCTAssertEqual(inboxOne.map(\.message.id), [30], "чужой инбокс не попал")
    }

    func testUnreadCount() throws {
        try database.conversations.upsert(StorageFixtures.conversation(11, inboxId: 1, contactLastSeenAt: 100))
        try dao.applyServerMessage(StorageFixtures.message(40, conversationId: 11, type: 1, createdAt: 50), attachments: [], echoId: nil)
        try dao.applyServerMessage(StorageFixtures.message(41, conversationId: 11, type: 1, createdAt: 150), attachments: [], echoId: nil)
        try dao.applyServerMessage(StorageFixtures.message(42, conversationId: 11, type: 0, createdAt: 150), attachments: [], echoId: nil)
        try dao.applyServerMessage(StorageFixtures.message(43, conversationId: 11, type: 1, createdAt: 150, isDeleted: true), attachments: [], echoId: nil)
        try dao.applyServerMessage(StorageFixtures.message(44, conversationId: 11, type: 3, contentType: "input_csat", createdAt: 150), attachments: [], echoId: nil)
        try dao.applyServerMessage(StorageFixtures.message(45, conversationId: 11, type: 3, contentType: "input_csat", createdAt: 150, surveyRating: 5), attachments: [], echoId: nil)

        XCTAssertEqual(try dao.unreadCount(inboxId: 1), 2, "входящее + неотвеченный опрос")
    }

    func testNewestMessageId() throws {
        XCTAssertNil(try dao.newestMessageId(conversationId: 7))
        try dao.applyServerMessage(StorageFixtures.message(50, conversationId: 7, createdAt: 1), attachments: [], echoId: nil)
        try dao.applyServerMessage(StorageFixtures.message(51, conversationId: 7, createdAt: 2), attachments: [], echoId: nil)
        XCTAssertEqual(try dao.newestMessageId(conversationId: 7), 51)
    }

    func testChangesEmittedOnWrite() throws {
        let fired = expectation(description: "changes")
        database.changes.sink { fired.fulfill() }.store(in: &cancellables)
        try dao.applyServerMessage(StorageFixtures.message(60, conversationId: 7, createdAt: 1), attachments: [], echoId: nil)
        wait(for: [fired], timeout: 1)
    }
}
