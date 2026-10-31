import Foundation

/// When the SDK keeps the realtime socket (`/cable`) open for the identified user.
/// In both modes `update_presence` (contact shown "online" to agents) is sent only
/// while the chat screen is visible.
public enum ChatwootRealtime: Sendable {
    /// While the app is in the foreground: new agent replies and the unread count
    /// arrive instantly anywhere in the app. The default.
    case whileForeground
    /// Only while the chat screen is open. Elsewhere the unread count is updated
    /// by a REST sync when the app returns to the foreground and by `refresh()`.
    case whileChatOpen
}

/// SDK configuration passed to `Chatwoot.initialize`. Validated on creation.
public struct ChatwootConfig {
    /// Server root over https, without a path, e.g. `https://chat.example.com`.
    public let baseURL: URL
    /// API inbox identifier (a path segment of the Client API). Never logged.
    public let inboxIdentifier: String
    /// Numeric id of the same inbox: the Client API never returns it, so foreign
    /// inboxes' conversations are discarded by it.
    public let inboxID: Int
    /// When to keep the realtime socket open; `.whileForeground` by default.
    public let realtime: ChatwootRealtime
    /// Host keys whose values are personal data and are masked in every SDK log
    /// line (like the built-in `account=…`). Letters, digits and `_`, 1–64 chars.
    public let redactedKeys: Set<String>
    /// Sink for redacted SDK log lines of level `info` and above.
    public let logSink: LogSink?
    /// Additionally print SDK logs, including `debug`, to the console.
    public let debugConsoleLogging: Bool

    public enum ValidationError: Error, Equatable {
        /// `baseURL` is not an https server root without path, query and fragment.
        case invalidBaseURL
        case blankInboxIdentifier
        case invalidInboxID
        case invalidRedactedKey
    }

    public init(
        baseURL: String,
        inboxIdentifier: String,
        inboxID: Int,
        realtime: ChatwootRealtime = .whileForeground,
        redactedKeys: Set<String> = [],
        logSink: LogSink? = nil,
        debugConsoleLogging: Bool = false
    ) throws {
        guard let url = URL(string: baseURL),
              url.scheme == "https",
              url.host != nil,
              url.path.isEmpty || url.path == "/",
              url.query == nil,
              url.fragment == nil,
              url.user == nil,
              url.password == nil else {
            throw ValidationError.invalidBaseURL
        }
        guard !inboxIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.blankInboxIdentifier
        }
        guard inboxID > 0 else { throw ValidationError.invalidInboxID }
        let keyPattern = #"^[A-Za-z0-9_]{1,64}$"#
        guard redactedKeys.allSatisfy({ $0.range(of: keyPattern, options: .regularExpression) != nil }) else {
            throw ValidationError.invalidRedactedKey
        }
        self.baseURL = url
        self.inboxIdentifier = inboxIdentifier
        self.inboxID = inboxID
        self.realtime = realtime
        self.redactedKeys = redactedKeys
        self.logSink = logSink
        self.debugConsoleLogging = debugConsoleLogging
    }
}

extension ChatwootConfig: CustomStringConvertible {
    /// Server URL, inbox identifier and redacted keys are omitted: they identify
    /// the host's deployment.
    public var description: String {
        "ChatwootConfig(inboxID=\(inboxID), realtime=\(realtime), debugConsoleLogging=\(debugConsoleLogging))"
    }
}
