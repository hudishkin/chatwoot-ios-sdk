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

/// `content_type` of a satisfaction survey (CSAT) message.
public let contentTypeCSAT = "input_csat"
