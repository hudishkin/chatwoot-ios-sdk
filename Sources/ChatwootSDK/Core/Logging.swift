import Foundation

/// Level of an SDK log message.
public enum LogLevel: Int, Comparable, Sendable {
    case verbose = 0
    case debug
    case info
    case warning
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An error as the SDK passes it to `LogSink`: `type` is the class name,
/// `message` is already redacted (`nil` if the original could contain user data).
public struct SanitizedError: Equatable, Sendable {
    public let type: String
    public let message: String?

    public init(type: String, message: String?) {
        self.type = type
        self.message = message
    }
}

/// Sink for redacted SDK log lines of level `info` and above.
public protocol LogSink {
    func log(level: LogLevel, domain: String, line: String, error: SanitizedError?)
}
