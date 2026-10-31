import Foundation

/// Contact profile shown to agents, sent on identify.
/// `description` is masked: both fields are personal data.
public struct ChatwootUser: Equatable {
    public let name: String?
    public let avatarURL: String?

    public init(name: String?, avatarURL: String? = nil) {
        self.name = name
        self.avatarURL = avatarURL
    }
}

extension ChatwootUser: CustomStringConvertible {
    public var description: String { "ChatwootUser(***)" }
}
