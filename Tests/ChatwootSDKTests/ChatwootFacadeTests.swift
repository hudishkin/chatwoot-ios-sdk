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
        Chatwoot.installForTesting(nil)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func installCore(
        config: ChatwootConfig? = nil,
        activity: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher(),
        unreadPollIntervalMs: UInt64 = RealtimeController.pollIntervalMs,
        stopGraceMs: UInt64 = ChatwootCore.stopGraceMs
    ) async throws -> ChatwootCore {
        let store = SessionStore(directory: directory)
        let core = ChatwootCore(
            config: try config ?? Fixtures.makeConfig(),
            api: api,
            sessionStore: store,
            dataDirectory: directory,
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path), "файл сессии удалён")
        let store = await core.sessionStore
        XCTAssertFalse(store.isCleanupRequired(), "маркер очистки снят после успешной зачистки")
        let stack = await core.stack
        XCTAssertEqual(try stack?.database.messages.messagesOfInbox(inboxId: 1).count, 0, "таблицы стёрты, файл базы остаётся")
    }

    func testIdentifyAssemblesStackAndStartsSync() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        assertSuccess(result)
        let stack = await core.stack
        XCTAssertNotNil(stack, "стек данных собран после identify")
        await eventually { self.api.conversationsCalls == 1 }
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
        XCTAssertEqual(api.contactChecks, ["src-1"], "сигнал подтверждён GET contacts/{source_id} до ре-идентификации")
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
        XCTAssertEqual(api.createContactCalls.count, 1, "живая сессия не ре-идентифицируется")
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "условие не наступило за 2с", file: file, line: line)
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
        XCTAssertNil(session, "выход не оставляет сессию, которую identify дописал после зачистки")
    }

    func testStaleSessionBeforeIdentifyIsForcedOnNextIdentify() async throws {
        try SessionStore(directory: directory).write(Fixtures.session)
        api.contactStub = .failure(ChatwootError.http(code: 404))
        api.conversationsStub = .failure(ChatwootError.http(code: 401))
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact())
        let core = try await installCore()
        await core.catchUp()
        await eventually { self.api.contactChecks.count >= 1 }
        XCTAssertEqual(api.createContactCalls.count, 0, "до identify контакт заново не создаётся")

        let result = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        assertSuccess(result)
        XCTAssertEqual(api.createContactCalls.count, 1, "отложенный reidentify выполняется принудительно")
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
        XCTAssertEqual(api.createContactCalls.count, 1, "уже заменённая сессия не ре-идентифицируется")
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
        XCTAssertEqual(api.createContactCalls.count, creates + 1, "refresh без сессии заново идентифицирует запомненного пользователя")
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
        let core = try await installCore(config: config, activity: activity.eraseToAnyPublisher(), stopGraceMs: 40)
        _ = await Chatwoot.identify(user: Fixtures.user, identity: StubIdentityProvider(result: .success(Fixtures.identity)))
        let beforeChat = await core.connectionWanted.value
        XCTAssertFalse(beforeChat, "вне чата сокет не нужен")
        await core.noteChatAppeared()
        let whileChat = await core.connectionWanted.value
        XCTAssertTrue(whileChat)
        await core.noteChatDisappeared()
        let duringGrace = await core.connectionWanted.value
        XCTAssertTrue(duringGrace, "короткое скрытие не рвёт сокет")
        try? await Task.sleep(nanoseconds: 80_000_000)
        let afterGrace = await core.connectionWanted.value
        XCTAssertFalse(afterGrace)
    }

    func testSecondInitializeIsIgnored() throws {
        let config = try Fixtures.makeConfig()
        Chatwoot.installForTesting(nil)
        Chatwoot.initialize(config)
        let first = Chatwoot.core
        Chatwoot.initialize(config)
        XCTAssertTrue(first === Chatwoot.core, "второй initialize не подменяет граф")
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
