import SwiftUI

/// Whether to follow the system dark appearance or pin one.
public enum ChatwootDarkMode: Equatable, Sendable {
    case followSystem, light, dark
}

/// Color tokens of one appearance (light or dark).
///
/// A `nil` token falls back to the SDK palette: a neutral background with a
/// teal brand color. Brand surfaces fall back to `accent` first, and `accent`
/// itself falls back to that teal. A host usually sets only the tokens that
/// should differ. Pass one value as `ChatwootTheme.lightChatColors` and
/// another as `darkChatColors`.
public struct ChatwootColors: Equatable, Sendable {
    /// Feed background.
    public var chatBackground: Color?
    /// User's bubbles. Defaults to `accent`.
    public var outgoingBubble: Color?
    /// Text on the user's bubbles. Defaults to `onAccent`.
    public var onOutgoingBubble: Color?
    /// Time and status on the user's bubbles. Defaults to `onAccent` at 85% opacity.
    public var outgoingMeta: Color?
    /// Links on the user's bubbles (always underlined). Defaults to `onAccent`.
    public var outgoingLink: Color?
    /// Agent's bubbles.
    public var incomingBubble: Color?
    /// Text on the agent's bubbles.
    public var onIncomingBubble: Color?
    /// Agent name and time.
    public var incomingMeta: Color?
    /// Links on the agent's bubbles. Defaults to `accent`.
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
    /// Text typed in the composer.
    public var composerText: Color?
    /// Composer placeholder and the attach icon.
    public var composerPlaceholder: Color?
    /// Send button. Defaults to `accent`.
    public var composerSend: Color?
    /// Icon on the send button. Defaults to `onAccent`.
    public var onComposerSend: Color?
    /// Hairline above the composer.
    public var composerDivider: Color?
    /// "New messages" chip. Defaults to `accent`.
    public var unreadDivider: Color?
    /// Text and icon on the "New messages" chip. Defaults to `onAccent`.
    public var onUnreadDivider: Color?
    /// Agent avatar with initials.
    public var avatarPlaceholder: Color?
    /// Initials on the avatar.
    public var onAvatarPlaceholder: Color?
    /// Day separator chip.
    public var dateChip: Color?
    /// Text on the day separator chip.
    public var onDateChip: Color?
    /// Navigation bar background.
    public var navigationBar: Color?
    /// Navigation title and bar buttons.
    public var onNavigationBar: Color?
    /// Brand color. Fallback for the outgoing bubble, incoming links, the send
    /// button, the "New messages" chip, and filled survey stars.
    public var accent: Color?
    /// Content drawn on `accent`: outgoing text and links, the send icon, and
    /// the "New messages" label, unless those tokens are set themselves.
    public var onAccent: Color?

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
        composerText: Color? = nil,
        composerPlaceholder: Color? = nil,
        composerSend: Color? = nil,
        onComposerSend: Color? = nil,
        composerDivider: Color? = nil,
        unreadDivider: Color? = nil,
        onUnreadDivider: Color? = nil,
        avatarPlaceholder: Color? = nil,
        onAvatarPlaceholder: Color? = nil,
        dateChip: Color? = nil,
        onDateChip: Color? = nil,
        navigationBar: Color? = nil,
        onNavigationBar: Color? = nil,
        accent: Color? = nil,
        onAccent: Color? = nil
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
        self.composerText = composerText
        self.composerPlaceholder = composerPlaceholder
        self.composerSend = composerSend
        self.onComposerSend = onComposerSend
        self.composerDivider = composerDivider
        self.unreadDivider = unreadDivider
        self.onUnreadDivider = onUnreadDivider
        self.avatarPlaceholder = avatarPlaceholder
        self.onAvatarPlaceholder = onAvatarPlaceholder
        self.dateChip = dateChip
        self.onDateChip = onDateChip
        self.navigationBar = navigationBar
        self.onNavigationBar = onNavigationBar
        self.accent = accent
        self.onAccent = onAccent
    }

    /// All tokens taken from the SDK palette.
    public static let derived = ChatwootColors()
}

/// Appearance of the chat screen. Pass it to `Chatwoot.chatView(theme:)`.
///
/// `lightChatColors` is used when the resolved appearance is light, and
/// `darkChatColors` when it is dark. `darkMode` picks that appearance: follow
/// the system, or pin light or dark. Tokens left unset fall back to the SDK
/// palette of the resolved appearance. `agentAvatar` replaces the initials of
/// every support agent; `nil` keeps them.
public struct ChatwootTheme: Equatable, Sendable {
    /// Colors used while the chat is light.
    public var lightChatColors: ChatwootColors
    /// Colors used while the chat is dark.
    public var darkChatColors: ChatwootColors
    /// How the chat chooses between `lightChatColors` and `darkChatColors`.
    public var darkMode: ChatwootDarkMode
    /// Image drawn, cropped to a circle, as the avatar of every support agent.
    /// `nil` keeps the initials.
    public var agentAvatar: Image?

    public init(
        lightChatColors: ChatwootColors = .derived,
        darkChatColors: ChatwootColors = .derived,
        darkMode: ChatwootDarkMode = .followSystem,
        agentAvatar: Image? = nil
    ) {
        self.lightChatColors = lightChatColors
        self.darkChatColors = darkChatColors
        self.darkMode = darkMode
        self.agentAvatar = agentAvatar
    }

    /// Default SDK look: neutral palette with a teal accent, system dark mode.
    public static let `default` = ChatwootTheme()

    public static func == (lhs: ChatwootTheme, rhs: ChatwootTheme) -> Bool {
        lhs.lightChatColors == rhs.lightChatColors
            && lhs.darkChatColors == rhs.darkChatColors
            && lhs.darkMode == rhs.darkMode
            && (lhs.agentAvatar == nil) == (rhs.agentAvatar == nil)
    }
}
