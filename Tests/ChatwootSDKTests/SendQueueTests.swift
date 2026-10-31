import XCTest
@testable import ChatwootSDK

final class SendQueueTests: XCTestCase {
    private var api: MockChatwootAPI!
    private var database: ChatwootDatabase!
    private var store: SessionStore!
    private var sync: SyncManager!
    private var queue: SendQueue!
    private var attachmentsDir: URL!
    private var clock: UInt64 = 0
    private var echoCounter = 0

    override func setUp() {
        super.setUp()
        api = MockChatwootAPI()
        database = try! ChatwootDatabase.inMemory()
        store = SessionStore(directory: Fixtures.makeTempDirectory())
        try! store.write(Fixtures.session)
        let sessionGuard = SessionGuard()
        clock = 1_000_000
        sync = SyncManager(
            api: api, inboxIdentifier: "inbox-1", inboxId: 1, store: store,
            messageDAO: database.messages, sessionGuard: sessionGuard,
            now: { [unowned self] in self.clock }
        )
        attachmentsDir = Fixtures.makeTempDirectory().appendingPathComponent("attachments", isDirectory: true)
        echoCounter = 0
        queue = SendQueue(
            api: api, inboxIdentifier: "inbox-1", inboxId: 1, store: store,
            pendingDAO: database.pending, messageDAO: database.messages, conversationDAO: database.conversations,
            sync: sync, sessionGuard: sessionGuard, attachmentsDir: attachmentsDir,
            now: { [unowned self] in self.clock },
            newEchoId: { [unowned self] in self.echoCounter += 1; return "echo-\(self.echoCounter)" }
        )
    }

    override func tearDown() {
        queue = nil
        super.tearDown()
    }

    private func start() async {
        await queue.start()
    }

    private func waitFor(_ condition: @escaping () throws -> Bool) async -> Bool {
        for _ in 0..<100 {
            if (try? condition()) == true { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func messageDTO(_ id: Int, conversationID: Int = 7, echoID: String? = nil) -> MessageDTO {
        MessageDTO(
            id: id, content: "ответ", messageType: 0, contentType: "text", contentAttributes: nil,
            createdAt: Int(clock / 1000), conversationID: conversationID, inboxID: 1, echoID: echoID, attachments: nil,
            sender: SenderDTO(id: nil, name: nil, availableName: nil, type: "contact", email: nil, phoneNumber: nil, thumbnail: nil, avatarURL: nil, identifier: nil)
        )
    }

    private func conversationDTO(_ id: Int) -> ConversationDTO {
        ConversationDTO(
            id: id, uuid: nil, inboxID: 1, status: "open", contactLastSeenAt: 0, agentLastSeenAt: 0,
            messages: nil, contact: nil
        )
    }

    func testEnqueueTextDelivers() async {
        await start()
        api.conversationsStub = .success([])
        api.createConversationStub = .success(conversationDTO(7))
        api.createMessageStub = .success(messageDTO(101, echoID: "echo-1"))

        await queue.enqueueText("привет")
        let delivered = await waitFor { try self.database.messages.get(101) != nil }

        XCTAssertTrue(delivered, "сообщение сохранено после ack")
        XCTAssertEqual(api.createConversationCalls, 1, "разговоров не было — создан")
        XCTAssertEqual(api.createMessageCalls.count, 1)
        XCTAssertEqual(api.createMessageCalls[0].echoID, "echo-1")
        XCTAssertEqual(try database.pending.getAll(), [], "очередь очищена")
        XCTAssertEqual(try database.messages.echoesOf(conversationId: 7), [StoredEcho(messageId: 101, echoId: "echo-1")])
        XCTAssertEqual(queue.inFlight.value, [])
    }

    func testNetworkFailureMarksFailed() async {
        await start()
        api.conversationsStub = .success([conversationDTO(7)])
        api.createMessageStub = .failure(ChatwootError.network)

        await queue.enqueueText("привет")
        let failed = await waitFor { try self.database.pending.get("echo-1")?.state == .failed }

        XCTAssertTrue(failed, "сетевая неудача — отправка сбойная")
        XCTAssertEqual(queue.inFlight.value, [])
    }

    func testRetryReposts() async {
        await start()
        api.conversationsStub = .success([conversationDTO(7)])
        api.createMessageStub = .failure(ChatwootError.network)
        await queue.enqueueText("привет")
        _ = await waitFor { try self.database.pending.get("echo-1")?.state == .failed }

        api.createMessageStub = .success(messageDTO(102, echoID: "echo-1"))
        await queue.retry("echo-1")
        let delivered = await waitFor { try self.database.messages.get(102) != nil }

        XCTAssertTrue(delivered)
        XCTAssertEqual(api.createMessageCalls.count, 2, "POST повторён")
        XCTAssertEqual(try database.pending.getAll(), [])
    }

    func testRetryFindsLostAckDuplicate() async {
        await start()
        api.conversationsStub = .success([conversationDTO(7)])
        api.createMessageStub = .failure(ChatwootError.network)
        await queue.enqueueText("привет")
        _ = await waitFor { try self.database.pending.get("echo-1")?.state == .failed }
        XCTAssertEqual(api.createMessageCalls.count, 1)

        let serverCopy = MessageDTO(
            id: 150, content: "привет", messageType: 0, contentType: "text", contentAttributes: nil,
            createdAt: Int(clock / 1000) + 1, conversationID: 7, inboxID: 1, echoID: nil, attachments: nil,
            sender: SenderDTO(id: nil, name: nil, availableName: nil, type: "contact", email: nil, phoneNumber: nil, thumbnail: nil, avatarURL: nil, identifier: nil)
        )
        api.messagesStub = .success([serverCopy])
        await queue.retry("echo-1")
        let cleared = await waitFor { try self.database.pending.get("echo-1") == nil }

        XCTAssertTrue(cleared, "дубликат найден, отправка снята с очереди")
        XCTAssertEqual(api.createMessageCalls.count, 1, "повторный POST не уходил")
        XCTAssertEqual(try database.messages.echoesOf(conversationId: 7), [StoredEcho(messageId: 150, echoId: "echo-1")])
    }

    // MARK: - Recovery

    func testRestartMarksQueuedAsFailed() async throws {
        try database.pending.upsert(StorageFixtures.pending("echo-old", state: .queued, createdAt: 1))
        await start()
        let failed = await waitFor { try self.database.pending.get("echo-old")?.state == .failed }
        XCTAssertTrue(failed, "после рестарта QUEUED стал FAILED")
    }

    func testEnqueueFileDeliversAndCleansUp() async throws {
        await start()
        api.conversationsStub = .success([conversationDTO(7)])
        api.createMessageStub = .success(messageDTO(103, echoID: "echo-1"))
        let source = Fixtures.makeTempDirectory().appendingPathComponent("note.txt")
        try "содержимое файла".write(to: source, atomically: true, encoding: .utf8)

        let result = await queue.enqueueFile(url: source, mime: "text/plain", caption: "смотри")
        guard case .success = result else {
            return XCTFail("ожидался успех постановки")
        }
        let delivered = await waitFor { try self.database.messages.get(103) != nil }

        XCTAssertTrue(delivered)
        XCTAssertEqual(api.createMessageCalls.count, 1)
        XCTAssertEqual(api.createMessageCalls[0].content, "смотри")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDir.path)) ?? []
        XCTAssertEqual(leftovers, [], "скопированный файл удалён после ack")
    }

    func testTooLargeFileRejected() async throws {
        await start()
        let source = Fixtures.makeTempDirectory().appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(AttachmentLimits.maxFileBytes + 1))
        try handle.close()

        let result = await queue.enqueueFile(url: source, mime: "application/octet-stream")
        guard case .failure(let error) = result else {
            return XCTFail("ожидалась ошибка")
        }
        XCTAssertEqual(error, .tooLarge)
        XCTAssertEqual(try database.pending.getAll(), [], "в очередь не ставилось")
    }

    // MARK: - 404

    func testConversationGoneWithUnknownContactFails() async {
        await start()
        api.conversationsStub = .success([conversationDTO(7)])
        api.createMessageStub = .failure(ChatwootError.http(code: 404))

        await queue.enqueueText("привет")
        let failed = await waitFor { try self.database.pending.get("echo-1")?.state == .failed }

        XCTAssertTrue(failed, "контакт не подтверждён (по умолчанию unknown) — отправка сбойная, история хранится")
        XCTAssertNotNil(try database.conversations.get(7), "разговор не удалён без подтверждения контакта")
    }
}

final class DuplicateMatcherTests: XCTestCase {
    private func pending(
        content: String? = "текст",
        attachmentPath: String? = nil,
        mime: String? = nil,
        createdAt: Int = 1_000
    ) -> StoredPendingMessage {
        StoredPendingMessage(
            echoId: "e", conversationId: 7, content: content, attachmentPath: attachmentPath,
            attachmentMime: mime, kind: .text, state: .failed, createdAt: createdAt,
            conversationAttributes: nil, posted: true
        )
    }

    private func serverMessage(_ id: Int, content: String? = "текст", createdAt: Int, isMine: Bool = true) -> StoredMessage {
        StorageFixtures.message(id, conversationId: 7, content: content, createdAt: createdAt, isMine: isMine)
    }

    func testTextMatchInWindow() {
        let match = DuplicateMatcher.find(
            pending: pending(),
            messages: [serverMessage(1, createdAt: 1_000 + DuplicateMatcher.afterSeconds)]
        )
        XCTAssertEqual(match?.id, 1)
    }

    func testTextMatchBeforeWindowEdge() {
        let match = DuplicateMatcher.find(
            pending: pending(),
            messages: [serverMessage(1, createdAt: 1_000 - DuplicateMatcher.beforeSeconds)]
        )
        XCTAssertNotNil(match, "сдвиг часов в пределах окна — совпадение")
    }

    func testTooEarlyMessageIsNotMatch() {
        let match = DuplicateMatcher.find(
            pending: pending(),
            messages: [serverMessage(1, createdAt: 1_000 - DuplicateMatcher.beforeSeconds - 1)]
        )
        XCTAssertNil(match, "давнее сообщение с тем же текстом — отдельная отправка")
    }

    func testForeignMessageIsNotMatch() {
        let match = DuplicateMatcher.find(
            pending: pending(),
            messages: [serverMessage(1, createdAt: 1_000, isMine: false)]
        )
        XCTAssertNil(match)
    }

    func testAttachmentMatchRequiresSingleSameTypeAndSize() {
        let withAttachments = MessageWithAttachments(
            message: serverMessage(1, content: nil, createdAt: 1_000),
            attachments: [StorageFixtures.attachment(9, messageId: 1, fileType: "image", fileSize: 500)]
        )
        let match = DuplicateMatcher.findWithAttachments(
            pending: pending(content: nil, attachmentPath: "/tmp/x", mime: "image/jpeg"),
            messages: [withAttachments],
            fileSize: 500
        )
        XCTAssertEqual(match?.id, 1)
    }

    func testTwoCandidatesAreNoMatch() {
        let one = MessageWithAttachments(
            message: serverMessage(1, content: nil, createdAt: 1_000),
            attachments: [StorageFixtures.attachment(9, messageId: 1, fileSize: 500)]
        )
        let two = MessageWithAttachments(
            message: serverMessage(2, content: nil, createdAt: 1_001),
            attachments: [StorageFixtures.attachment(10, messageId: 2, fileSize: 500)]
        )
        let match = DuplicateMatcher.findWithAttachments(
            pending: pending(content: nil, attachmentPath: "/tmp/x", mime: "image/png"),
            messages: [one, two],
            fileSize: 500
        )
        XCTAssertNil(match, "два кандидата — неопределённость, а не совпадение")
    }

    func testUnknownSizeIsNoMatch() {
        let match = DuplicateMatcher.findWithAttachments(
            pending: pending(content: nil, attachmentPath: "/tmp/x", mime: "image/png"),
            messages: [],
            fileSize: nil
        )
        XCTAssertNil(match)
    }
}
