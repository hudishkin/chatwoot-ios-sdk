import Foundation
@testable import ChatwootSDK

let feedNoon = 1_792_756_800
let feedConversation = 7

func feedAgent(
    _ id: Int,
    at: Int? = nil,
    text: String? = "reply",
    name: String = "Agent",
    senderType: String = "user",
    deleted: Bool = false,
    attachments: [StoredAttachment] = []
) -> MessageWithAttachments {
    MessageWithAttachments(
        message: StoredMessage(
            id: id, conversationId: feedConversation, content: text, type: 1,
            contentType: "text", createdAt: at ?? feedNoon + id, isMine: false,
            isDeleted: deleted, senderName: name, senderType: senderType,
            surveyDisplay: nil, surveyRating: nil
        ),
        attachments: attachments
    )
}

func feedMine(
    _ id: Int,
    at: Int? = nil,
    text: String? = "question",
    deleted: Bool = false,
    attachments: [StoredAttachment] = []
) -> MessageWithAttachments {
    MessageWithAttachments(
        message: StoredMessage(
            id: id, conversationId: feedConversation, content: text, type: 0,
            contentType: "text", createdAt: at ?? feedNoon + id, isMine: true,
            isDeleted: deleted, senderName: nil, senderType: "contact",
            surveyDisplay: nil, surveyRating: nil
        ),
        attachments: attachments
    )
}

func feedTemplate(
    _ id: Int,
    at: Int? = nil,
    text: String? = "We reply within a day"
) -> MessageWithAttachments {
    MessageWithAttachments(
        message: StoredMessage(
            id: id, conversationId: feedConversation, content: text, type: 3,
            contentType: "text", createdAt: at ?? feedNoon + id, isMine: false,
            isDeleted: false, senderName: "Bot", senderType: "agent_bot",
            surveyDisplay: nil, surveyRating: nil
        ),
        attachments: []
    )
}

func feedPending(
    _ echoId: String,
    at: Int? = nil,
    text: String? = "queued",
    state: StoredPendingMessage.State = .queued,
    path: String? = nil,
    mime: String? = nil
) -> StoredPendingMessage {
    StoredPendingMessage(
        echoId: echoId, conversationId: feedConversation, content: text,
        attachmentPath: path, attachmentMime: mime, kind: .text, state: state,
        createdAt: at ?? feedNoon + 1000, conversationAttributes: nil, posted: false
    )
}

func feedImage(_ id: Int, messageId: Int) -> StoredAttachment {
    StoredAttachment(
        id: id, messageId: messageId, fileType: "image",
        dataUrl: "https://chat.example.com/rails/active_storage/blobs/x/photo.jpg",
        thumbUrl: "https://chat.example.com/thumb.jpg", fileSize: 1000, width: 800, height: 600
    )
}

func feedFile(_ id: Int, messageId: Int, name: String = "report%20final.pdf") -> StoredAttachment {
    StoredAttachment(
        id: id, messageId: messageId, fileType: "file",
        dataUrl: "https://chat.example.com/rails/active_storage/blobs/x/\(name)",
        thumbUrl: nil, fileSize: 2048, width: nil, height: nil
    )
}

func feedSurvey(
    _ id: Int,
    at: Int? = nil,
    text: String? = "Please rate the conversation",
    display: String? = "star",
    rating: Int? = nil
) -> MessageWithAttachments {
    MessageWithAttachments(
        message: StoredMessage(
            id: id, conversationId: feedConversation, content: text, type: 3,
            contentType: "input_csat", createdAt: at ?? feedNoon + id, isMine: false,
            isDeleted: false, senderName: "Bot", senderType: "agent_bot",
            surveyDisplay: display, surveyRating: rating
        ),
        attachments: []
    )
}
