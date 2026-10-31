import Combine
import Foundation

final class InFlightTracker: @unchecked Sendable {
    let sending = CurrentValueSubject<Set<String>, Never>([])

    private let lock = NSLock()
    private var set: Set<String> = []

    func markSending(_ echoId: String) {
        update { $0.insert(echoId) }
    }

    func markDelivered(_ echoId: String) {
        update { $0.remove(echoId) }
    }

    func markBroken(_ echoId: String) {
        update { $0.remove(echoId) }
    }

    func isSending(_ echoId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return set.contains(echoId)
    }

    func clear() {
        update { $0.removeAll() }
    }

    private func update(_ mutate: (inout Set<String>) -> Void) {
        lock.lock()
        mutate(&set)
        let snapshot = set
        lock.unlock()
        sending.send(snapshot)
    }
}
