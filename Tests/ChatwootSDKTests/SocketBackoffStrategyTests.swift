import XCTest
@testable import ChatwootSDK

final class SocketBackoffStrategyTests: XCTestCase {
    func testExponentialGrowthAndCap() {
        var backoff = SocketBackoffStrategy(random: { 1.0 })
        XCTAssertEqual(backoff.nextDelayMs(attempt: 0), 1_000)
        XCTAssertEqual(backoff.nextDelayMs(attempt: 1), 2_000)
        XCTAssertEqual(backoff.nextDelayMs(attempt: 2), 4_000)
        XCTAssertEqual(backoff.nextDelayMs(attempt: 5), 30_000, "кап 30 с")
        XCTAssertEqual(backoff.nextDelayMs(attempt: 10), 30_000)
        XCTAssertEqual(backoff.nextDelayMs(attempt: 100), 30_000, "сдвиг ограничен, переполнения нет")
    }

    func testJitterBounds() {
        var backoff = SocketBackoffStrategy(random: { 0.5 })
        XCTAssertEqual(backoff.nextDelayMs(attempt: 0), 500, "джиттер 0.5–1.0")
    }

    func testStableConnectionResetsCounter() {
        var backoff = SocketBackoffStrategy(random: { 1.0 })
        backoff.onConnectionOpened(atMs: 1_000)
        XCTAssertTrue(backoff.onConnectionClosed(atMs: 1_000 + SocketBackoffStrategy.stabilityWindowMs))
        XCTAssertEqual(backoff.nextDelayMs(attempt: 0), 1_000, "после стабильной сессии — с первого шага")
    }

    func testUnstableConnectionKeepsCounter() {
        var backoff = SocketBackoffStrategy(random: { 1.0 })
        backoff.onConnectionOpened(atMs: 1_000)
        XCTAssertFalse(backoff.onConnectionClosed(atMs: 5_000))
    }

    func testCloseWithoutOpenIsNotStable() {
        var backoff = SocketBackoffStrategy(random: { 1.0 })
        XCTAssertFalse(backoff.onConnectionClosed(atMs: 100_000))
    }

    func testTimestampConsumedOnClose() {
        var backoff = SocketBackoffStrategy(random: { 1.0 })
        backoff.onConnectionOpened(atMs: 1_000)
        XCTAssertTrue(backoff.onConnectionClosed(atMs: 40_000))
        XCTAssertFalse(backoff.onConnectionClosed(atMs: 80_000), "второе закрытие без открытия — нестабильно")
    }
}
