import Foundation

/// Pseudonymous contact identifier and its HMAC, computed on the host's backend
/// (never in the app: the inbox HMAC token must not ship with the app).
/// `description` is masked.
public struct Identity: Equatable {
    public let identifier: String
    public let identifierHash: String

    public init(identifier: String, identifierHash: String) {
        self.identifier = identifier
        self.identifierHash = identifierHash
    }
}

extension Identity: CustomStringConvertible {
    public var description: String { "Identity(***)" }
}

/// Identity provider: the SDK asks the host's backend for it on `identify`.
public protocol IdentityProvider {
    func fetch() async -> Result<Identity, ChatwootError>
}
