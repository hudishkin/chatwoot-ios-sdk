import Foundation

/// Contact in Client API responses.
public struct ContactDTO: Codable, Equatable {
    public let id: Int?
    public let name: String?
    public let email: String?
    public let phoneNumber: String?
    public let identifier: String?
    public let customAttributes: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, name, email, identifier
        case phoneNumber = "phone_number"
        case customAttributes = "custom_attributes"
    }
}
