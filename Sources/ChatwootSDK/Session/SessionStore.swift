import Combine
import Foundation

final class SessionStore {
    enum StoreError: Error, Equatable {
        case cannotWriteMarker
    }

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    let currentSubject = CurrentValueSubject<Session?, Never>(nil)

    private var sessionFile: URL { directory.appendingPathComponent("session.json") }
    private var markerFile: URL { directory.appendingPathComponent("cleanup_required") }

    private(set) var current: Session?

    private var cleanupPending = false

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    @discardableResult
    func read() -> Session? {
        lock.lock()
        let session = isCleanupRequiredLocked() ? nil : readFile()
        current = session
        lock.unlock()
        currentSubject.send(session)
        return session
    }

    private func readFile() -> Session? {
        guard fileManager.fileExists(atPath: sessionFile.path) else { return nil }
        do {
            let data = try Data(contentsOf: sessionFile)
            return try decoder.decode(Session.self, from: data)
        } catch {
            CWLog.w(.auth, "session file unreadable, deleted")
            try? fileManager.removeItem(at: sessionFile)
            return nil
        }
    }

    func write(_ session: Session) throws {
        lock.lock()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: sessionFile, options: .atomic)
        current = session
        lock.unlock()
        currentSubject.send(session)
    }

    func clear() {
        lock.lock()
        try? fileManager.removeItem(at: sessionFile)
        current = nil
        lock.unlock()
        currentSubject.send(nil)
    }

    func markCleanupRequired() throws {
        lock.lock()
        cleanupPending = true
        current = nil
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: markerFile.path) {
            guard fileManager.createFile(atPath: markerFile.path, contents: nil) else {
                lock.unlock()
                throw StoreError.cannotWriteMarker
            }
        }
        lock.unlock()
        currentSubject.send(nil)
    }

    func isCleanupRequired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCleanupRequiredLocked()
    }

    func clearCleanupRequired() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: markerFile)
        cleanupPending = false
    }

    private func isCleanupRequiredLocked() -> Bool {
        cleanupPending || fileManager.fileExists(atPath: markerFile.path)
    }
}
