import Foundation

/// Reason a SDK call failed. Minor versions may add new cases: always include a
/// `default` when switching over this type.
public enum ChatwootError: Error, Equatable {
    case network
    case http(code: Int)
    /// The server returned a contact that does not match the requested identity.
    case identityMismatch
    /// The attachment exceeds the 40 MB limit; it was not enqueued.
    case tooLarge
    /// The attachment could not be read from its source; it was not enqueued.
    case unreadable
    /// `Chatwoot.initialize(_:)` has not been called yet.
    case notInitialized
    case unknown
}
