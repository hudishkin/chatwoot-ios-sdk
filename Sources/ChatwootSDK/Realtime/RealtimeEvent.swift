import Foundation

/// Realtime event of the `RoomChannel` (Chatwoot 4.9.1).
/// The `conversation.read` and `contact.merged` events are not delivered to contacts.
public enum RealtimeEvent: Equatable {
    case messageCreated(MessageDTO, echoID: String?)
    case messageUpdated(MessageDTO)
    case conversationStatusChanged(id: Int, status: ConversationStatus, inboxID: Int?)
    case conversationUpdated(id: Int, inboxID: Int?)
    case typing(conversationID: Int, on: Bool, inboxID: Int?)

    /// Parses an ActionCable frame event; `nil` for an unknown or malformed one
    /// (private typing, a foreign channel, invalid data).
    public static func fromCableEvent(name: String, data: [String: JSONValue]) -> RealtimeEvent? {
        switch name {
        case "message.created":
            guard let dto = try? JSONValue.object(data).decoded(as: MessageDTO.self) else { return nil }
            return .messageCreated(dto, echoID: data["echo_id"]?.stringValue)
        case "message.updated":
            guard let dto = try? JSONValue.object(data).decoded(as: MessageDTO.self) else { return nil }
            return .messageUpdated(dto)
        case "conversation.status_changed":
            guard let id = data["id"]?.intValue else { return nil }
            return .conversationStatusChanged(
                id: Int(id),
                status: ConversationStatus(apiName: data["status"]?.stringValue),
                inboxID: data["inbox_id"]?.intValue.map(Int.init)
            )
        case "conversation.updated":
            guard let id = data["id"]?.intValue else { return nil }
            return .conversationUpdated(id: Int(id), inboxID: data["inbox_id"]?.intValue.map(Int.init))
        case "conversation.typing_on", "conversation.typing_off":
            let isPrivate = data["is_private"]?.boolValue == true
            guard !isPrivate,
                  let conversation = data["conversation"]?.objectValue,
                  let id = conversation["id"]?.intValue else { return nil }
            return .typing(
                conversationID: Int(id),
                on: name.hasSuffix("_on"),
                inboxID: conversation["inbox_id"]?.intValue.map(Int.init)
            )
        default:
            return nil
        }
    }
}

/// Channel subscription state.
public enum SubscriptionState: Equatable, Sendable {
    case idle, subscribing, confirmed, rejected
}
