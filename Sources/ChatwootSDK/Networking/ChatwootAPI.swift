import Foundation

/// File for a multipart attachment upload.
public struct MultipartFile: Equatable, Sendable {
    public let data: Data
    public let filename: String
    public let mimeType: String

    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }
}

/// Client of the Chatwoot **Client API** for an API inbox
/// (`/public/api/v1/inboxes/{inbox_identifier}/...`), verified against Chatwoot 4.9.1.
/// Errors are `ChatwootError`.
public protocol ChatwootAPI {
    /// `POST contacts`: finds the contact by `identifier` or creates it; always
    /// creates a new contact-inbox (`source_id`, `pubsub_token`).
    func createContact(_ body: ContactCreateBody) async throws -> ContactInboxDTO

    /// Cheap contact-inbox check: 404 for an unknown `sourceID`. With `hmac_mandatory`
    /// the server verifies `identifierHash` against `identifier` right here, so both
    /// travel as query parameters.
    func contact(sourceID: String, identifier: String?, identifierHash: String?) async throws -> ContactInboxDTO

    /// `PATCH contacts/{sourceID}`: profile and custom attributes (server-side deep-merge).
    func updateContact(sourceID: String, body: ContactUpdateBody) async throws -> ContactDTO

    /// All conversations of the contact with all messages, unpaginated.
    func conversations(sourceID: String) async throws -> [ConversationDTO]

    /// `POST conversations`: honours the inbox's `lock_to_single_conversation` setting.
    func createConversation(sourceID: String, body: ConversationCreateBody) async throws -> ConversationDTO

    /// 20 newest messages (oldest first), or 20 before `before` — backward pagination.
    func messages(sourceID: String, conversationID: Int, before: Int?) async throws -> [MessageDTO]

    /// `POST messages` with a JSON body `{content, echo_id}`.
    func createMessage(sourceID: String, conversationID: Int, body: MessageCreateBody) async throws -> MessageDTO

    /// `POST messages` multipart: `content`, `echo_id`, `attachments[]` (up to 40 MB each).
    func createMessageWithAttachments(
        sourceID: String,
        conversationID: Int,
        content: String?,
        echoID: String,
        attachments: [MultipartFile]
    ) async throws -> MessageDTO

    /// `PATCH messages/{id}`: answer to an interactive message (survey). Resending
    /// replaces the previous answer; 404 means the message is gone, 422 — the survey
    /// window is closed.
    func updateMessage(sourceID: String, conversationID: Int, messageID: Int, body: UpdateMessageBody) async throws -> MessageDTO

    /// "Read" marker (client-side debounce).
    func updateLastSeen(sourceID: String, conversationID: Int) async throws

    /// `typing_status`: `"on"` / `"off"`.
    func toggleTyping(sourceID: String, conversationID: Int, status: String) async throws

    /// `GET /api`: server version.
    func serverInfo() async throws -> ServerInfoDTO
}
