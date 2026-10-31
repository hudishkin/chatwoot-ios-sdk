import Foundation

final class SessionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func isCurrent(_ generation: Int) -> Bool {
        current == generation
    }

    @discardableResult
    func invalidate<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return try block()
    }

    func ifCurrent<T>(_ generation: Int, _ block: () throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard value == generation else { return nil }
        return try block()
    }

    func snapshot<T>(_ block: (Int) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try block(value)
    }
}
