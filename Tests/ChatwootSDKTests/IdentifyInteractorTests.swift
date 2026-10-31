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
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func stubSuccess(identifier: String? = "user-42") {
        api.createContactStub = .success(Fixtures.contactInbox())
        api.updateContactStub = .success(Fixtures.contact(identifier: identifier))
    }

    func testFreshIdentifyCreatesPatchesAndStoresSession() async {
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
    }

    func testSameIdentifierIsNoOp() async {
        stubSuccess()
        try! store.write(Fixtures.session)
        let result = await interactor.identify(user: Fixtures.user, identity: Fixtures.identity)
        XCTAssertEqual(result, .success(Fixtures.session))
        XCTAssertEqual(api.createContactCalls.count, 0, "хранимая сессия — без сетевых вызовов")
        XCTAssertEqual(api.updateContactCalls.count, 0)
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
}
