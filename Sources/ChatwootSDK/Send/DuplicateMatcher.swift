import Foundation

enum DuplicateMatcher {
    static let beforeSeconds = 30
    static let afterSeconds = 300

    static func find(pending: StoredPendingMessage, messages: [StoredMessage]) -> StoredMessage? {
        guard let content = pending.content, !content.isEmpty else { return nil }
        return messages.first { $0.isMine && $0.content == content && inWindow(pending: pending, message: $0) }
    }

    static func findWithAttachments(pending: StoredPendingMessage, messages: [MessageWithAttachments], fileSize: Int?) -> StoredMessage? {
        let captionedFile = !(pending.content?.isEmpty ?? true) && pending.attachmentPath != nil && pending.kind == .text
        if !(pending.content?.isEmpty ?? true), !captionedFile {
            return find(pending: pending, messages: messages.map(\.message))
        }
        guard pending.attachmentPath != nil, let fileSize else { return nil }
        let type = coarseType(pending.attachmentMime)
        let candidates = messages.filter { candidate in
            candidate.message.isMine
                && (captionedFile ? candidate.message.content == pending.content : (candidate.message.content?.isEmpty ?? true))
                && inWindow(pending: pending, message: candidate.message)
                && candidate.attachments.count == 1
                && candidate.attachments[0].fileType == type
                && candidate.attachments[0].fileSize == fileSize
        }
        return candidates.count == 1 ? candidates[0].message : nil
    }

    private static func inWindow(pending: StoredPendingMessage, message: StoredMessage) -> Bool {
        let delta = message.createdAt - pending.createdAt
        return delta >= -beforeSeconds && delta <= afterSeconds
    }

    private static func coarseType(_ mime: String?) -> String {
        let top = mime?.split(separator: "/").first?.lowercased()
        return (top == "image" || top == "audio" || top == "video") ? top! : "file"
    }
}
