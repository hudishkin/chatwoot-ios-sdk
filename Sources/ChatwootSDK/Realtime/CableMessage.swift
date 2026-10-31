import Foundation

/// A Rails ActionCable (`/cable`) frame decoded from a text WebSocket frame.
public enum CableMessage: Equatable {
    case welcome
    case ping
    case confirm(identifier: String?)
    case reject(identifier: String?)
    case disconnect(reason: String?, reconnect: Bool)
    case event(name: String, data: [String: JSONValue], identifier: String?)
}
