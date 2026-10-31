import Foundation

/// Conversation in Client API responses.
public struct ConversationDTO: Codable, Equatable {
    public let id: Int?
    public let uuid: String?
    public let inboxID: Int?
    public let status: String?
    public let contactLastSeenAt: Int?
    public let agentLastSeenAt: Int?
    public let messages: [MessageDTO]?
    public let contact: ContactDTO?

    enum CodingKeys: String, CodingKey {
        case id, uuid, status, messages, contact
        case inboxID = "inbox_id"
        case contactLastSeenAt = "contact_last_seen_at"
        case agentLastSeenAt = "agent_last_seen_at"
    }
}
