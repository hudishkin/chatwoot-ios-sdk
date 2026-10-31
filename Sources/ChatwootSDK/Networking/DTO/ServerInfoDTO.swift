import Foundation

/// Response of `GET /api`: Chatwoot server version.
public struct ServerInfoDTO: Codable, Equatable, Sendable {
    public let version: String?
    public let timestamp: String?
    public let queueServices: String?
    public let dataServices: String?

    enum CodingKeys: String, CodingKey {
        case version, timestamp
        case queueServices = "queue_services"
        case dataServices = "data_services"
    }
}
