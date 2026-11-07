import Foundation

/// What a send gets when it asks for a session.
enum SessionRecovery: Equatable {
    /// Identify ran, or another call settled the session meanwhile. The send reads the session again.
    case done
    /// Nobody was identified in this process, or a logout came after.
    case notIdentified
    /// A logout began while identifying. The send belongs to the user being signed out.
    case aborted
    /// Identify was tried and failed (after the retries for a transient error).
    case failed(ChatwootError)
    /// A forced reidentify for a send ran too recently. None is started.
    case capped
}

/// Taken when a send is queued. A later send shares a recovery that finished after this ticket.
struct RecoveryTicket: Equatable {
    let identifies: Int
    let reidentifies: Int
}

/// Restores the session of a send. Each kind of run is single-flight.
///
/// `recover` identifies with the remembered user when there is no session.
/// `reidentify` replaces a session the server confirmed as gone. The user is waiting,
/// so the background reidentify cap does not apply. A run starts at most once per
/// `reidentifyIntervalMs`. A burst of queued sends shares one run, whatever its outcome.
actor SessionRecoverer {
    private let identifyOnce: () async -> SessionRecovery
    private let reidentifyOnce: (Session) async -> SessionRecovery
    private let retryDelaysMs: [UInt64]
    private let timeoutMs: UInt64
    private let reidentifyIntervalMs: UInt64
    private let now: () -> UInt64

    private var identifyRuns = 0
    private var reidentifyRuns = 0
    private var lastIdentify: SessionRecovery = .notIdentified
    private var lastReidentify: SessionRecovery = .notIdentified
    private var lastReidentifyAt: UInt64?
    private var identifyInFlight: Task<SessionRecovery, Never>?
    private var reidentifyInFlight: Task<SessionRecovery, Never>?

    init(
        identifyOnce: @escaping () async -> SessionRecovery,
        reidentifyOnce: @escaping (Session) async -> SessionRecovery = { _ in .notIdentified },
        retryDelaysMs: [UInt64] = SessionRecoverer.defaultRetryDelaysMs,
        timeoutMs: UInt64 = SessionRecoverer.defaultTimeoutMs,
        reidentifyIntervalMs: UInt64 = SessionRecoverer.defaultReidentifyIntervalMs,
        now: @escaping () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.identifyOnce = identifyOnce
        self.reidentifyOnce = reidentifyOnce
        self.retryDelaysMs = retryDelaysMs
        self.timeoutMs = timeoutMs
        self.reidentifyIntervalMs = reidentifyIntervalMs
        self.now = now
    }

    func ticket() -> RecoveryTicket {
        RecoveryTicket(identifies: identifyRuns, reidentifies: reidentifyRuns)
    }

    /// Shares an identify that finished after `since` (or is in progress), else runs one.
    /// A reidentify that finished after `since` counts too: a failed one leaves no session.
    func recover(since: RecoveryTicket) async -> SessionRecovery {
        if let finished = finished(runs: identifyRuns, since: since.identifies, last: lastIdentify) {
            return finished
        }
        if let finished = finished(runs: reidentifyRuns, since: since.reidentifies, last: lastReidentify) {
            return finished
        }
        let task: Task<SessionRecovery, Never>
        if let identifyInFlight {
            task = identifyInFlight
        } else {
            task = Task { await self.performIdentify() }
            identifyInFlight = task
        }
        return await task.value
    }

    /// Replaces the confirmed `stale` session. Shares a reidentify that finished after `since`.
    func reidentify(stale: Session, since: RecoveryTicket) async -> SessionRecovery {
        if let finished = finished(runs: reidentifyRuns, since: since.reidentifies, last: lastReidentify) {
            return finished
        }
        let task: Task<SessionRecovery, Never>
        if let reidentifyInFlight {
            task = reidentifyInFlight
        } else {
            task = Task { await self.performReidentify(stale) }
            reidentifyInFlight = task
        }
        return await task.value
    }

    private func performIdentify() async -> SessionRecovery {
        let result = await attempts { await self.identifyOnce() }
        lastIdentify = result
        identifyRuns += 1
        identifyInFlight = nil
        return result
    }

    private func performReidentify(_ stale: Session) async -> SessionRecovery {
        let at = now()
        if let lastReidentifyAt, at - lastReidentifyAt < reidentifyIntervalMs {
            CWLog.w(.send, "send reidentify capped: one ran \(at - lastReidentifyAt)ms ago")
            lastReidentify = .capped
            reidentifyRuns += 1
            reidentifyInFlight = nil
            return .capped
        }
        lastReidentifyAt = at
        CWLog.i(.send, "send reidentify start")
        let result = await attempts { await self.reidentifyOnce(stale) }
        CWLog.i(.send, "send reidentify -> \(result.logLabel)")
        lastReidentify = result
        reidentifyRuns += 1
        reidentifyInFlight = nil
        return result
    }

    private func finished(runs: Int, since: Int, last: SessionRecovery) -> SessionRecovery? {
        runs == since ? nil : last
    }

    private func attempts(_ once: @escaping () async -> SessionRecovery) async -> SessionRecovery {
        do {
            return try await withDeadline(ms: timeoutMs) {
                await self.retrying(once)
            }
        } catch {
            CWLog.w(.send, "session restore timed out ms=\(timeoutMs)")
            return .failed(.network)
        }
    }

    private func retrying(_ once: @escaping () async -> SessionRecovery) async -> SessionRecovery {
        var attempt = 0
        while true {
            let result = await once()
            if case .failed(let error) = result, error.isTransient, attempt < retryDelaysMs.count {
                let wait = retryDelaysMs[attempt]
                attempt += 1
                CWLog.w(.send, "session restore attempt=\(attempt) failed \(error.logLabel), retry in \(wait)ms")
                try? await Task.sleep(nanoseconds: wait * 1_000_000)
                if Task.isCancelled { return .failed(.network) }
                continue
            }
            return result
        }
    }

    static let defaultRetryDelaysMs: [UInt64] = [1_000, 2_000]
    static let defaultTimeoutMs: UInt64 = 20_000
    static let defaultReidentifyIntervalMs: UInt64 = 30_000
}

extension SessionRecovery {
    var logLabel: String {
        switch self {
        case .done: return "done"
        case .notIdentified: return "not_identified"
        case .aborted: return "aborted"
        case .failed(let error): return "failed \(error.logLabel)"
        case .capped: return "capped"
        }
    }
}

extension ChatwootError {
    var isTransient: Bool {
        switch self {
        case .network: return true
        case .http(let code): return code >= 500 || code == 408 || code == 429
        default: return false
        }
    }

    var logLabel: String {
        switch self {
        case .http(let code): return "http \(code)"
        case .network: return "network"
        case .tooLarge: return "tooLarge"
        case .unreadable: return "unreadable"
        case .identityMismatch: return "identityMismatch"
        case .notInitialized: return "notInitialized"
        case .unknown: return "unknown"
        }
    }
}

/// Runs `operation` until it returns or `ms` elapses. On the deadline the operation task is cancelled
/// and the function throws `SendTimeout`.
func withDeadline<T>(ms: UInt64, _ operation: @escaping @Sendable () async -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let once = OnceResume(continuation)
        let work = Task {
            let value = await operation()
            once.success(value)
        }
        Task {
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            if once.failure(SendTimeout()) {
                work.cancel()
            }
        }
    }
}

struct SendTimeout: Error {}

private final class OnceResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func success(_ value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    @discardableResult
    func failure(_ error: Error) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(throwing: error)
        return true
    }
}
