import Foundation

/// Message in Client API responses.
public struct MessageDTO: Codable, Equatable {
    public let id: Int?
    public let content: String?
    public let messageType: Int?
    public let contentType: String?
    public let contentAttributes: [String: JSONValue]?
    public let createdAt: Int?
    public let conversationID: Int?
    public let inboxID: Int?
    public let echoID: String?
    public let attachments: [AttachmentDTO]?
    public let sender: SenderDTO?

    enum CodingKeys: String, CodingKey {
        case id, content, attachments, sender
        case messageType = "message_type"
        case contentType = "content_type"
        case contentAttributes = "content_attributes"
        case createdAt = "created_at"
        case conversationID = "conversation_id"
        case inboxID = "inbox_id"
        case echoID = "echo_id"
    }
}

extension MessageDTO {
    /// The message was written by the contact itself (`message_type == 0` and the
    /// sender is a contact).
    public var isMine: Bool { messageType == 0 && sender?.type == "contact" }

    /// `content_attributes.display_type` of a survey message (`"star"` / `"emoji"`),
    /// `nil` when absent.
    public var surveyDisplay: String? { contentAttributes?["display_type"]?.stringValue }

    /// `content_attributes.submitted_values.csat_survey_response.rating`, `nil`
    /// until the survey is answered.
    public var surveyRating: Int? {
        guard let submitted = contentAttributes?["submitted_values"]?.objectValue,
              let response = submitted["csat_survey_response"]?.objectValue else { return nil }
        return response["rating"]?.intValue.map(Int.init)
    }
}
