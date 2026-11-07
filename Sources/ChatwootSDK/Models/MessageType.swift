import Foundation

/// `message_type` of a Chatwoot message.
public enum MessageType: Int, Codable, Sendable {
    /// Incoming: written by the contact (`message_type == 0`).
    case incoming = 0
    /// Outgoing: written by an agent or a bot.
    case outgoing = 1
    /// System activity row ("conversation resolved" and the like).
    case activity = 2
    case template = 3

    /// An unknown code falls back to `activity`.
    public init(code: Int?) {
        self = code.flatMap(MessageType.init(rawValue:)) ?? .activity
    }
}

/// Plain-text template: an automatic reply (out-of-office, greeting), not a system line.
let contentTypeText = "text"

extension StoredMessage {
    var isAutoReply: Bool {
        type == MessageType.template.rawValue && contentType == contentTypeText
    }
}

/// Agent replies, automatic replies, and unanswered surveys. Used in unread queries over alias `m`.
let unreadKindSQL = "(m.type = 1 OR (m.type = 3 AND m.contentType = 'text') OR (m.type = 3 AND m.contentType = 'input_csat' AND m.surveyRating IS NULL))"

/// `content_type` of a satisfaction survey (CSAT) message.
public let contentTypeCSAT = "input_csat"
