import Foundation

/// Message attachment (`attachments[]` of a response).
public struct AttachmentDTO: Codable, Equatable, Sendable {
    public let id: Int?
    public let messageID: Int?
    public let fileType: String?
    public let fileExtension: String?
    public let dataURL: String?
    public let thumbURL: String?
    public let fileSize: Int?
    public let width: Int?
    public let height: Int?
    public let fallbackTitle: String?

    enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case fileType = "file_type"
        case fileExtension = "extension"
        case dataURL = "data_url"
        case thumbURL = "thumb_url"
        case fileSize = "file_size"
        case width
        case height
        case fallbackTitle = "fallback_title"
    }
}
