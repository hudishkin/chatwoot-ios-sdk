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
        CWLog.install(sink: nil, console: false)
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

        XCTAssertTrue(delivered)
        XCTAssertEqual(api.createConversationCalls, 1)
        XCTAssertEqual(api.createMessageCalls.count, 1)
        XCTAssertEqual(api.createMessageCalls[0].echoID, "echo-1")
        XCTAssertEqual(try database.pending.getAll(), [])
        XCTAssertEqual(try database.messages.echoesOf(conversationId: 7), [StoredEcho(messageId: 101, echoId: "echo-1")])
        XCTAssertEqual(queue.inFlight.value, [])
    }

    func testNetworkFailureMarksFailed() async {
        await start()
        api.conversationsStub = .success([conversationDTO(7)])
        api.createMessageStub = .failure(ChatwootError.network)

        await queue.enqueueText("привет")
        let failed = await waitFor { try self.database.pending.get("echo-1")?.state == .failed }

        XCTAssertTrue(failed)
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
        XCTAssertEqual(api.createMessageCalls.count, 2)
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

        XCTAssertTrue(cleared)
        XCTAssertEqual(api.createMessageCalls.count, 1)
        XCTAssertEqual(try database.messages.echoesOf(conversationId: 7), [StoredEcho(messageId: 150, echoId: "echo-1")])
    }

    // MARK: - Recovery

    func testRestartMarksQueuedAsFailed() async throws {
        try database.pending.upsert(StorageFixtures.pending("echo-old", state: .queued, createdAt: 1))
        await start()
        let failed = await waitFor { try self.database.pending.get("echo-old")?.state == .failed }
        XCTAssertTrue(failed)
    }

    func testEnqueueFileDeliversAndCleansUp() async throws {
        await start()
        api.conversationsStub = .success([conversationDTO(7)])
        api.createMessageStub = .success(messageDTO(103, echoID: "echo-1"))
        let source = Fixtures.makeTempDirectory().appendingPathComponent("note.txt")
        try "содержимое файла".write(to: source, atomically: true, encoding: .utf8)

        let result = await queue.enqueueFile(url: source, mime: "text/plain", caption: "смотри")
        guard case .success = result else {
            return XCTFail()
        }
        let delivered = await waitFor { try self.database.messages.get(103) != nil }

        XCTAssertTrue(delivered)
        XCTAssertEqual(api.createMessageCalls.count, 1)
        XCTAssertEqual(api.createMessageCalls[0].content, "смотри")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDir.path)) ?? []
        XCTAssertEqual(leftovers, [])
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
            return XCTFail()
        }
        XCTAssertEqual(error, .tooLarge)
        XCTAssertEqual(try database.pending.getAll(), [])
    }

    // MARK: - 404

    func testConversationGoneWithUnknownContactFails() async {
        await start()
        api.conversationsStub = .success([conversationDTO(7)])
        api.createMessageStub = .failure(ChatwootError.http(code: 404))

        await queue.enqueueText("привет")
        let failed = await waitFor { try self.database.pending.get("echo-1")?.state == .failed }

        XCTAssertTrue(failed)
        XCTAssertNotNil(try database.conversations.get(7))
    }

    func testSendWithoutSessionFailsWhenNobodyWasIdentified() async {
        store.clear()
        await start()

        await queue.enqueueText("привет")
        let failed = await waitFor { try self.database.pending.get("echo-1")?.state == .failed }

        XCTAssertTrue(failed)
        XCTAssertEqual(queue.failures.value["echo-1"], .session)
        XCTAssertEqual(api.createMessageCalls.count, 0)
    }

    func testReopenResolvedPostsIntoResolvedConversation() async {
        try? database.conversations.upsert(StorageFixtures.conversation(7, status: "resolved", lastActivityAt: 10))
        let reopen = SendQueue(
            api: api, inboxIdentifier: "inbox-1", inboxId: 1, store: store,
            pendingDAO: database.pending, messageDAO: database.messages, conversationDAO: database.conversations,
            sync: sync, sessionGuard: SessionGuard(), attachmentsDir: attachmentsDir,
            now: { [unowned self] in self.clock },
            newEchoId: { [unowned self] in self.echoCounter += 1; return "echo-\(self.echoCounter)" },
            realtimeLive: { true },
            reopenResolved: true
        )
        await reopen.start()
        api.createMessageStub = .success(messageDTO(201, echoID: "echo-1"))

        await reopen.enqueueText("ещё")
        let delivered = await waitFor { try self.database.messages.get(201) != nil }

        XCTAssertTrue(delivered)
        XCTAssertEqual(api.createConversationCalls, 0)
        XCTAssertEqual(api.createMessageCalls.first?.conversationID, 7)
    }
    func testNoSessionIdentifiesThenPosts() async throws {
        store.clear()
        try database.conversations.upsert(StorageFixtures.conversation(7))
        let identifies = Counter()
        let sink = LineSink()
        CWLog.install(sink: sink, console: false)
        let recovering = makeQueue(recoverer: SessionRecoverer(
            identifyOnce: { [store] in
                identifies.value += 1
                try? store?.write(Fixtures.session)
                return .done
            },
            retryDelaysMs: [],
            now: { [unowned self] in self.clock }
        ))
        api.createMessageStub = .success(messageDTO(101, echoID: "echo-1"))
        await recovering.start()
        await recovering.enqueueText("привет")
        let delivered = await waitFor { try self.database.messages.get(101) != nil }
        XCTAssertTrue(delivered)
        XCTAssertEqual(identifies.value, 1)
        XCTAssertEqual(api.createMessageCalls.count, 1)
        XCTAssertTrue(sink.lines.contains { $0.contains("no session echo=echo-1, identifying") })
    }

    func testIdentifyFailureFailsTheSendWithoutPosting() async throws {
        store.clear()
        try database.conversations.upsert(StorageFixtures.conversation(7))
        let recovering = makeQueue(recoverer: SessionRecoverer(
            identifyOnce: { .failed(.network) },
            retryDelaysMs: [],
            now: { [unowned self] in self.clock }
        ))
        await recovering.start()
        await recovering.enqueueText("привет")
        let failed = await waitFor { (try? self.database.pending.get("echo-1"))?.state == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(api.createMessageCalls.count, 0)
        XCTAssertEqual(recovering.failures.value["echo-1"], .session)
    }

    func testTwoSendsWithoutASessionShareOneIdentify() async throws {
        store.clear()
        try database.conversations.upsert(StorageFixtures.conversation(7))
        let identifies = Counter()
        let gate = ResumeGate()
        let recovering = makeQueue(recoverer: SessionRecoverer(
            identifyOnce: { [store] in
                identifies.value += 1
                await gate.wait()
                try? store?.write(Fixtures.session)
                return .done
            },
            retryDelaysMs: [],
            now: { [unowned self] in self.clock }
        ))
        api.createMessageStub = .success(messageDTO(101))
        await recovering.start()
        await recovering.enqueueText("один")
        await recovering.enqueueText("два")
        let started = await waitFor { identifies.value == 1 }
        XCTAssertTrue(started)
        gate.resume()
        let posted = await waitFor { self.api.createMessageCalls.count == 2 }
        XCTAssertTrue(posted)
        XCTAssertEqual(identifies.value, 1)
    }

    func testMessage404WithStaleContactReidentifiesAndReposts() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        let calls = Counter()
        let sources = Sources()
        api.createMessageHandler = { source, _, body in
            let n = sources.add(source)
            if n == 1 { throw ChatwootError.http(code: 404) }
            return self.messageDTO(101, echoID: body.echoID)
        }
        let recovering = makeQueue(
            recoverer: SessionRecoverer(
                identifyOnce: { .notIdentified },
                reidentifyOnce: { [store] _ in
                    calls.value += 1
                    try? store?.write(Session(
                        identifier: "user-42", identifierHash: "hash-42",
                        sourceID: "src-2", pubsubToken: "tok-2", contactID: 9
                    ))
                    return .done
                },
                retryDelaysMs: [],
                now: { [unowned self] in self.clock }
            ),
            contactCheck: { _ in .stale }
        )
        await recovering.start()
        await recovering.enqueueText("привет")
        let delivered = await waitFor { try self.database.messages.get(101) != nil }
        XCTAssertTrue(delivered)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(sources.values, ["src-1", "src-2"])
    }

    func testFailedReidentifyDoesNotPostAgain() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        let calls = Counter()
        api.createMessageHandler = { _, _, _ in throw ChatwootError.http(code: 404) }
        let recovering = makeQueue(
            recoverer: SessionRecoverer(
                identifyOnce: { .notIdentified },
                reidentifyOnce: { _ in
                    calls.value += 1
                    return .failed(.http(code: 500))
                },
                retryDelaysMs: [],
                now: { [unowned self] in self.clock }
            ),
            contactCheck: { _ in .stale }
        )
        await recovering.start()
        await recovering.enqueueText("привет")
        let failed = await waitFor { (try? self.database.pending.get("echo-1"))?.state == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(api.createMessageCalls.count, 1)
        XCTAssertEqual(recovering.failures.value["echo-1"], .session)
    }

    func testMessage404WithUnknownContactDoesNotReidentify() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        let calls = Counter()
        api.createMessageHandler = { _, _, _ in throw ChatwootError.http(code: 404) }
        let recovering = makeQueue(
            recoverer: SessionRecoverer(
                identifyOnce: { .notIdentified },
                reidentifyOnce: { _ in
                    calls.value += 1
                    return .done
                },
                retryDelaysMs: [],
                now: { [unowned self] in self.clock }
            ),
            contactCheck: { _ in .unknown }
        )
        await recovering.start()
        await recovering.enqueueText("привет")
        let failed = await waitFor { (try? self.database.pending.get("echo-1"))?.state == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(api.createMessageCalls.count, 1)
    }

    func testReidentifyIsCappedUntilTheIntervalElapses() async throws {
        try database.conversations.upsert(StorageFixtures.conversation(7))
        let calls = Counter()
        let posts = Counter()
        api.createMessageHandler = { _, _, body in
            let n = posts.value + 1
            posts.value = n
            if n == 1 || n == 3 || n == 4 { throw ChatwootError.http(code: 404) }
            return self.messageDTO(100 + n, echoID: body.echoID)
        }
        let recovering = makeQueue(
            recoverer: SessionRecoverer(
                identifyOnce: { .notIdentified },
                reidentifyOnce: { [store] _ in
                    let n = calls.value + 1
                    calls.value = n
                    try? store?.write(Session(
                        identifier: "user-42", identifierHash: "hash-42",
                        sourceID: "src-\(n + 1)", pubsubToken: "tok-\(n + 1)", contactID: 9
                    ))
                    return .done
                },
                retryDelaysMs: [],
                reidentifyIntervalMs: 30_000,
                now: { [unowned self] in self.clock }
            ),
            contactCheck: { _ in .stale }
        )
        await recovering.start()
        await recovering.enqueueText("первый")
        let firstReposted = await waitFor { posts.value >= 2 }
        XCTAssertTrue(firstReposted)
        XCTAssertEqual(calls.value, 1)

        clock += 29_000
        await recovering.enqueueText("второй")
        let capped = await waitFor { (try? self.database.pending.get("echo-2"))?.state == .failed }
        XCTAssertTrue(capped)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(posts.value, 3)

        clock += 1_000
        await recovering.enqueueText("третий")
        let retried = await waitFor { posts.value == 5 }
        XCTAssertTrue(retried)
        XCTAssertEqual(calls.value, 2)
    }

    private func makeQueue(
        recoverer: SessionRecoverer,
        contactCheck: @escaping (Session) async -> SendQueue.ContactVerdict = { _ in .unknown }
    ) -> SendQueue {
        SendQueue(
            api: api, inboxIdentifier: "inbox-1", inboxId: 1, store: store,
            pendingDAO: database.pending, messageDAO: database.messages, conversationDAO: database.conversations,
            sync: sync, sessionGuard: SessionGuard(), attachmentsDir: attachmentsDir,
            now: { [unowned self] in self.clock },
            newEchoId: { [unowned self] in self.echoCounter += 1; return "echo-\(self.echoCounter)" },
            contactCheck: contactCheck,
            realtimeLive: { true },
            sessionRecoverer: recoverer
        )
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
        XCTAssertNotNil(match)
    }

    func testTooEarlyMessageIsNotMatch() {
        let match = DuplicateMatcher.find(
            pending: pending(),
            messages: [serverMessage(1, createdAt: 1_000 - DuplicateMatcher.beforeSeconds - 1)]
        )
        XCTAssertNil(match)
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
        XCTAssertNil(match)
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

private final class Counter: @unchecked Sendable {
    var value = 0
}

private final class Sources: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func add(_ value: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        stored.append(value)
        return stored.count
    }
}

private final class LineSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func log(level: LogLevel, domain: String, line: String, error: SanitizedError?) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if resumed {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resume() {
        lock.lock()
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
