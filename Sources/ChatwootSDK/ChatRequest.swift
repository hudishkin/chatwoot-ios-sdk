import Foundation

/// Chat screen request: prefilled text, title and conversation attributes.
/// Everything is optional; `ChatRequest()` is a plain chat.
public struct ChatRequest: Equatable, Sendable {
    /// Text prefilled into the composer.
    public let initialMessage: String?
    /// Screen title; `nil` falls back to the default title.
    public let title: String?
    /// Sent as `custom_attributes`, but only if the send has to create a conversation.
    public let conversationAttributes: [String: JSONValue]

    public init(
        initialMessage: String? = nil,
        title: String? = nil,
        conversationAttributes: [String: JSONValue] = [:]
    ) {
        self.initialMessage = initialMessage
        self.title = title
        self.conversationAttributes = conversationAttributes
    }

    /// Plain chat: no prefilled text, default title, no attributes.
    public static let `default` = ChatRequest()
}
