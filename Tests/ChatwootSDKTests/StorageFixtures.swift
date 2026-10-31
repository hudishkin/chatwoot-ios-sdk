import Foundation
@testable import ChatwootSDK

enum StorageFixtures {
    static func conversation(
        _ id: Int,
        inboxId: Int = 1,
        status: String = "open",
        contactLastSeenAt: Int = 0,
        agentLastSeenAt: Int = 0,
        lastActivityAt: Int = 0
    ) -> StoredConversation {
        StoredConversation(
            id: id, inboxId: inboxId, status: status,
            contactLastSeenAt: contactLastSeenAt, agentLastSeenAt: agentLastSeenAt,
            lastActivityAt: lastActivityAt
        )
    }

    static func message(
        _ id: Int,
        conversationId: Int,
        content: String? = nil,
        type: Int = 0,
        contentType: String = "text",
        createdAt: Int,
        isMine: Bool = false,
        isDeleted: Bool = false,
        senderName: String? = nil,
        senderType: String? = nil,
        surveyDisplay: String? = nil,
        surveyRating: Int? = nil
    ) -> StoredMessage {
        StoredMessage(
            id: id, conversationId: conversationId, content: content, type: type,
            contentType: contentType, createdAt: createdAt, isMine: isMine, isDeleted: isDeleted,
            senderName: senderName, senderType: senderType,
            surveyDisplay: surveyDisplay, surveyRating: surveyRating
        )
    }

    static func attachment(
        _ id: Int,
        messageId: Int,
        fileType: String? = "image",
        fileSize: Int? = 100
    ) -> StoredAttachment {
        StoredAttachment(
            id: id, messageId: messageId, fileType: fileType, dataUrl: "https://x/\(id)",
            thumbUrl: nil, fileSize: fileSize, width: nil, height: nil
        )
    }

    static func pending(
        _ echoId: String,
        conversationId: Int? = nil,
        content: String? = "текст",
        attachmentPath: String? = nil,
        kind: StoredPendingMessage.Kind = .text,
        state: StoredPendingMessage.State = .queued,
        createdAt: Int = 100,
        posted: Bool = false
    ) -> StoredPendingMessage {
        StoredPendingMessage(
            echoId: echoId, conversationId: conversationId, content: content,
            attachmentPath: attachmentPath, attachmentMime: nil, kind: kind, state: state,
            createdAt: createdAt, conversationAttributes: nil, posted: posted
        )
    }
}
