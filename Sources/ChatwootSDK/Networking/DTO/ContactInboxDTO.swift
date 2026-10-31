import Foundation

/// Response of `POST`/`GET contacts`: contact-inbox with `source_id` and `pubsub_token`.
/// `sourceID` and `pubsubToken` are session secrets: never logged.
public struct ContactInboxDTO: Codable, Equatable {
    public let sourceID: String?
    public let pubsubToken: String?
    public let id: Int?
    public let name: String?
    public let email: String?
    public let phoneNumber: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case sourceID = "source_id"
        case pubsubToken = "pubsub_token"
        case phoneNumber = "phone_number"
    }
}
