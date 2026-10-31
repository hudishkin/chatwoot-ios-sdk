import Foundation

/// Codec of ActionCable frames for the `RoomChannel` (Chatwoot 4.9.1).
public enum CableCodec {
    private static let channel = "RoomChannel"
    private static let actionUpdatePresence = "update_presence"

    /// Decodes a text frame; `nil` for an unparseable one.
    public static func decode(_ text: String) -> CableMessage? {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let root = raw as? [String: Any] else { return nil }

        if let type = root["type"] as? String {
            switch type {
            case "welcome":
                return .welcome
            case "ping":
                return .ping
            case "confirm_subscription":
                return .confirm(identifier: root["identifier"] as? String)
            case "reject_subscription":
                return .reject(identifier: root["identifier"] as? String)
            case "disconnect":
                return .disconnect(reason: root["reason"] as? String, reconnect: root["reconnect"] as? Bool ?? true)
            default:
                return nil
            }
        }
        guard let message = root["message"] as? [String: Any],
              let name = message["event"] as? String else { return nil }
        let eventData = (message["data"] as? [String: Any]) ?? [:]
        var mapped: [String: JSONValue] = [:]
        mapped.reserveCapacity(eventData.count)
        for (key, value) in eventData { mapped[key] = JSONValue(bridging: value) }
        return .event(name: name, data: mapped, identifier: root["identifier"] as? String)
    }

    public static func subscribeFrame(pubsubToken: String) -> String {
        frame(["command": "subscribe", "identifier": identifier(pubsubToken: pubsubToken)])
    }

    public static func unsubscribeFrame(pubsubToken: String) -> String {
        frame(["command": "unsubscribe", "identifier": identifier(pubsubToken: pubsubToken)])
    }

    public static func presenceFrame(pubsubToken: String) -> String {
        let data = frame(["action": actionUpdatePresence])
        return frame(["command": "message", "identifier": identifier(pubsubToken: pubsubToken), "data": data])
    }

    /// Subscription identifier: `{"channel":"RoomChannel","pubsub_token":"…"}`.
    /// Keys are sorted, so the string is deterministic and safe to compare against
    /// the `identifier` of incoming frames.
    public static func identifier(pubsubToken: String) -> String {
        frame(["channel": channel, "pubsub_token": pubsubToken])
    }

    private static func frame(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
