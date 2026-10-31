import Foundation

struct SocketBackoffStrategy {
    static let baseMs: UInt64 = 1_000
    static let capMs: UInt64 = 30_000
    static let stabilityWindowMs: UInt64 = 30_000
    private static let maxShift = 16

    private let random: () -> Double

    private var openedAtMs: UInt64?

    init(random: @escaping () -> Double = { 0.5 + Double.random(in: 0..<0.5) }) {
        self.random = random
    }

    mutating func nextDelayMs(attempt: Int) -> UInt64 {
        let shift = min(max(attempt, 0), Self.maxShift)
        let exponential = Double(Self.baseMs) * pow(2.0, Double(shift))
        let capped = min(exponential, Double(Self.capMs))
        return UInt64(capped * random())
    }

    mutating func onConnectionOpened(atMs: UInt64) {
        openedAtMs = atMs
    }

    mutating func onConnectionClosed(atMs: UInt64) -> Bool {
        guard let opened = openedAtMs else { return false }
        let stable = atMs >= opened && atMs - opened >= Self.stabilityWindowMs
        openedAtMs = nil
        return stable
    }
}
