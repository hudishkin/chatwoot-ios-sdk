import XCTest
@testable import ChatwootSDK

final class StaleSessionVerifierTests: XCTestCase {
    private var api: MockChatwootAPI!
    private var clock: UInt64 = 0
    private var verifier: StaleSessionVerifier!

    override func setUp() {
        super.setUp()
        api = MockChatwootAPI()
        clock = 1_000_000
        verifier = StaleSessionVerifier(
            api: api,
            inboxIdentifier: "inbox-1",
            now: { [unowned self] in self.clock },
            minIntervalMs: 600,
            maxIntervalMs: 2_400
        )
    }

    private func verify() async -> StaleSessionVerifier.Verdict {
        await verifier.verify(session: Fixtures.session)
    }

    func testVerifyMapsHttp404ToStale() async {
        api.contactStub = .failure(ChatwootError.http(code: 404))
        let verdict = await verify()
        guard case .stale = verdict else { return XCTFail("404 → stale, got \(verdict)") }
        XCTAssertEqual(api.contactChecks, ["src-1"])
        XCTAssertEqual(api.contactQueries.first?.identifier, "user-42")
        XCTAssertEqual(api.contactQueries.first?.identifierHash, "hash-42")
    }

    func testVerifyMapsHttp401ToStale() async {
        api.contactStub = .failure(ChatwootError.http(code: 401))
        let verdict = await verify()
        guard case .stale = verdict else { return XCTFail("401 → stale, got \(verdict)") }
    }

    func testVerifyMapsHttp500ToUnknown() async {
        api.contactStub = .failure(ChatwootError.http(code: 500))
        let verdict = await verify()
        guard case .unknown = verdict else { return XCTFail("500 → unknown, got \(verdict)") }
    }

    func testVerifyMapsNetworkToUnknown() async {
        api.contactStub = .failure(ChatwootError.network)
        let verdict = await verify()
        guard case .unknown = verdict else { return XCTFail("network → unknown, got \(verdict)") }
    }

    func testVerifyMapsSuccessToHealthy() async {
        api.contactStub = .success(Fixtures.contactInbox())
        let verdict = await verify()
        guard case .healthy = verdict else { return XCTFail("2xx → healthy, got \(verdict)") }
    }

    func testTryAcquireCapsRepeats() {
        XCTAssertTrue(verifier.tryAcquire())
        XCTAssertFalse(verifier.tryAcquire())
        clock += 600
        XCTAssertTrue(verifier.tryAcquire())
        clock += 600
        XCTAssertFalse(verifier.tryAcquire())
        clock += 600
        XCTAssertTrue(verifier.tryAcquire())
    }

    func testTryAcquireIntervalCapsAtMax() {
        XCTAssertTrue(verifier.tryAcquire())
        for _ in 0..<10 {
            clock += 100_000
            XCTAssertTrue(verifier.tryAcquire())
        }
        clock += 2_400
        XCTAssertTrue(verifier.tryAcquire())
    }

    func testHealthyVerdictResetsInterval() async {
        XCTAssertTrue(verifier.tryAcquire())
        clock += 600
        XCTAssertTrue(verifier.tryAcquire())
        api.contactStub = .success(Fixtures.contactInbox())
        _ = await verify()
        clock += 600
        XCTAssertTrue(verifier.tryAcquire())
    }
}
