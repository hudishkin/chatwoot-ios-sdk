import Combine
import Foundation
import Network

final class NetworkAvailabilityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "chatwoot.network.availability")
    private let lock = NSLock()
    private nonisolated(unsafe) var handler: (() -> Void)?

    let transportAvailable = CurrentValueSubject<Bool, Never>(true)

    func start(onAvailable: @escaping () -> Void) {
        lock.lock()
        handler = onAvailable
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.transportAvailable.send(path.status == .satisfied)
            guard path.status == .satisfied else { return }
            self?.lock.lock()
            let handler = self?.handler
            self?.lock.unlock()
            handler?()
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    deinit {
        monitor.cancel()
    }
}
