import XCTest
@testable import ChatwootSDK

final class SQLiteDatabaseTests: XCTestCase {
    private var db: SQLiteDatabase!

    override func setUp() {
        super.setUp()
        db = try! SQLiteDatabase.inMemory()
        try! db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    }

    func testRunAndQuery() throws {
        try db.run("INSERT INTO t (id, v) VALUES (?, ?)", [.integer(1), .text("a")])
        try db.run("INSERT INTO t (id, v) VALUES (?, ?)", [.integer(2), .null])
        let rows = try db.query("SELECT id, v FROM t ORDER BY id") { row in
            (row.int(0), row.optionalString(1))
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].0, 1)
        XCTAssertEqual(rows[0].1, "a")
        XCTAssertEqual(rows[1].0, 2)
        XCTAssertNil(rows[1].1)
    }

    func testTransactionRollsBackOnThrow() throws {
        struct E: Error {}
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO t (id, v) VALUES (1, 'x')")
            throw E()
        })
        let count = try db.query("SELECT COUNT(*) FROM t") { $0.int(0) }.first
        XCTAssertEqual(count, 0, "строка внутри упавшей транзакции откатилась")
    }

    func testNestedTransactionJoinsOuter() throws {
        try db.transaction {
            try db.run("INSERT INTO t (id, v) VALUES (1, 'a')")
            try db.transaction {
                try db.run("INSERT INTO t (id, v) VALUES (2, 'b')")
            }
        }
        let count = try db.query("SELECT COUNT(*) FROM t") { $0.int(0) }.first
        XCTAssertEqual(count, 2)
    }

    func testRunReturnsChangedRows() throws {
        try db.run("INSERT INTO t (id, v) VALUES (1, 'a')")
        let changed = try db.run("UPDATE t SET v = 'b' WHERE id = 1")
        XCTAssertEqual(changed, 1)
        let unchanged = try db.run("UPDATE t SET v = 'c' WHERE id = 99")
        XCTAssertEqual(unchanged, 0)
    }

    func testBadSQLThrows() {
        XCTAssertThrowsError(try db.run("INSERT INTO nope VALUES (1)")) { error in
            guard case SQLiteDatabase.DBError.prepare = error else {
                return XCTFail("ожидалась ошибка prepare, получено \(error)")
            }
        }
    }
}
