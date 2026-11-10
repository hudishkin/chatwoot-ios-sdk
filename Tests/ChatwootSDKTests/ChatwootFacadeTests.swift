import Combine
import XCTest
@testable import ChatwootSDK

final class ChatwootFacadeTests: XCTestCase {
    private var directory: URL!
    private var api: MockChatwootAPI!

    override func setUp() {
        super.setUp()
        directory = Fixtures.makeTempDirectory()
        api = MockChatwootAPI()
    }

    override func tearDown() {
        CWLog.install(sink: nil, console: false)
        Chatwoot.installForTesting(nil)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func installCore(
        config: ChatwootConfig? = nil,
        activity: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher(),
        socket: (any SocketManaging)? = nil,
        unreadPollIntervalMs: UInt64 = RealtimeController.pollIntervalMs,
        stopGraceMs: UInt64 = ChatwootCore.stopGraceMs
    ) async throws -> ChatwootCore {
        let store = SessionStore(directory: directory)
        let core = ChatwootCore(
            config: try config ?? Fixtures.makeConfig(),
            api: api,
            sessionStore: store,
            dataDirectory: directory,
            socket: socket,
            appActivity: activity,
            unreadPollIntervalMs: unreadPollIntervalMs,
            stopGraceMs: stopGraceMs
        )
        Chatwoot.installForTesting(core)
        return core
    }

    private func assertSuccess(_ result: Result<Void, ChatwootError>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .success = result else {
            return XCTFail("expected success, got \(result)", file: file, line: line)
        }
    }

    private func assertFailure(_ result: Result<Void, ChatwootError>, _ expected: ChatwootError, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else {
            return XCTFail("expected failure \(expected), got \(result)", file: file, line: line)
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    func testIdentifyBeforeInitializeIsNotInitialized() async {
        Chatwoot.installForTesting(nil)
        let provider = StubIdentityProvider(result: .success(Fixtures.identity))
        let result = await Chatwoot.identify(user: Fixtures.user, identity: provider)
        assertFailure(result, .notInitialized)
    }

    func testIdentifySuccessStoresSession() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        assertSuccess(result)
        let session = await core.session
        XCTAssertEqual(session, Fixtures.session)
    }

    func testIdentifyPropagatesProviderFailure() async throws {
        _ = try await installCore()
        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .failure(.network)))
        assertFailure(result, .network)
        XCTAssertEqual(api.createContactCalls.count, 0)
    }

    func testResetWipesSessionAndLocalData() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        var session = await core.session
        XCTAssertNotNil(session)

        await Chatwoot.reset()
        session = await core.session
        XCTAssertNil(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path))
        let store = await core.sessionStore
        XCTAssertFalse(store.isCleanupRequired())
        let stack = await core.stack
        XCTAssertEqual(try stack?.database.messages.messagesOfInbox(inboxId: 1).count, 0)
    }

    func testIdentifyAssemblesStackAndStartsSync() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        assertSuccess(result)
        let stack = await core.stack
        XCTAssertNotNil(stack)
        XCTAssertEqual(api.conversationsCalls, 1)
    }

    func testIdentifyAgainWithSameIdentitySyncsWithoutNewContact() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        _ = try await installCore()
        let provider = StubIdentityProvider(result: .success(Fixtures.identity))
        assertSuccess(await Chatwoot.identify(user: Fixtures.user, identity: provider))
        XCTAssertEqual(api.conversationsCalls, 1)

        assertSuccess(await Chatwoot.identify(user: Fixtures.user, identity: provider))
        XCTAssertEqual(api.createContactCalls.count, 1)
        XCTAssertEqual(api.conversationsCalls, 2)
    }

    func testIdentifyAgainWithNewHashReplacesSession() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        assertSuccess(await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity))))

        api.createContactStub = .success(Fixtures.contactInbox(sourceID: "src-2", pubsubToken: "tok-2"))
        let result = await Chatwoot.identify(
            user: Fixtures.user,
            identity: StubIdentityProvider(result: .success(Identity(identifier: "user-42", identifierHash: "hash-new")))
        )
        assertSuccess(result)
        let session = await core.session
        XCTAssertEqual(session?.identifierHash, "hash-new")
        XCTAssertEqual(session?.sourceID, "src-2")
        XCTAssertEqual(api.createContactCalls.count, 2)
        XCTAssertEqual(api.conversationsCalls, 2)
    }

    func testStaleSessionSignalTriggersReidentify() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        api.contactStub = .failure(ChatwootError.http(code: 404))
        let core = try await installCore()
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        XCTAssertEqual(api.createContactCalls.count, 1)
        core.sessionGuard.request("test_signal")
        await eventually { self.api.createContactCalls.count == 2 }
        XCTAssertEqual(api.contactChecks, ["src-1"])
    }

    func testHealthySessionSignalDoesNotReidentify() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        api.contactStub = .success(Fixtures.contactInbox())
        let core = try await installCore()
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        core.sessionGuard.request("test_signal")
        await eventually { self.api.contactChecks.count == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.createContactCalls.count, 1)
    }

    private var foreground: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }

    private static let unauthorizedDisconnect = #"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#

    private func connectedSocket() -> FakeSocketManaging {
        let socket = FakeSocketManaging()
        socket.state.send(.connected(since: 0))
        return socket
    }

    private func textMessage(_ id: Int, conversationID: Int = 7, echoID: String? = nil) -> MessageDTO {
        MessageDTO(
            id: id, content: "m\(id)", messageType: 1, contentType: "text", contentAttributes: nil,
            createdAt: 100, conversationID: conversationID, inboxID: 1, echoID: echoID, attachments: nil, sender: nil
        )
    }

    private func conversation(_ id: Int, messages: [MessageDTO]) -> ConversationDTO {
        ConversationDTO(
            id: id, uuid: nil, inboxID: 1, status: "open", contactLastSeenAt: 0, agentLastSeenAt: 0,
            messages: messages, contact: nil
        )
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testUnreadCountFollowsLocalMessagesAndClearsOnReset() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        var latest = -1
        let subscription = Chatwoot.unreadCount.sink { latest = $0 }
        defer { subscription.cancel() }
        XCTAssertEqual(latest, 0)

        let core = try await installCore()
        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        assertSuccess(result)
        let database = await core.stack?.database
        try database?.conversations.upsert(StorageFixtures.conversation(7, contactLastSeenAt: 100))
        try database?.messages.applyServerMessage(
            StorageFixtures.message(11, conversationId: 7, content: "ответ", type: 1, createdAt: 200),
            attachments: [],
            echoId: nil
        )
        await eventually { latest == 1 }

        await Chatwoot.reset()
        await eventually { latest == 0 }
    }

    func testReturnToForegroundSyncsInbox() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let activity = CurrentValueSubject<Bool, Never>(false)
        _ = try await installCore(activity: activity.eraseToAnyPublisher())
        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        assertSuccess(result)
        await eventually { self.api.conversationsCalls == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        activity.send(true)
        await eventually { self.api.conversationsCalls == 2 }
    }

    func testResetDuringIdentifyLeavesNoSession() async throws {
        let entered = expectation(description: "identity fetch started")
        let provider = PausingIdentityProvider(onEnter: { entered.fulfill() })
        let core = try await installCore()
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())

        let identifyTask = Task { await Chatwoot.identify(user: Fixtures.user, identity: provider) }
        await fulfillment(of: [entered], timeout: 2)
        let resetTask = Task { await Chatwoot.reset() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        provider.resume()
        _ = await identifyTask.value
        await resetTask.value
        let session = await core.session
        XCTAssertNil(session)
    }

    func testStaleSessionBeforeIdentifyIsForcedOnNextIdentify() async throws {
        try SessionStore(directory: directory).write(Fixtures.session)
        api.contactStub = .failure(ChatwootError.http(code: 404))
        api.conversationsStub = .failure(ChatwootError.http(code: 401))
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let logs = LineSink()
        CWLog.install(sink: logs, console: false)
        let core = try await installCore()
        await core.catchUp()
        await eventually { logs.lines.contains { $0.contains("reidentify deferred") } }
        XCTAssertEqual(api.createContactCalls.count, 0)

        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        assertSuccess(result)
        XCTAssertEqual(api.createContactCalls.count, 1)
    }

    func testReidentifySkipsWhenSessionAlreadyReplaced() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        let checksBefore = api.contactChecks.count

        let entered = expectation(description: "contact check started")
        let gate = ResumeGate()
        api.contactHandler = { _ in
            entered.fulfill()
            await gate.wait()
            throw ChatwootError.http(code: 404)
        }
        core.sessionGuard.request("test_signal")
        await fulfillment(of: [entered], timeout: 2)
        let replaced = Session(identifier: "user-42", identifierHash: "hash-42", sourceID: "src-2", pubsubToken: "tok-2", contactID: 9)
        try await core.sessionStore.write(replaced)
        gate.resume()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let sourceID = await core.session?.sourceID
        XCTAssertEqual(api.createContactCalls.count, 1)
        XCTAssertEqual(sourceID, "src-2")
        XCTAssertGreaterThan(api.contactChecks.count, checksBefore)
    }

    func testRefreshIdentifiesRememberedUserWhenSessionIsGone() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        await eventually { self.api.conversationsCalls >= 1 }
        try await core.sessionStore.dropSession()
        let creates = api.createContactCalls.count
        await Chatwoot.refresh()
        let session = await core.session
        XCTAssertEqual(api.createContactCalls.count, creates + 1)
        XCTAssertNotNil(session)
    }

    func testWhileChatOpenSocketFollowsTheChat() async throws {
        let activity = CurrentValueSubject<Bool, Never>(true)
        let config = try ChatwootConfig(
            baseURL: "https://chat.example.com",
            inboxIdentifier: "inbox-1",
            inboxID: 1,
            realtime: .whileChatOpen
        )
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore(
            config: config,
            activity: activity.eraseToAnyPublisher(),
            socket: FakeSocketManaging(),
            stopGraceMs: 40
        )
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        let beforeChat = await core.connectionWanted.value
        XCTAssertFalse(beforeChat)
        await core.noteChatAppeared()
        let whileChat = await core.connectionWanted.value
        XCTAssertTrue(whileChat)
        await core.noteChatDisappeared()
        let duringGrace = await core.connectionWanted.value
        XCTAssertTrue(duringGrace)
        var dropped = false
        for _ in 0..<50 {
            if await core.connectionWanted.value == false {
                dropped = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(dropped)
    }

    func testDeferredReidentifySurvivesAFailingIdentify() async throws {
        try SessionStore(directory: directory).write(Fixtures.session)
        api.contactStub = .failure(ChatwootError.http(code: 404))
        api.conversationsStub = .failure(ChatwootError.http(code: 401))
        api.createContactStub = .success(Fixtures.contactInbox(sourceID: "src-2", pubsubToken: "tok-2"))
        api.updateContactStub = .success(Fixtures.contact())
        let logs = LineSink()
        CWLog.install(sink: logs, console: false)
        let core = try await installCore()
        await core.catchUp()
        await eventually { logs.lines.contains { $0.contains("reidentify deferred") } }
        XCTAssertEqual(api.createContactCalls.count, 0)
        api.conversationsStub = .success([])

        let failed = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .failure(.network)))
        assertFailure(failed, .network)
        XCTAssertEqual(api.createContactCalls.count, 0)

        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        assertSuccess(result)
        XCTAssertEqual(api.createContactCalls.count, 1)
        let session = await core.session
        XCTAssertEqual(session?.sourceID, "src-2")
        XCTAssertEqual(session?.pubsubToken, "tok-2")
    }

    func testStaleBurstReidentifiesOnceAndResubscribes() async throws {
        let socket = connectedSocket()
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore(activity: foreground, socket: socket)
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        await eventually { socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok-1")) }

        api.contactStub = .failure(ChatwootError.http(code: 404))
        api.createContactStub = .success(Fixtures.contactInbox(sourceID: "src-2", pubsubToken: "tok-2"))
        core.sessionGuard.request("http_404")
        core.sessionGuard.request("http_404")
        core.sessionGuard.request("http_404")
        await eventually { self.api.createContactCalls.count == 2 }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(api.createContactCalls.count, 2)
        let session = await core.session
        XCTAssertEqual(session?.pubsubToken, "tok-2")
        XCTAssertTrue(socket.desiredHistory.contains(false))
        XCTAssertTrue(socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok-2")))
    }

    func testTerminalDisconnectWithHealthyContactLeavesTheSession() async throws {
        let socket = connectedSocket()
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        api.contactStub = .success(Fixtures.contactInbox())
        let core = try await installCore(activity: foreground, socket: socket)
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        await eventually { socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok-1")) }
        socket.frames.send(.text(Self.unauthorizedDisconnect))
        await eventually { socket.desiredHistory.contains(false) }
        await eventually { self.api.contactChecks.count >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.createContactCalls.count, 1)
        let session = await core.session
        XCTAssertEqual(session?.pubsubToken, "tok-1")
    }

    func testTerminalDisconnectWithStaleContactReidentifiesOnce() async throws {
        let socket = connectedSocket()
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore(activity: foreground, socket: socket)
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        await eventually { socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok-1")) }
        api.contactStub = .failure(ChatwootError.http(code: 404))
        api.createContactStub = .success(Fixtures.contactInbox(sourceID: "src-2", pubsubToken: "tok-2"))
        socket.frames.send(.text(Self.unauthorizedDisconnect))
        await eventually { self.api.createContactCalls.count == 2 }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(api.createContactCalls.count, 2)
        let session = await core.session
        XCTAssertEqual(session?.pubsubToken, "tok-2")
    }

    func testThreeMissedConfirmsWithHealthyContactDoesNotReidentify() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        api.contactStub = .success(Fixtures.contactInbox())
        let core = try await installCore()
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        core.sessionGuard.onMissedConfirms(1)
        core.sessionGuard.onMissedConfirms(2)
        core.sessionGuard.onMissedConfirms(3)
        await eventually { self.api.contactChecks.count >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.createContactCalls.count, 1)
        XCTAssertEqual(api.contactChecks.count, 1)
    }

    func testConversations404WithUnknownContactDoesNotReidentify() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        api.contactStub = .failure(ChatwootError.network)
        let core = try await installCore()
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        core.sessionGuard.onHttp(code: 404, path: "/public/api/v1/inboxes/inbox-1/contacts/src-1/conversations")
        await eventually { self.api.contactChecks.count >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.createContactCalls.count, 1)
    }

    func testResetDuringCreateContactLeavesNoSession() async throws {
        let entered = expectation(description: "create contact")
        let gate = ResumeGate()
        api.createContactHandler = { _ in
            entered.fulfill()
            await gate.wait()
            return Fixtures.contactInbox()
        }
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        let identifyTask = Task { await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity))) }
        await fulfillment(of: [entered], timeout: 2)
        let resetTask = Task { await Chatwoot.reset() }
        gate.resume()
        _ = await identifyTask.value
        await resetTask.value
        let session = await core.session
        XCTAssertNil(session)
    }

    func testResetDuringSyncDropsTheSnapshot() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        let entered = expectation(description: "conversations")
        let gate = ResumeGate()
        api.conversationsHandler = {
            entered.fulfill()
            await gate.wait()
            return .success([self.conversation(7, messages: [self.textMessage(11)])])
        }
        let syncing = Task { await core.stack?.sync.sync(.refresh) }
        await fulfillment(of: [entered], timeout: 2)
        await Chatwoot.reset()
        gate.resume()
        _ = await syncing.value
        let count = try await core.stack?.database.messages.messagesOfInbox(inboxId: 1).count
        XCTAssertEqual(count, 0)
    }

    func testResetDuringMessagePostDoesNotStoreTheAck() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        try await core.stack?.database.conversations.upsert(StorageFixtures.conversation(7))
        let entered = expectation(description: "post message")
        let gate = ResumeGate()
        api.createMessageHandler = { _, _, body in
            entered.fulfill()
            await gate.wait()
            return self.textMessage(101, echoID: body.echoID)
        }
        let queue = await core.stack?.sendQueue
        await queue?.enqueueText("привет")
        await fulfillment(of: [entered], timeout: 2)
        await Chatwoot.reset()
        gate.resume()
        await eventually { queue?.inFlight.value.isEmpty == true }
        let count = try await core.stack?.database.messages.messagesOfInbox(inboxId: 1).count
        XCTAssertEqual(count, 0)
    }

    func testSwitchingUserSubscribesWithTheNewTokenAndWipesHistory() async throws {
        let socket = connectedSocket()
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore(activity: foreground, socket: socket)
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        await eventually { socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok-1")) }
        try await core.stack?.database.conversations.upsert(StorageFixtures.conversation(7))
        try await core.stack?.database.messages.applyServerMessage(
            StorageFixtures.message(11, conversationId: 7, createdAt: 1), attachments: [], echoId: nil
        )

        let other = Identity(identifier: "user-43", identifierHash: "hash-43")
        api.createContactStub = .success(Fixtures.contactInbox(sourceID: "src-2", pubsubToken: "tok-2"))
        api.updateContactStub = .success(Fixtures.contact(identifier: "user-43"))
        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(other)))
        assertSuccess(result)
        await eventually { socket.sent.contains(CableCodec.subscribeFrame(pubsubToken: "tok-2")) }
        XCTAssertTrue(socket.desiredHistory.contains(false))
        let session = await core.session
        XCTAssertEqual(session?.identifier, "user-43")
        let count = try await core.stack?.database.messages.messagesOfInbox(inboxId: 1).count
        XCTAssertEqual(count, 0)
    }

    func testSecondInitializeIsIgnored() throws {
        let config = try Fixtures.makeConfig()
        Chatwoot.installForTesting(nil)
        Chatwoot.initialize(config)
        let first = Chatwoot.core
        Chatwoot.initialize(config)
        XCTAssertTrue(first === Chatwoot.core)
    }
}

private final class PausingIdentityProvider: IdentityProvider, @unchecked Sendable {
    private let onEnter: @Sendable () -> Void
    private let gate = ResumeGate()

    init(onEnter: @escaping @Sendable () -> Void) {
        self.onEnter = onEnter
    }

    func fetch() async -> Result<Identity, ChatwootError> {
        onEnter()
        await gate.wait()
        return .success(Fixtures.identity)
    }

    func resume() { gate.resume() }
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
