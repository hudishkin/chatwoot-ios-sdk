import Foundation

final class StaleSessionVerifier: @unchecked Sendable {
    enum Verdict {
        case healthy, stale, unknown
    }

    private let api: ChatwootAPI
    private let inboxIdentifier: String
    private let now: () -> UInt64
    private let minIntervalMs: UInt64
    private let maxIntervalMs: UInt64

    private let lock = NSLock()
    private var lastForcedAt: UInt64?
    private var intervalMs: UInt64

    init(
        api: ChatwootAPI,
        inboxIdentifier: String,
        now: @escaping () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) },
        minIntervalMs: UInt64 = StaleSessionVerifier.minIntervalMs,
        maxIntervalMs: UInt64 = StaleSessionVerifier.maxIntervalMs
    ) {
        self.api = api
        self.inboxIdentifier = inboxIdentifier
        self.now = now
        self.minIntervalMs = minIntervalMs
        self.maxIntervalMs = maxIntervalMs
        self.intervalMs = minIntervalMs
    }

    func verify(session: Session) async -> Verdict {
        let verdict: Verdict
        do {
            _ = try await api.contact(sourceID: session.sourceID, identifier: session.identifier, identifierHash: session.identifierHash)
            verdict = .healthy
        } catch let error as ChatwootError {
            if case .http(let code) = error, code == 404 || code == 401 {
                verdict = .stale
            } else {
                verdict = .unknown
            }
        } catch {
            verdict = .unknown
        }
        if verdict == .healthy {
            resetInterval()
        }
        CWLog.i(.auth, "session check -> \(verdict)")
        return verdict
    }

    private func resetInterval() {
        lock.lock()
        intervalMs = minIntervalMs
        lock.unlock()
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let at = now()
        if let last = lastForcedAt {
            if at - last < intervalMs { return false }
            intervalMs = min(intervalMs * 2, maxIntervalMs)
        }
        lastForcedAt = at
        return true
    }

    static let minIntervalMs: UInt64 = 10 * 60 * 1000
    static let maxIntervalMs: UInt64 = 60 * 60 * 1000
}
