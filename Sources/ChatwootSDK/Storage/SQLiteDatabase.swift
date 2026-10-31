import Foundation
import SQLite3

final class SQLiteDatabase: @unchecked Sendable {
    enum DBError: Error, Equatable {
        case open(String)
        case prepare(String)
        case step(String)
    }

    enum Value {
        case null
        case integer(Int64)
        case text(String)

        static func optional(_ value: Int?) -> Value { value.map { .integer(Int64($0)) } ?? .null }
        static func optional(_ value: String?) -> Value { value.map(Value.text) ?? .null }
        static func bool(_ value: Bool) -> Value { .integer(value ? 1 : 0) }
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
        func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
        func optionalInt(_ index: Int32) -> Int? { isNull(index) ? nil : int(index) }
        func string(_ index: Int32) -> String { String(cString: sqlite3_column_text(statement, index)) }
        func optionalString(_ index: Int32) -> String? { isNull(index) ? nil : string(index) }
        func bool(_ index: Int32) -> Bool { int(index) != 0 }
    }

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0

    init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open(path, &handle)
        guard rc == SQLITE_OK else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(handle)
            throw DBError.open(message)
        }
        self.handle = handle
    }

    static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        try synced {
            var error: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &error)
            if rc != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "code \(rc)"
                sqlite3_free(error)
                throw DBError.step("\(message) [\(sql)]")
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ bindings: [Value] = []) throws -> Int {
        try synced {
            let statement = try prepare(sql, bindings)
            defer { sqlite3_finalize(statement) }
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_DONE else { throw DBError.step("\(lastError(rc)) [\(sql)]") }
            return Int(sqlite3_changes(handle))
        }
    }

    func query<T>(_ sql: String, _ bindings: [Value] = [], _ map: (Row) throws -> T) throws -> [T] {
        try synced {
            let statement = try prepare(sql, bindings)
            defer { sqlite3_finalize(statement) }
            var rows: [T] = []
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw DBError.step("\(lastError(rc)) [\(sql)]") }
                rows.append(try map(Row(statement: statement)))
            }
            return rows
        }
    }

    func transaction<T>(_ block: () throws -> T) throws -> T {
        try synced {
            if transactionDepth > 0 { return try block() }
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try block()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - Private

    private func synced<T>(_ block: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try block()
    }

    private func prepare(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw DBError.prepare("\(lastError(rc)) [\(sql)]")
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let number):
                sqlite3_bind_int64(statement, index, Int64(number))
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            }
        }
        return statement
    }

    private func lastError(_ rc: Int32) -> String {
        let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? ""
        return "\(message) (code \(rc))"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
