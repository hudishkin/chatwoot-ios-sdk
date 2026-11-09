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
    private var ownerFile: URL { directory.appendingPathComponent("data_owner") }

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
        try mutate {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if storedOwner() != session.identifier {
                try replaceFile(ownerFile, data: Data(session.identifier.utf8))
            }
            let data = try encoder.encode(session)
            try data.write(to: sessionFile, options: .atomic)
            current = session
        }
        currentSubject.send(session)
    }

    /// Identifier of the last session written, until `clear`. A store from before
    /// `data_owner` existed falls back to the session file.
    func owner() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedOwner() ?? readFile()?.identifier
    }

    func clear() {
        lock.lock()
        deleteSession()
        try? fileManager.removeItem(at: ownerFile)
        try? fileManager.removeItem(at: URL(fileURLWithPath: ownerFile.path + ".tmp"))
        lock.unlock()
        currentSubject.send(nil)
    }

    /// Drops only the session (a reidentify of the same user). Local data stays
    /// the owner's. A store written before `data_owner` existed gets the owner
    /// from the session first; if that write fails this throws and the session
    /// is kept, so the data never loses its owner.
    func dropSession() throws {
        try mutate {
            if let identifier = readFile()?.identifier, storedOwner() != identifier {
                try replaceFile(ownerFile, data: Data(identifier.utf8))
            }
            deleteSession()
        }
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

    private func storedOwner() -> String? {
        guard fileManager.fileExists(atPath: ownerFile.path) else { return nil }
        do {
            let text = try String(contentsOf: ownerFile, encoding: .utf8)
            return text.isEmpty ? nil : text
        } catch {
            CWLog.w(.auth, "data owner unreadable (\(type(of: error)))")
            return nil
        }
    }

    private func deleteSession() {
        try? fileManager.removeItem(at: sessionFile)
        try? fileManager.removeItem(at: URL(fileURLWithPath: sessionFile.path + ".tmp"))
        current = nil
    }

    /// Writes `url` via a sibling `url.tmp`, so a blocked temp path fails before the destination changes.
    private func replaceFile(_ url: URL, data: Data) throws {
        let temp = URL(fileURLWithPath: url.path + ".tmp")
        try data.write(to: temp)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: url)
        }
    }

    private func mutate(_ body: () throws -> Void) throws {
        lock.lock()
        do {
            try body()
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }
}
