import XCTest
@testable import ChatwootSDK

final class SessionRecovererTests: XCTestCase {
    func testRecoverSharesOneIdentifyAcrossQueuedSends() async {
        let gate = IdentifyGate()
        let recoverer = SessionRecoverer(
            identifyOnce: {
                await gate.hit()
                return .done
            },
            retryDelaysMs: [],
            timeoutMs: 5_000
        )
        let ticket = await recoverer.ticket()
        async let first = recoverer.recover(since: ticket)
        async let second = recoverer.recover(since: ticket)
        let results = await [first, second]
        XCTAssertEqual(results, [.done, .done])
        let hits = await gate.count
        XCTAssertEqual(hits, 1)

        let shared = await recoverer.recover(since: ticket)
        XCTAssertEqual(shared, .done)
        let hitsAfter = await gate.count
        XCTAssertEqual(hitsAfter, 1, "отправка, вставшая в очередь до конца identify, не запускает вторую")
    }

    func testReidentifyIsCapped() async {
        var now: UInt64 = 1_000
        let recoverer = SessionRecoverer(
            identifyOnce: { .notIdentified },
            reidentifyOnce: { _ in .done },
            retryDelaysMs: [],
            timeoutMs: 5_000,
            reidentifyIntervalMs: 30_000,
            now: { now }
        )
        let stale = Session(identifier: "u", identifierHash: "h", sourceID: "s", pubsubToken: "p", contactID: 1)
        let firstTicket = await recoverer.ticket()
        let first = await recoverer.reidentify(stale: stale, since: firstTicket)
        XCTAssertEqual(first, .done)

        now += 1_000
        let secondTicket = await recoverer.ticket()
        let second = await recoverer.reidentify(stale: stale, since: secondTicket)
        XCTAssertEqual(second, .capped)
    }
}

private actor IdentifyGate {
    private(set) var count = 0

    func hit() {
        count += 1
    }
}
