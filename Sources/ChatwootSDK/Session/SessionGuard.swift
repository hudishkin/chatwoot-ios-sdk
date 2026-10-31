import Combine
import Foundation

final class SessionGuard: @unchecked Sendable {
    let reidentifyRequests = PassthroughSubject<String, Never>()

    private let lock = NSLock()
    private var missedConfirmsArmed = true

    func onHttp(code: Int, path: String) {
        let isContactPath = path.contains(Self.contactsSegment)
        if isContactPath && code == 404 {
            request("http_404")
        } else if isContactPath && code == 401 {
            request("http_401")
        }
    }

    func onMissedConfirms(_ n: Int) {
        lock.lock()
        if n < Self.missedConfirmsLimit {
            missedConfirmsArmed = true
            lock.unlock()
        } else if missedConfirmsArmed {
            missedConfirmsArmed = false
            lock.unlock()
            request("missed_confirms")
        } else {
            lock.unlock()
        }
    }

    func onTerminalDisconnect(reason: String) {
        request("cable_disconnect_\(DisconnectReason.sanitize(reason))")
    }

    func request(_ reason: String) {
        CWLog.w(.auth, "stale session suspected: \(reason)")
        reidentifyRequests.send(reason)
    }

    private static let missedConfirmsLimit = 3
    private static let contactsSegment = "/contacts/"
}
