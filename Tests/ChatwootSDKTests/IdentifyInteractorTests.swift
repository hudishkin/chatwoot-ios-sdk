import XCTest
@testable import ChatwootSDK

final class IdentifyInteractorTests: XCTestCase {
    private var directory: URL!
    private var api: MockChatwootAPI!
    private var store: SessionStore!
    private var wipeCount = 0
    private var interactor: IdentifyInteractor!

    override func setUp() {
        super.setUp()
        directory = Fixtures.makeTempDirectory()
        api = MockChatwootAPI()
        store = SessionStore(directory: directory)
        wipeCount = 0
        interactor = IdentifyInteractor(api: api, store: store) { [unowned self] in
            self.wipeCount += 1
            self.store.clearCleanupRequired()
        }
    }

    override func tearDown() {
        CWLog.install(sink: nil, console: false)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func stubSuccess(identifier: String? = "user-42") {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact(identifier: identifier))
    }

    func testFreshIdentifyCreatesPatchesAndStoresSession() async throws {
        stubSuccess()
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        guard case .success(let session) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(session, Fixtures.session)
        XCTAssertEqual(store.current, Fixtures.session)

        XCTAssertEqual(api.createContactCalls.count, 1)
        let create = api.createContactCalls[0]
        XCTAssertEqual(create.identifier, "user-42")
        XCTAssertEqual(create.identifierHash, "hash-42")
        XCTAssertEqual(create.name, "Jane")
        XCTAssertEqual(create.avatarURL, "https://app.example.com/avatar.png")

        XCTAssertEqual(api.updateContactCalls.count, 1)
        XCTAssertEqual(api.updateContactCalls[0].sourceID, "src-1", "PATCH идёт по source_id из create")
        let patch = try jsonObject(api.updateContactCalls[0].body)
        XCTAssertEqual(patch["name"] as? String, "Jane")
        XCTAssertEqual(patch["identifier_hash"] as? String, "hash-42")
        XCTAssertEqual(patch["avatar_url"] as? String, "https://app.example.com/avatar.png")
    }

    func testCreateAndPatchOmitNilAvatar() async throws {
        let user = ChatwootUser(name: "Jane", avatarURL: nil)
        stubSuccess()
        let result = await interactor.identify(user: user, identity: Fixtures.identity)
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        let create = try jsonObject(api.createContactCalls[0])
        XCTAssertEqual(Set(create.keys), ["identifier", "identifier_hash", "name"])
        let patch = try jsonObject(api.updateContactCalls[0].body)
        XCTAssertEqual(patch["identifier"] as? String, "user-42")
        XCTAssertEqual(patch["identifier_hash"] as? String, "hash-42")
        XCTAssertEqual(patch["name"] as? String, "Jane")
        XCTAssertNil(patch["avatar_url"])
        XCTAssertNil(patch["custom_attributes"])
    }

    func testSameIdentifierIsNoOp() async {
        stubSuccess()
        try! store.write(Fixtures.session)
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .success(Fixtures.session))
        XCTAssertEqual(api.createContactCalls.count, 0, "хранимая сессия — без сетевых вызовов")
        XCTAssertEqual(api.updateContactCalls.count, 0)
        XCTAssertEqual(wipeCount, 0)
    }

    func testDifferentIdentifierWipesFirst() async {
        stubSuccess(identifier: "user-43")
        try! store.write(Fixtures.session)
        let other = Identity(identifier: "user-43", identifierHash: "hash-43")
        let result = await interactor.identify(user: Fixtures.user, identity: other)
        guard case .success(let session) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(wipeCount, 1, "данные прежнего пользователя стёрты до создания нового")
        XCTAssertEqual(session.identifier, "user-43")
        XCTAssertEqual(api.createContactCalls.count, 1)
    }

    func testForceReidentifyRunsCallsAgain() async {
        stubSuccess()
        try! store.write(Fixtures.session)
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity, force: true)
        XCTAssertEqual(result, .success(Fixtures.session))
        XCTAssertEqual(api.createContactCalls.count, 1, "force сбрасывает сессию и повторяет POST/PATCH")
        XCTAssertEqual(wipeCount, 0, "force не стирает локальные данные, только сессию")
        XCTAssertEqual(store.owner(), "user-42")
    }

    func testSameIdentifierDifferentHashRecreatesSessionWithoutWipe() async {
        stubSuccess()
        let old = Session(identifier: "user-42", identifierHash: "old-hash", sourceID: "old-src", pubsubToken: "old-tok", contactID: 4)
        try! store.write(old)
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        guard case .success(let session) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(session.identifierHash, "hash-42")
        XCTAssertEqual(session.sourceID, "src-1")
        XCTAssertEqual(wipeCount, 0, "смена хеша не стирает локальные данные")
        XCTAssertEqual(api.createContactCalls.count, 1)
        XCTAssertEqual(store.owner(), "user-42")
    }

    func testFailedReidentifyThenOtherIdentifierWipes() async {
        api.createContactStub = .failure(ChatwootError.http(code: 503))
        let old = Session(identifier: "old-user", identifierHash: "old-hash", sourceID: "s", pubsubToken: "p", contactID: 1)
        try! store.write(old)
        let failed = await interactor.identify(
            user: Fixtures.user,
            identity: Identity(identifier: "old-user", identifierHash: "old-hash"),
            force: true
        )
        XCTAssertEqual(failed, .failure(.http(code: 503)))
        XCTAssertNil(store.read())
        XCTAssertEqual(store.owner(), "old-user")

        stubSuccess()
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(wipeCount, 1, "после потерянной сессии чужой identifier всё равно зачищает данные")
        XCTAssertEqual(store.owner(), "user-42")
    }

    func testLegacySessionWithoutOwnerStillWipesAfterFailedReidentify() async throws {
        api.createContactStub = .failure(ChatwootError.http(code: 503))
        let old = Session(identifier: "old-user", identifierHash: "old-hash", sourceID: "s", pubsubToken: "p", contactID: 1)
        try store.write(old)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("data_owner"))
        let failed = await interactor.identify(
            user: Fixtures.user,
            identity: Identity(identifier: "old-user", identifierHash: "old-hash"),
            force: true
        )
        XCTAssertEqual(failed, .failure(.http(code: 503)))
        XCTAssertNil(store.read())
        let owner = try String(contentsOf: directory.appendingPathComponent("data_owner"), encoding: .utf8)
        XCTAssertEqual(owner, "old-user")

        stubSuccess()
        _ = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(wipeCount, 1)
    }

    func testReidentifyKeepsSessionWhenOwnerCannotBeSaved() async throws {
        api.createContactStub = .success(Fixtures.contactInbox())
        let old = Session(identifier: "user-42", identifierHash: "hash-42", sourceID: "src-1", pubsubToken: "tok-1", contactID: 9)
        try store.write(old)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("data_owner"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("data_owner.tmp"), withIntermediateDirectories: true)
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity, force: true)
        XCTAssertEqual(result, .failure(.unknown))
        XCTAssertEqual(store.read(), old)
        XCTAssertEqual(api.createContactCalls.count, 0, "сессию не сбрасываем, пока владелец данных не записан")
    }

    func testFailedReidentifyThenSameIdentifierKeepsData() async {
        api.createContactStub = .failure(ChatwootError.http(code: 503))
        try! store.write(Fixtures.session)
        let failed = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity, force: true)
        XCTAssertEqual(failed, .failure(.http(code: 503)))

        stubSuccess()
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        guard case .success(let session) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(wipeCount, 0)
        XCTAssertEqual(session.sourceID, "src-1")
        XCTAssertEqual(store.owner(), "user-42")
    }

    func testIdentifierMismatchFailsAndWipes() async {
        stubSuccess(identifier: "someone-else")
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .failure(.identityMismatch))
        XCTAssertEqual(wipeCount, 1)
        XCTAssertNil(store.current)
    }

    func testIncompleteCreateResponseIsUnknown() async {
        api.createContactStub = .success(Fixtures.contactInbox(sourceID: nil))
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .failure(.unknown))
    }

    func testNetworkErrorPropagates() async {
        api.createContactStub = .failure(ChatwootError.network)
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .failure(.network))
        XCTAssertEqual(api.updateContactCalls.count, 0, "PATCH не уходит после неудачного create")
    }

    func testHttpErrorPropagates() async {
        api.updateContactStub = .failure(ChatwootError.http(code: 500))
        api.createContactStub = .success(Fixtures.contactInbox())
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .failure(.http(code: 500)))
    }

    func testUnfinishedCleanupIsFinishedFirst() async {
        stubSuccess()
        try! store.markCleanupRequired()
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(wipeCount, 1)
        XCTAssertFalse(store.isCleanupRequired())
    }

    func testFailingWipeBlocksIdentify() async {
        stubSuccess()
        try! store.write(Fixtures.session)
        let failing = IdentifyInteractor(api: api, store: store) { throw ChatwootError.unknown }
        let other = Identity(identifier: "user-43", identifierHash: "hash-43")
        let result = await failing.identify(user: Fixtures.user, identity: other)
        XCTAssertEqual(result, .failure(.unknown))
        XCTAssertEqual(api.createContactCalls.count, 0, "при неудавшейся зачистке сеть не трогаем")
    }

    func testPatchFailureLogOmitsSecrets() async {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .failure(ChatwootError.http(code: 500))
        let sink = LineSink()
        CWLog.install(sink: sink, console: false)
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .failure(.http(code: 500)))
        assertLogOmitsSecrets(sink.lines, needle: "identify patch failed: http 500")
    }

    func testCreateFailureLogUsesOnlyTheErrorType() async {
        api.createContactStub = .failure(SecretFailure())
        let sink = LineSink()
        CWLog.install(sink: sink, console: false)
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .failure(.unknown))
        assertLogOmitsSecrets(sink.lines, needle: "identify create failed: SecretFailure")
    }

    func testSessionDirectoryThatIsAFileIsUnknown() async {
        let blocked = directory.appendingPathComponent("blocked")
        FileManager.default.createFile(atPath: blocked.path, contents: Data("not-a-directory".utf8))
        let blockedStore = SessionStore(directory: blocked)
        let blockedInteractor = IdentifyInteractor(api: api, store: blockedStore) {}
        stubSuccess()
        let sink = LineSink()
        CWLog.install(sink: sink, console: false)
        let result = await blockedInteractor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .failure(.unknown))
        XCTAssertTrue(sink.lines.contains { $0.contains("session not saved") })
    }

    func testIdentifierMismatchWhenWipeThrowsIsUnknown() async {
        stubSuccess(identifier: "someone-else")
        var wipes = 0
        let failing = IdentifyInteractor(api: api, store: store) {
            wipes += 1
            throw ChatwootError.unknown
        }
        let result = await failing.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .failure(.unknown))
        XCTAssertEqual(wipes, 1)
        XCTAssertNil(store.read())
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertLogOmitsSecrets(_ lines: [String], needle: String, file: StaticString = #filePath, line: UInt = #line) {
        let blob = lines.joined(separator: "\n")
        XCTAssertTrue(blob.contains(needle), blob, file: file, line: line)
        for secret in ["user-42", "hash-42", "src-1", "tok-1", "Jane"] {
            XCTAssertFalse(blob.contains(secret), "лог содержит \(secret): \(blob)", file: file, line: line)
        }
    }
}

private struct SecretFailure: Error, CustomStringConvertible {
    var description: String { "user-42 hash-42 src-1 tok-1 Jane" }
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
