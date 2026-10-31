import Foundation

/// `ChatwootAPI` implementation on `URLSession` (Chatwoot 4.9.1 contract).
public final class URLSessionChatwootAPI: ChatwootAPI {
    private let baseURL: URL
    private let inboxIdentifier: String
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, inboxIdentifier: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.inboxIdentifier = inboxIdentifier
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public convenience init(config: ChatwootConfig, session: URLSession = .shared) {
        self.init(baseURL: config.baseURL, inboxIdentifier: config.inboxIdentifier, session: session)
    }

    // MARK: - Contacts

    public func createContact(_ body: ContactCreateBody) async throws -> ContactInboxDTO {
        try await send(path: contactsPath, method: "POST", json: body)
    }

    public func contact(sourceID: String, identifier: String?, identifierHash: String?) async throws -> ContactInboxDTO {
        var query: [URLQueryItem] = []
        if let identifier { query.append(URLQueryItem(name: "identifier", value: identifier)) }
        if let identifierHash { query.append(URLQueryItem(name: "identifier_hash", value: identifierHash)) }
        return try await send(path: "\(contactsPath)/\(sourceID)", method: "GET", query: query)
    }

    public func updateContact(sourceID: String, body: ContactUpdateBody) async throws -> ContactDTO {
        try await send(path: "\(contactsPath)/\(sourceID)", method: "PATCH", json: body)
    }

    // MARK: - Conversations

    public func conversations(sourceID: String) async throws -> [ConversationDTO] {
        try await send(path: "\(contactsPath)/\(sourceID)/conversations", method: "GET")
    }

    public func createConversation(sourceID: String, body: ConversationCreateBody) async throws -> ConversationDTO {
        try await send(path: "\(contactsPath)/\(sourceID)/conversations", method: "POST", json: body)
    }

    // MARK: - Messages

    public func messages(sourceID: String, conversationID: Int, before: Int?) async throws -> [MessageDTO] {
        var query: [URLQueryItem] = []
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        return try await send(path: messagesPath(sourceID: sourceID, conversationID: conversationID), method: "GET", query: query)
    }

    public func createMessage(sourceID: String, conversationID: Int, body: MessageCreateBody) async throws -> MessageDTO {
        try await send(path: messagesPath(sourceID: sourceID, conversationID: conversationID), method: "POST", json: body)
    }

    public func createMessageWithAttachments(
        sourceID: String,
        conversationID: Int,
        content: String?,
        echoID: String,
        attachments: [MultipartFile]
    ) async throws -> MessageDTO {
        let boundary = "ChatwootBoundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        if let content, !content.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"content\"\r\n\r\n")
            append("\(content)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"echo_id\"\r\n\r\n")
        append("\(echoID)\r\n")
        for file in attachments {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"attachments[]\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.mimeType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        var request = try makeRequest(path: messagesPath(sourceID: sourceID, conversationID: conversationID), method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await perform(request)
    }

    public func updateMessage(sourceID: String, conversationID: Int, messageID: Int, body: UpdateMessageBody) async throws -> MessageDTO {
        try await send(path: "\(messagesPath(sourceID: sourceID, conversationID: conversationID))/\(messageID)", method: "PATCH", json: body)
    }

    public func updateLastSeen(sourceID: String, conversationID: Int) async throws {
        let _: EmptyResponse = try await send(path: "\(contactsPath)/\(sourceID)/conversations/\(conversationID)/update_last_seen", method: "POST")
    }

    public func toggleTyping(sourceID: String, conversationID: Int, status: String) async throws {
        let _: EmptyResponse = try await send(
            path: "\(contactsPath)/\(sourceID)/conversations/\(conversationID)/toggle_typing",
            method: "POST",
            query: [URLQueryItem(name: "typing_status", value: status)]
        )
    }

    // MARK: - Server

    public func serverInfo() async throws -> ServerInfoDTO {
        try await send(path: "api", method: "GET")
    }

    // MARK: - Private

    private var contactsPath: String { "public/api/v1/inboxes/\(inboxIdentifier)/contacts" }

    private func messagesPath(sourceID: String, conversationID: Int) -> String {
        "\(contactsPath)/\(sourceID)/conversations/\(conversationID)/messages"
    }

    private func makeRequest(path: String, method: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ChatwootError.unknown
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ChatwootError.unknown }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        return request
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await perform(makeRequest(path: path, method: method, query: query))
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        json body: Body
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw ChatwootError.unknown
        }
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as ChatwootError {
            throw error
        } catch {
            throw ChatwootError.network
        }
        guard let http = response as? HTTPURLResponse else { throw ChatwootError.unknown }
        guard (200..<300).contains(http.statusCode) else { throw ChatwootError.http(code: http.statusCode) }
        if Response.self == EmptyResponse.self, let empty = EmptyResponse() as? Response {
            return empty
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ChatwootError.unknown
        }
    }
}

private struct EmptyResponse: Decodable {}
