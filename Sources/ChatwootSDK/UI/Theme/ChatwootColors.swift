import SwiftUI

/// Whether to follow the system dark appearance or pin one.
public enum ChatwootDarkMode: Equatable, Sendable {
    case followSystem, light, dark
}

/// Color tokens of the chat. A token left `nil` falls back to the SDK palette
/// (neutral with a teal accent), so a host usually sets only the tokens that
/// should differ.
public struct ChatwootColors: Equatable, Sendable {
    /// Feed background.
    public var chatBackground: Color?
    /// User's bubbles.
    public var outgoingBubble: Color?
    /// Text on the user's bubbles.
    public var onOutgoingBubble: Color?
    /// Time and status on the user's bubbles (defaults to content at 85% opacity).
    public var outgoingMeta: Color?
    /// Links on the user's bubbles (always underlined).
    public var outgoingLink: Color?
    /// Agent's bubbles.
    public var incomingBubble: Color?
    /// Text on the agent's bubbles.
    public var onIncomingBubble: Color?
    /// Agent name and time.
    public var incomingMeta: Color?
    /// Links on the agent's bubbles.
    public var incomingLink: Color?
    /// System rows and the empty state.
    public var systemText: Color?
    /// The "not sent" row.
    public var failed: Color?
    /// Error surfaces.
    public var failedContainer: Color?
    /// Text on error surfaces.
    public var onFailedContainer: Color?
    /// Connection banner.
    public var bannerContainer: Color?
    /// Text on the connection banner.
    public var onBannerContainer: Color?
    /// Composer bar.
    public var composerContainer: Color?
    /// Composer input field.
    public var composerField: Color?
    /// "New messages" chip.
    public var unreadDivider: Color?
    /// Agent avatar with initials.
    public var avatarPlaceholder: Color?
    /// Initials on the avatar.
    public var onAvatarPlaceholder: Color?
    /// Day separator chip.
    public var dateChip: Color?
    /// Text on the day separator chip.
    public var onDateChip: Color?

    public init(
        chatBackground: Color? = nil,
        outgoingBubble: Color? = nil,
        onOutgoingBubble: Color? = nil,
        outgoingMeta: Color? = nil,
        outgoingLink: Color? = nil,
        incomingBubble: Color? = nil,
        onIncomingBubble: Color? = nil,
        incomingMeta: Color? = nil,
        incomingLink: Color? = nil,
        systemText: Color? = nil,
        failed: Color? = nil,
        failedContainer: Color? = nil,
        onFailedContainer: Color? = nil,
        bannerContainer: Color? = nil,
        onBannerContainer: Color? = nil,
        composerContainer: Color? = nil,
        composerField: Color? = nil,
        unreadDivider: Color? = nil,
        avatarPlaceholder: Color? = nil,
        onAvatarPlaceholder: Color? = nil,
        dateChip: Color? = nil,
        onDateChip: Color? = nil
    ) {
        self.chatBackground = chatBackground
        self.outgoingBubble = outgoingBubble
        self.onOutgoingBubble = onOutgoingBubble
        self.outgoingMeta = outgoingMeta
        self.outgoingLink = outgoingLink
        self.incomingBubble = incomingBubble
        self.onIncomingBubble = onIncomingBubble
        self.incomingMeta = incomingMeta
        self.incomingLink = incomingLink
        self.systemText = systemText
        self.failed = failed
        self.failedContainer = failedContainer
        self.onFailedContainer = onFailedContainer
        self.bannerContainer = bannerContainer
        self.onBannerContainer = onBannerContainer
        self.composerContainer = composerContainer
        self.composerField = composerField
        self.unreadDivider = unreadDivider
        self.avatarPlaceholder = avatarPlaceholder
        self.onAvatarPlaceholder = onAvatarPlaceholder
        self.dateChip = dateChip
        self.onDateChip = onDateChip
    }

    /// All tokens taken from the SDK palette.
    public static let derived = ChatwootColors()
}

/// Appearance of the chat screen. Everything is optional: tokens not set by the
/// host fall back to the SDK palette. Passed to `Chatwoot.chatView`.
public struct ChatwootTheme: Equatable, Sendable {
    public var lightChatColors: ChatwootColors
    public var darkChatColors: ChatwootColors
    public var darkMode: ChatwootDarkMode

    public init(
        lightChatColors: ChatwootColors = .derived,
        darkChatColors: ChatwootColors = .derived,
        darkMode: ChatwootDarkMode = .followSystem
    ) {
        self.lightChatColors = lightChatColors
        self.darkChatColors = darkChatColors
        self.darkMode = darkMode
    }

    /// Default SDK look: neutral palette with a teal accent, system dark mode.
    public static let `default` = ChatwootTheme()
}
