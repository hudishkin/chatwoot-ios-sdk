import XCTest
@testable import ChatwootSDK

final class SessionStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SessionStore!

    override func setUp() {
        super.setUp()
        directory = Fixtures.makeTempDirectory()
        store = SessionStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testWriteReadRoundTrip() throws {
        try store.write(Fixtures.session)
        XCTAssertEqual(store.read(), Fixtures.session)
        XCTAssertEqual(store.current, Fixtures.session)
    }

    func testReadWithoutFileIsNil() {
        XCTAssertNil(store.read())
        XCTAssertNil(store.current)
    }

    func testUnreadableFileIsDeleted() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("session.json"))
        XCTAssertNil(store.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path))
    }

    func testCleanupMarkerHidesSession() throws {
        try store.write(Fixtures.session)
        try store.markCleanupRequired()
        XCTAssertTrue(store.isCleanupRequired())
        XCTAssertNil(store.read(), "сессия скрыта, пока требуется очистка")
        XCTAssertNil(store.current)
        store.clearCleanupRequired()
        XCTAssertEqual(store.read(), Fixtures.session)
    }

    func testMarkerSurvivesNewStoreInstance() throws {
        try store.markCleanupRequired()
        let another = SessionStore(directory: directory)
        XCTAssertTrue(another.isCleanupRequired())
    }

    func testClearDropsSession() throws {
        try store.write(Fixtures.session)
        store.clear()
        XCTAssertNil(store.current)
        XCTAssertNil(store.read())
        XCTAssertNil(store.owner())
    }

    func testWriteRecordsOwner() throws {
        try store.write(Fixtures.session)
        XCTAssertEqual(store.owner(), "user-42")
        let owner = try String(contentsOf: directory.appendingPathComponent("data_owner"), encoding: .utf8)
        XCTAssertEqual(owner, "user-42")
    }

    func testDropSessionKeepsOwnerAcrossInstances() throws {
        try store.write(Fixtures.session)
        try store.dropSession()
        XCTAssertNil(store.read())
        XCTAssertNil(store.current)
        let another = SessionStore(directory: directory)
        XCTAssertEqual(another.owner(), "user-42")
    }

    func testDropSessionPersistsOwnerMissingFromLegacyStore() throws {
        try store.write(Fixtures.session)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("data_owner"))
        try store.dropSession()
        XCTAssertNil(store.read())
        let owner = try String(contentsOf: directory.appendingPathComponent("data_owner"), encoding: .utf8)
        XCTAssertEqual(owner, "user-42")
    }

    func testDropSessionKeepsSessionWhenOwnerCannotBeWritten() throws {
        try store.write(Fixtures.session)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("data_owner"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("data_owner.tmp"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.dropSession())
        XCTAssertEqual(store.read(), Fixtures.session)
    }

    func testOwnerFallsBackToSessionFile() throws {
        try store.write(Fixtures.session)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("data_owner"))
        XCTAssertEqual(store.owner(), "user-42")
    }

    func testOwnerFollowsNewIdentifier() throws {
        try store.write(Fixtures.session)
        let next = Session(identifier: "user-43", identifierHash: "hash-43", sourceID: "src-2", pubsubToken: "tok-2", contactID: 10)
        try store.write(next)
        XCTAssertEqual(store.owner(), "user-43")
    }

    func testSessionDescriptionIsMasked() {
        XCTAssertEqual(Fixtures.session.description, "Session(contactID=9)")
    }
}
