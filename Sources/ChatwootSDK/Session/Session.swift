import Foundation

struct Session: Codable, Equatable, Sendable {
    let identifier: String
    let identifierHash: String
    let sourceID: String
    let pubsubToken: String
    let contactID: Int

    enum CodingKeys: String, CodingKey {
        case identifier
        case identifierHash = "identifier_hash"
        case sourceID = "source_id"
        case pubsubToken = "pubsub_token"
        case contactID = "contact_id"
    }
}

extension Session: CustomStringConvertible {
    var description: String { "Session(contactID=\(contactID))" }
}
