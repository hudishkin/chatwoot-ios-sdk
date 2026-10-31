import Foundation

struct StoredConversation: Equatable {
    let id: Int
    var inboxId: Int
    var status: String
    var contactLastSeenAt: Int
    let agentLastSeenAt: Int
    var lastActivityAt: Int
}

struct StoredMessage: Equatable {
    let id: Int
    var conversationId: Int
    let content: String?
    let type: Int
    let contentType: String
    let createdAt: Int
    let isMine: Bool
    let isDeleted: Bool
    let senderName: String?
    let senderType: String?
    let surveyDisplay: String?
    let surveyRating: Int?
}

struct StoredAttachment: Equatable {
    let id: Int
    let messageId: Int
    let fileType: String?
    let dataUrl: String?
    let thumbUrl: String?
    let fileSize: Int?
    let width: Int?
    let height: Int?
}

struct MessageWithAttachments: Equatable {
    let message: StoredMessage
    let attachments: [StoredAttachment]
    var echoId: String? = nil
}

struct StoredPendingMessage: Equatable {
    enum Kind: String {
        case text = "TEXT"
        case diag = "DIAG"
        case diagDecline = "DIAG_DECLINE"
    }

    enum State: String {
        case queued = "QUEUED"
        case failed = "FAILED"
    }

    let echoId: String
    var conversationId: Int?
    let content: String?
    let attachmentPath: String?
    let attachmentMime: String?
    let kind: Kind
    let state: State
    let createdAt: Int
    let conversationAttributes: String?
    let posted: Bool
}

struct StoredEcho: Equatable {
    let messageId: Int
    let echoId: String
}

struct ConversationBundle {
    let conversation: StoredConversation
    let messages: [StoredMessage]
    let attachments: [StoredAttachment]
}

private let defaultContentType = "text"

extension MessageDTO {
    func toEntities() -> (StoredMessage, [StoredAttachment])? {
        guard let id else { return nil }
        let message = StoredMessage(
            id: id,
            conversationId: conversationID ?? 0,
            content: content,
            type: messageType ?? 0,
            contentType: contentType ?? defaultContentType,
            createdAt: createdAt ?? 0,
            isMine: isMine,
            isDeleted: contentAttributes?["deleted"]?.boolValue == true,
            senderName: sender?.name,
            senderType: sender?.type,
            surveyDisplay: surveyDisplay,
            surveyRating: surveyRating
        )
        return (message, (attachments ?? []).compactMap { $0.toEntity(messageId: id) })
    }
}

extension ConversationDTO {
    func toEntities() -> ConversationBundle? {
        guard let id else { return nil }
        var messages: [StoredMessage] = []
        var attachments: [StoredAttachment] = []
        for dto in self.messages ?? [] {
            guard let (message, messageAttachments) = dto.toEntities() else { continue }
            var stored = message
            stored.conversationId = dto.conversationID ?? id
            messages.append(stored)
            attachments.append(contentsOf: messageAttachments)
        }
        let conversation = StoredConversation(
            id: id,
            inboxId: inboxID ?? 0,
            status: ConversationStatus(apiName: status).rawValue,
            contactLastSeenAt: contactLastSeenAt ?? 0,
            agentLastSeenAt: agentLastSeenAt ?? 0,
            lastActivityAt: messages.map(\.createdAt).max() ?? 0
        )
        return ConversationBundle(conversation: conversation, messages: messages, attachments: attachments)
    }
}

extension AttachmentDTO {
    func toEntity(messageId: Int) -> StoredAttachment? {
        guard let id else { return nil }
        return StoredAttachment(
            id: id,
            messageId: messageId,
            fileType: fileType,
            dataUrl: dataURL,
            thumbUrl: thumbURL,
            fileSize: fileSize,
            width: width,
            height: height
        )
    }
}
