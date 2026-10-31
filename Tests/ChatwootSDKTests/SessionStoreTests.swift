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
    }

    func testSessionDescriptionIsMasked() {
        XCTAssertEqual(Fixtures.session.description, "Session(contactID=9)")
    }
}
