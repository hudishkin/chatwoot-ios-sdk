import Foundation

/// Message sender. Contact fields (email, phone, identifier) are personal data:
/// checked against the session but never stored or logged.
public struct SenderDTO: Codable, Equatable {
    public let id: Int?
    public let name: String?
    public let availableName: String?
    public let type: String?
    public let email: String?
    public let phoneNumber: String?
    public let thumbnail: String?
    public let avatarURL: String?
    /// Present only on contact senders (`Contact#push_event_data`).
    public let identifier: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, email, thumbnail, identifier
        case availableName = "available_name"
        case phoneNumber = "phone_number"
        case avatarURL = "avatar_url"
    }
}

extension SenderDTO: CustomStringConvertible {
    public var description: String { "SenderDTO(id=\(id.map(String.init) ?? "nil"), type=\(type ?? "nil"))" }
}
