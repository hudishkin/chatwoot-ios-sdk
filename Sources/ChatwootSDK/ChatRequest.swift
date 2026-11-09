import Foundation
import UniformTypeIdentifiers

/// Chat screen request: prefilled text, title, conversation attributes, the
/// paperclip menu, and how the system pickers export a gallery item or a file.
/// Everything is optional; `ChatRequest()` is a plain chat.
public struct ChatRequest: Equatable, Sendable {
    /// Text prefilled into the composer.
    public let initialMessage: String?
    /// Screen title; `nil` falls back to the default title.
    public let title: String?
    /// Sent as `custom_attributes`, but only if the send has to create a conversation.
    public let conversationAttributes: [String: JSONValue]
    /// Rows of the paperclip menu, in this order. An empty list hides the paperclip.
    /// The default is the camera, the photo library, then the system file picker.
    public let attachmentMenu: [ChatAttachmentMenuItem]
    /// Passed to the photo library picker as `preferredAssetRepresentationMode`.
    /// Applies to a picked photo and a picked video. `.current` by default.
    public let galleryRepresentation: GalleryRepresentation
    /// Passed to the system file picker as `forOpeningContentTypes`.
    /// An empty list is treated as every file (`UTType.item`).
    public let fileContentTypes: [UTType]

    public init(
        initialMessage: String? = nil,
        title: String? = nil,
        conversationAttributes: [String: JSONValue] = [:],
        attachmentMenu: [ChatAttachmentMenuItem] = ChatAttachmentMenuItem.defaultMenu,
        galleryRepresentation: GalleryRepresentation = .current,
        fileContentTypes: [UTType] = [.item]
    ) {
        self.initialMessage = initialMessage
        self.title = title
        self.conversationAttributes = conversationAttributes
        self.attachmentMenu = attachmentMenu
        self.galleryRepresentation = galleryRepresentation
        self.fileContentTypes = fileContentTypes.isEmpty ? [.item] : fileContentTypes
    }

    /// Plain chat: no prefilled text, default title, no attributes, default paperclip.
    public static let `default` = ChatRequest()

    /// Compares custom rows by id, title and icon. The `provide` closure is not part
    /// of equality.
    public static func == (lhs: ChatRequest, rhs: ChatRequest) -> Bool {
        lhs.initialMessage == rhs.initialMessage
            && lhs.title == rhs.title
            && lhs.conversationAttributes == rhs.conversationAttributes
            && lhs.attachmentMenu.map(\.menuIdentity) == rhs.attachmentMenu.map(\.menuIdentity)
            && lhs.galleryRepresentation == rhs.galleryRepresentation
            && lhs.fileContentTypes == rhs.fileContentTypes
    }
}
