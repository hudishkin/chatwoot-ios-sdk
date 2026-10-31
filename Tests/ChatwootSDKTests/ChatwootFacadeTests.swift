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

    private func installCore() async throws -> ChatwootCore {
        let store = SessionStore(directory: directory)
        let core = ChatwootCore(config: try Fixtures.makeConfig(), api: api, sessionStore: store, dataDirectory: directory)
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

    func testSecondInitializeIsIgnored() throws {
        let config = try Fixtures.makeConfig()
        Chatwoot.installForTesting(nil)
        Chatwoot.initialize(config)
        let first = Chatwoot.core
        Chatwoot.initialize(config)
        XCTAssertTrue(first === Chatwoot.core, "второй initialize не подменяет граф")
    }
}
