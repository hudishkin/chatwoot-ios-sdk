import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum AppActivity {
    /// `true` while the app is active. Replays the current value on subscribe,
    /// then follows activation and background transitions.
    static func publisher() -> AnyPublisher<Bool, Never> {
        Deferred { changes.prepend(isActive()) }.eraseToAnyPublisher()
    }

    private static var changes: AnyPublisher<Bool, Never> {
        let center = NotificationCenter.default
        #if canImport(UIKit)
        return center.publisher(for: UIApplication.didBecomeActiveNotification).map { _ in true }
            .merge(with: center.publisher(for: UIApplication.didEnterBackgroundNotification).map { _ in false })
            .eraseToAnyPublisher()
        #elseif canImport(AppKit)
        return center.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in true }
            .merge(with: center.publisher(for: NSApplication.didResignActiveNotification).map { _ in false })
            .eraseToAnyPublisher()
        #else
        return Empty().eraseToAnyPublisher()
        #endif
    }

    private static func isActive() -> Bool {
        #if canImport(UIKit)
        if Thread.isMainThread {
            return UIApplication.shared.applicationState == .active
        }
        return DispatchQueue.main.sync { UIApplication.shared.applicationState == .active }
        #elseif canImport(AppKit)
        if Thread.isMainThread {
            return NSApplication.shared.isActive
        }
        return DispatchQueue.main.sync { NSApplication.shared.isActive }
        #else
        return true
        #endif
    }
}

/// Keeps the local inbox fresh so `Chatwoot.unreadCount` moves without a host-driven refresh.
/// The first observed active state only arms the timer: identify has just synced.
/// A later return to the foreground syncs immediately. While active, a timer syncs
/// again whenever realtime is not delivering events.
final class UnreadMaintenance: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private let pollIntervalMs: UInt64
    private let activity: AnyPublisher<Bool, Never>
    private let sync: @Sendable () async -> Void
    private let isRealtimeLive: @Sendable () -> Bool

    init(
        activity: AnyPublisher<Bool, Never>,
        pollIntervalMs: UInt64,
        isRealtimeLive: @escaping @Sendable () -> Bool,
        sync: @escaping @Sendable () async -> Void
    ) {
        self.activity = activity
        self.pollIntervalMs = pollIntervalMs
        self.isRealtimeLive = isRealtimeLive
        self.sync = sync
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        poll?.cancel()
        poll = nil
        lock.unlock()
    }

    private func run() async {
        var primed = false
        for await active in activity.removeDuplicates().eagerValues() {
            if Task.isCancelled { break }
            let returnedToForeground = active && primed
            primed = true
            setPoll(nil)
            guard active else { continue }
            if returnedToForeground {
                await sync()
            }
            armPoll()
        }
    }

    private func armPoll() {
        let interval = pollIntervalMs
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                if !self.isRealtimeLive() {
                    await self.sync()
                }
            }
        }
        setPoll(poll)
    }

    private func setPoll(_ next: Task<Void, Never>?) {
        lock.lock()
        if next != nil, task == nil {
            lock.unlock()
            next?.cancel()
            return
        }
        poll?.cancel()
        poll = next
        lock.unlock()
    }
}
