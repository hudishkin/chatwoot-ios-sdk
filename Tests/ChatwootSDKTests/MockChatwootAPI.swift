import Foundation
@testable import ChatwootSDK

final class MockChatwootAPI: ChatwootAPI {
    var createContactStub = Result<ContactInboxDTO, Error>.failure(ChatwootError.unknown)
    var contactStub = Result<ContactInboxDTO, Error>.failure(ChatwootError.unknown)
    var updateContactStub = Result<ContactDTO, Error>.failure(ChatwootError.unknown)
    var conversationsStub = Result<[ConversationDTO], Error>.success([])
    var createConversationStub = Result<ConversationDTO, Error>.failure(ChatwootError.unknown)
    var messagesStub = Result<[MessageDTO], Error>.success([])
    var createMessageStub = Result<MessageDTO, Error>.failure(ChatwootError.unknown)
    var updateMessageStub = Result<MessageDTO, Error>.failure(ChatwootError.unknown)
    var updateLastSeenStub = Result<Void, Error>.success(())
    var serverInfoStub = Result<ServerInfoDTO, Error>.failure(ChatwootError.unknown)

    private(set) var createContactCalls: [ContactCreateBody] = []
    private(set) var updateContactCalls: [(sourceID: String, body: ContactUpdateBody)] = []
    private(set) var contactChecks: [String] = []
    private(set) var conversationsCalls = 0
    private(set) var messagesCalls: [(conversationID: Int, before: Int?)] = []
    private(set) var createMessageCalls: [(conversationID: Int, content: String?, echoID: String)] = []
    private(set) var createConversationCalls = 0
    private(set) var updateMessageCalls: [(conversationID: Int, messageID: Int, body: UpdateMessageBody)] = []
    private(set) var updateLastSeenCalls: [(sourceID: String, conversationID: Int)] = []

    var conversationsHandler: (() async -> Result<[ConversationDTO], Error>)?
    var messagesHandler: ((Int, Int?) async -> Result<[MessageDTO], Error>)?
    var updateMessageHandler: ((Int, Int, UpdateMessageBody) async throws -> MessageDTO)?

    func createContact(_ body: ContactCreateBody) async throws -> ContactInboxDTO {
        createContactCalls.append(body)
        return try createContactStub.get()
    }

    func contact(sourceID: String, identifier: String?, identifierHash: String?) async throws -> ContactInboxDTO {
        contactChecks.append(sourceID)
        return try contactStub.get()
    }

    func updateContact(sourceID: String, body: ContactUpdateBody) async throws -> ContactDTO {
        updateContactCalls.append((sourceID, body))
        return try updateContactStub.get()
    }

    func conversations(sourceID: String) async throws -> [ConversationDTO] {
        conversationsCalls += 1
        if let handler = conversationsHandler {
            return try await handler().get()
        }
        return try conversationsStub.get()
    }

    func createConversation(sourceID: String, body: ConversationCreateBody) async throws -> ConversationDTO {
        createConversationCalls += 1
        return try createConversationStub.get()
    }

    func messages(sourceID: String, conversationID: Int, before: Int?) async throws -> [MessageDTO] {
        messagesCalls.append((conversationID, before))
        if let handler = messagesHandler {
            return try await handler(conversationID, before).get()
        }
        return try messagesStub.get()
    }

    func createMessage(sourceID: String, conversationID: Int, body: MessageCreateBody) async throws -> MessageDTO {
        createMessageCalls.append((conversationID, body.content, body.echoID))
        return try createMessageStub.get()
    }

    func createMessageWithAttachments(sourceID: String, conversationID: Int, content: String?, echoID: String, attachments: [MultipartFile]) async throws -> MessageDTO {
        createMessageCalls.append((conversationID, content, echoID))
        return try createMessageStub.get()
    }

    func updateMessage(sourceID: String, conversationID: Int, messageID: Int, body: UpdateMessageBody) async throws -> MessageDTO {
        updateMessageCalls.append((conversationID, messageID, body))
        if let handler = updateMessageHandler {
            return try await handler(conversationID, messageID, body)
        }
        return try updateMessageStub.get()
    }

    func updateLastSeen(sourceID: String, conversationID: Int) async throws {
        updateLastSeenCalls.append((sourceID, conversationID))
        try updateLastSeenStub.get()
    }

    func toggleTyping(sourceID: String, conversationID: Int, status: String) async throws {}

    func serverInfo() async throws -> ServerInfoDTO {
        try serverInfoStub.get()
    }
}

struct StubIdentityProvider: IdentityProvider {
    let result: Result<Identity, ChatwootError>

    func fetch() async -> Result<Identity, ChatwootError> { result }
}

enum Fixtures {
    static let identity = Identity(identifier: "user-42", identifierHash: "hash-42")
    static let user = ChatwootUser(name: "Jane", avatarURL: "https://app.example.com/avatar.png")
    static let session = Session(identifier: "user-42", identifierHash: "hash-42", sourceID: "src-1", pubsubToken: "tok-1", contactID: 9)

    static func makeConfig() throws -> ChatwootConfig {
        try ChatwootConfig(baseURL: "https://chat.example.com", inboxIdentifier: "inbox-1", inboxID: 1)
    }

    static func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chatwoot-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func contactInbox(sourceID: String? = "src-1", pubsubToken: String? = "tok-1", id: Int? = 9) -> ContactInboxDTO {
        ContactInboxDTO(sourceID: sourceID, pubsubToken: pubsubToken, id: id, name: nil, email: nil, phoneNumber: nil)
    }

    static func contact(id: Int? = 9, identifier: String? = "user-42") -> ContactDTO {
        ContactDTO(id: id, name: nil, email: nil, phoneNumber: nil, identifier: identifier, customAttributes: nil)
    }
}
