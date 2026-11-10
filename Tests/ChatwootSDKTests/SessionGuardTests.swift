import Combine
import XCTest
@testable import ChatwootSDK

final class SessionGuardTests: XCTestCase {
    private var sessionGuard: SessionGuard!
    private var reasons: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        sessionGuard = SessionGuard()
        reasons = []
        sessionGuard.reidentifyRequests.sink { [unowned self] reason in
            self.reasons.append(reason)
        }.store(in: &cancellables)
    }

    func test404OnAContactPathRequestsReidentify() {
        sessionGuard.onHttp(code: 404, path: "/public/api/v1/inboxes/inbox/contacts/src/conversations")
        XCTAssertEqual(reasons, ["http_404"])
    }

    func test401OnContactPathsRequestsReidentify() {
        sessionGuard.onHttp(code: 401, path: "/public/api/v1/inboxes/inbox/contacts/src/conversations")
        sessionGuard.onHttp(code: 401, path: "/public/api/v1/inboxes/inbox/contacts/src")
        XCTAssertEqual(reasons, ["http_401", "http_401"])
    }

    func testOtherStatusesAndPathsAreIgnored() {
        sessionGuard.onHttp(code: 500, path: "/public/api/v1/inboxes/inbox/contacts/src")
        sessionGuard.onHttp(code: 404, path: "/public/api/v1/inboxes/inbox/contacts")
        sessionGuard.onHttp(code: 404, path: "/api")
        sessionGuard.onHttp(code: 401, path: "/public/api/v1/inboxes/inbox/messages")
        XCTAssertTrue(reasons.isEmpty)
    }

    func testExplicitRequestPassesTheReasonThrough() {
        sessionGuard.request("contact_identifier_mismatch")
        XCTAssertEqual(reasons, ["contact_identifier_mismatch"])
    }

    func testMissedConfirmsFiresOnceUntilItRearms() {
        for n in [1, 2, 3, 4, 5, 0, 1, 3] {
            sessionGuard.onMissedConfirms(n)
        }
        XCTAssertEqual(reasons, ["missed_confirms", "missed_confirms"])
    }

    func testTerminalDisconnectSanitizesTheReason() {
        sessionGuard.onTerminalDisconnect(reason: "unauthorized")
        sessionGuard.onTerminalDisconnect(reason: "user 42 secret")
        XCTAssertEqual(reasons, ["cable_disconnect_unauthorized", "cable_disconnect_other"])
    }
}
