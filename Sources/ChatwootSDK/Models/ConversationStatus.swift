import Foundation

/// Status of a Chatwoot conversation.
public enum ConversationStatus: String, Codable, Sendable {
    case open
    case resolved
    case pending
    case snoozed

    /// An unknown status falls back to `open`.
    public init(apiName: String?) {
        self = ConversationStatus(rawValue: apiName ?? "") ?? .open
    }
}
