import Combine
import XCTest
@testable import ChatwootSDK

final class UnreadMaintenanceTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private func sleepMs(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await sleepMs(10)
        }
        XCTAssertTrue(condition(), "условие не наступило за 2с", file: file, line: line)
    }

    func testFirstActiveSnapshotDoesNotSync() async {
        let syncs = Counter()
        let maintenance = UnreadMaintenance(
            activity: Just(true).eraseToAnyPublisher(),
            pollIntervalMs: 5_000,
            isRealtimeLive: { false },
            sync: { syncs.increment() }
        )
        maintenance.start()
        await sleepMs(80)
        XCTAssertEqual(syncs.value, 0, "первый активный снимок не дублирует синк identify")
        maintenance.stop()
    }

    func testReturnToForegroundSyncsOnceBeforeTheTimer() async {
        let activity = CurrentValueSubject<Bool, Never>(false)
        let syncs = Counter()
        let maintenance = UnreadMaintenance(
            activity: activity.eraseToAnyPublisher(),
            pollIntervalMs: 5_000,
            isRealtimeLive: { false },
            sync: { syncs.increment() }
        )
        maintenance.start()
        await sleepMs(50)
        activity.send(true)
        await eventually { syncs.value == 1 }
        await sleepMs(80)
        XCTAssertEqual(syncs.value, 1, "таймер ещё не должен сработать")
        maintenance.stop()
    }

    func testTimerSyncsWhileRealtimeIsDown() async {
        let syncs = Counter()
        let maintenance = UnreadMaintenance(
            activity: Just(true).eraseToAnyPublisher(),
            pollIntervalMs: 30,
            isRealtimeLive: { false },
            sync: { syncs.increment() }
        )
        maintenance.start()
        await eventually { syncs.value >= 1 }
        maintenance.stop()
    }

    func testTimerStaysQuietWhileRealtimeIsLive() async {
        let syncs = Counter()
        let maintenance = UnreadMaintenance(
            activity: Just(true).eraseToAnyPublisher(),
            pollIntervalMs: 30,
            isRealtimeLive: { true },
            sync: { syncs.increment() }
        )
        maintenance.start()
        await sleepMs(120)
        XCTAssertEqual(syncs.value, 0, "живой сокет сам двигает счётчик")
        maintenance.stop()
    }
}
