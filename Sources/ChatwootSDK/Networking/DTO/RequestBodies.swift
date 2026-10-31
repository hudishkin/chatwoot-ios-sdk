import Foundation

/// Body of `POST contacts`.
public struct ContactCreateBody: Codable, Equatable {
    public let identifier: String
    public let identifierHash: String?
    public let name: String?
    public let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case identifier, name
        case identifierHash = "identifier_hash"
        case avatarURL = "avatar_url"
    }

    public init(identifier: String, identifierHash: String? = nil, name: String? = nil, avatarURL: String? = nil) {
        self.identifier = identifier
        self.identifierHash = identifierHash
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// Body of `PATCH contacts/{sourceID}`: `nil` fields are omitted from the request
/// (the server keeps what it has).
public struct ContactUpdateBody: Codable, Equatable {
    public let identifier: String
    public let identifierHash: String?
    public let name: String?
    public let avatarURL: String?
    public let customAttributes: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case identifier, name
        case identifierHash = "identifier_hash"
        case avatarURL = "avatar_url"
        case customAttributes = "custom_attributes"
    }

    public init(
        identifier: String,
        identifierHash: String? = nil,
        name: String? = nil,
        avatarURL: String? = nil,
        customAttributes: [String: JSONValue]? = nil
    ) {
        self.identifier = identifier
        self.identifierHash = identifierHash
        self.name = name
        self.avatarURL = avatarURL
        self.customAttributes = customAttributes
    }
}

/// Body of `POST conversations`.
public struct ConversationCreateBody: Codable, Equatable {
    public let customAttributes: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case customAttributes = "custom_attributes"
    }

    public init(customAttributes: [String: JSONValue]? = nil) {
        self.customAttributes = customAttributes
    }
}

/// Body of `POST messages` (text message).
public struct MessageCreateBody: Codable, Equatable {
    public let content: String
    public let echoID: String

    enum CodingKeys: String, CodingKey {
        case content
        case echoID = "echo_id"
    }

    public init(content: String, echoID: String) {
        self.content = content
        self.echoID = echoID
    }
}

/// Body of `PATCH messages/{id}`: the contact's answer to an interactive message
/// (CSAT survey).
public struct UpdateMessageBody: Codable, Equatable {
    public let submittedValues: SubmittedValuesDTO

    enum CodingKeys: String, CodingKey {
        case submittedValues = "submitted_values"
    }

    /// Answer to a satisfaction survey; a `nil` feedback omits `feedback_message`
    /// from the request.
    public static func csat(rating: Int, feedback: String?) -> UpdateMessageBody {
        UpdateMessageBody(submittedValues: SubmittedValuesDTO(csatSurveyResponse: CSATSurveyResponseDTO(rating: rating, feedbackMessage: feedback)))
    }
}

public struct SubmittedValuesDTO: Codable, Equatable {
    public let csatSurveyResponse: CSATSurveyResponseDTO?

    enum CodingKeys: String, CodingKey {
        case csatSurveyResponse = "csat_survey_response"
    }
}

/// `feedbackMessage` is the contact's free text: never logged, hidden from `description`.
public struct CSATSurveyResponseDTO: Codable, Equatable {
    public let rating: Int?
    public let feedbackMessage: String?

    enum CodingKeys: String, CodingKey {
        case rating
        case feedbackMessage = "feedback_message"
    }
}

extension CSATSurveyResponseDTO: CustomStringConvertible {
    public var description: String {
        "CSATSurveyResponseDTO(rating=\(rating.map(String.init) ?? "nil"), feedbackMessage=\(feedbackMessage == nil ? "nil" : "***"))"
    }
}
