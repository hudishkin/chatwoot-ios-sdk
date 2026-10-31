import Foundation

/// A file the host hands to the composer. The SDK copies it into the send queue
/// and leaves the original in place.
public struct ChatAttachmentFile: Equatable, Sendable {
    public let url: URL
    /// MIME type. `nil` lets the SDK infer it from the file extension.
    public let mimeType: String?

    public init(url: URL, mimeType: String? = nil) {
        self.url = url
        self.mimeType = mimeType
    }
}

/// Host row in the paperclip menu. Tapping it calls `provide`.
/// A returned file is sent as an attachment; `nil` leaves the composer unchanged.
public struct CustomAttachment: Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name shown next to `title`.
    public let systemImage: String
    public let provide: @Sendable () async -> ChatAttachmentFile?

    public init(
        title: String,
        systemImage: String = "doc",
        id: String? = nil,
        provide: @escaping @Sendable () async -> ChatAttachmentFile?
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = systemImage.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = trimmedTitle
        self.systemImage = symbol.isEmpty ? "doc" : symbol
        self.id = explicitID.isEmpty ? trimmedTitle : explicitID
        self.provide = provide
    }
}

/// One row of the paperclip menu, in the order the host lists them.
public enum ChatAttachmentMenuItem: Sendable {
    /// Photos and videos from the photo library. Shown on iOS 16 and later;
    /// skipped on other systems.
    case photo
    /// System file picker.
    case file
    /// Host action.
    case custom(CustomAttachment)

    /// Photo library, then the system file picker.
    public static let defaultMenu: [ChatAttachmentMenuItem] = [.photo, .file]
}

extension ChatAttachmentMenuItem {
    var menuIdentity: String {
        switch self {
        case .photo: return "photo"
        case .file: return "file"
        case .custom(let action):
            return "custom\u{1f}\(action.id)\u{1f}\(action.title)\u{1f}\(action.systemImage)"
        }
    }

    static func visible(_ items: [ChatAttachmentMenuItem]) -> [ChatAttachmentMenuItem] {
        items.filter { item in
            switch item {
            case .photo:
                #if os(iOS)
                if #available(iOS 16, *) { return true }
                return false
                #else
                return false
                #endif
            case .file:
                return true
            case .custom(let action):
                return !action.title.isEmpty
            }
        }
    }
}
