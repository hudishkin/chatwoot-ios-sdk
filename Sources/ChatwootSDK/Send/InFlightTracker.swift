import Combine
import Foundation

/// Why the last attempt of a send failed in this process. The chat words the failed row from it.
enum SendFailure: Equatable {
    /// No answer from the server, or no network.
    case network
    /// The attempt ran past the send deadline.
    case timeout
    /// No session could be restored: identify or the forced reidentify failed, or nobody was identified.
    case session
    /// Anything else: an HTTP error, an unreadable file, an unexpected failure.
    case other
}

final class InFlightTracker: @unchecked Sendable {
    let sending = CurrentValueSubject<Set<String>, Never>([])
    let failures = CurrentValueSubject<[String: SendFailure], Never>([:])

    private let lock = NSLock()
    private var set: Set<String> = []
    private var reasons: [String: SendFailure] = [:]

    func markSending(_ echoId: String) {
        let snapshots = locked {
            set.insert(echoId)
            reasons.removeValue(forKey: echoId)
            return (set, reasons)
        }
        sending.send(snapshots.0)
        failures.send(snapshots.1)
    }

    func markDelivered(_ echoId: String) {
        let snapshots = locked {
            set.remove(echoId)
            reasons.removeValue(forKey: echoId)
            return (set, reasons)
        }
        sending.send(snapshots.0)
        failures.send(snapshots.1)
    }

    func recordFailure(_ echoId: String, _ reason: SendFailure) {
        let snapshot = locked { () -> [String: SendFailure] in
            reasons[echoId] = reason
            return reasons
        }
        failures.send(snapshot)
    }

    func markBroken(_ echoId: String) {
        update { $0.remove(echoId) }
    }

    func clearFailures() {
        lock.lock()
        reasons.removeAll()
        lock.unlock()
        failures.send([:])
    }

    func isSending(_ echoId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return set.contains(echoId)
    }

    func clear() {
        lock.lock()
        set.removeAll()
        reasons.removeAll()
        let sendingSnapshot = set
        lock.unlock()
        sending.send(sendingSnapshot)
        failures.send([:])
    }

    private func update(_ mutate: (inout Set<String>) -> Void) {
        let snapshot = locked { () -> Set<String> in
            mutate(&set)
            return set
        }
        sending.send(snapshot)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
