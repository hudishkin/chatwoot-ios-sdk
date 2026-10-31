import SwiftUI

enum ThemePalette {
    struct Scheme {
        let primary, onPrimary, primaryContainer, onPrimaryContainer: Color
        let secondaryContainer, onSecondaryContainer: Color
        let background, onBackground: Color
        let surface, onSurface, surfaceVariant, onSurfaceVariant: Color
        let outline, outlineVariant: Color
        let error, onError, errorContainer, onErrorContainer: Color
        let tertiaryContainer, onTertiaryContainer: Color
    }

    static let light = Scheme(
        primary: Color(hex: 0x0B6E6D), onPrimary: Color(hex: 0xFFFFFF),
        primaryContainer: Color(hex: 0xD3EFED), onPrimaryContainer: Color(hex: 0x00403E),
        secondaryContainer: Color(hex: 0xD5DDE1), onSecondaryContainer: Color(hex: 0x343D43),
        background: Color(hex: 0xF2F4F5), onBackground: Color(hex: 0x222222),
        surface: Color(hex: 0xFFFFFF), onSurface: Color(hex: 0x222222),
        surfaceVariant: Color(hex: 0xF7F8F9), onSurfaceVariant: Color(hex: 0x6B7078),
        outline: Color(hex: 0x8C9099), outlineVariant: Color(hex: 0xE3E6EA),
        error: Color(hex: 0xC9383E), onError: Color(hex: 0xFFFFFF),
        errorContainer: Color(hex: 0xFCEBEC), onErrorContainer: Color(hex: 0x8D1D23),
        tertiaryContainer: Color(hex: 0xFDF3DC), onTertiaryContainer: Color(hex: 0x5C4300)
    )

    static let dark = Scheme(
        primary: Color(hex: 0x5FD4CF), onPrimary: Color(hex: 0x003735),
        primaryContainer: Color(hex: 0x1F4E4C), onPrimaryContainer: Color(hex: 0xD0F2EF),
        secondaryContainer: Color(hex: 0x3A414A), onSecondaryContainer: Color(hex: 0xDCE2E8),
        background: Color(hex: 0x131518), onBackground: Color(hex: 0xECECEC),
        surface: Color(hex: 0x24272C), onSurface: Color(hex: 0xECECEC),
        surfaceVariant: Color(hex: 0x2E3238), onSurfaceVariant: Color(hex: 0xA3A8B0),
        outline: Color(hex: 0x6E737C), outlineVariant: Color(hex: 0x3A3E46),
        error: Color(hex: 0xFFB4AB), onError: Color(hex: 0x690005),
        errorContainer: Color(hex: 0x4A2326), onErrorContainer: Color(hex: 0xFFDAD6),
        tertiaryContainer: Color(hex: 0x3B3220), onTertiaryContainer: Color(hex: 0xFBE3A8)
    )
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct ResolvedChatColors {
    let scheme: ThemePalette.Scheme

    let chatBackground, outgoingBubble, onOutgoingBubble, outgoingMeta, outgoingLink: Color
    let incomingBubble, onIncomingBubble, incomingMeta, incomingLink: Color
    let systemText, failed, failedContainer, onFailedContainer: Color
    let bannerContainer, onBannerContainer: Color
    let composerContainer, composerField: Color
    let unreadDivider: Color
    let avatarPlaceholder, onAvatarPlaceholder: Color
    let dateChip, onDateChip: Color
}

extension ChatwootColors {
    func resolve(dark: Bool) -> ResolvedChatColors {
        let scheme = dark ? ThemePalette.dark : ThemePalette.light
        return ResolvedChatColors(
            scheme: scheme,
            chatBackground: chatBackground ?? scheme.background,
            outgoingBubble: outgoingBubble ?? scheme.primary,
            onOutgoingBubble: onOutgoingBubble ?? scheme.onPrimary,
            outgoingMeta: outgoingMeta ?? scheme.onPrimary.opacity(outgoingMetaAlpha),
            outgoingLink: outgoingLink ?? scheme.onPrimary,
            incomingBubble: incomingBubble ?? scheme.surface,
            onIncomingBubble: onIncomingBubble ?? scheme.onSurface,
            incomingMeta: incomingMeta ?? scheme.onSurfaceVariant,
            incomingLink: incomingLink ?? scheme.primary,
            systemText: systemText ?? scheme.onSurfaceVariant,
            failed: failed ?? scheme.error,
            failedContainer: failedContainer ?? scheme.errorContainer,
            onFailedContainer: onFailedContainer ?? scheme.onErrorContainer,
            bannerContainer: bannerContainer ?? scheme.tertiaryContainer,
            onBannerContainer: onBannerContainer ?? scheme.onTertiaryContainer,
            composerContainer: composerContainer ?? scheme.surface,
            composerField: composerField ?? scheme.background,
            unreadDivider: unreadDivider ?? scheme.primary,
            avatarPlaceholder: avatarPlaceholder ?? scheme.primaryContainer,
            onAvatarPlaceholder: onAvatarPlaceholder ?? scheme.onPrimaryContainer,
            dateChip: dateChip ?? scheme.secondaryContainer,
            onDateChip: onDateChip ?? scheme.onSecondaryContainer
        )
    }
}

let outgoingMetaAlpha = 0.85

extension ChatwootTheme {
    func resolve(systemDark: Bool) -> (dark: Bool, colors: ResolvedChatColors) {
        let dark: Bool
        switch darkMode {
        case .followSystem: dark = systemDark
        case .light: dark = false
        case .dark: dark = true
        }
        return (dark, (dark ? darkChatColors : lightChatColors).resolve(dark: dark))
    }
}

enum Spacing {
    static let listInset: CGFloat = 12
    static let bubbleHorizontal: CGFloat = 12
    static let bubbleVertical: CGFloat = 8
    static let inRun: CGFloat = 2
    static let betweenRuns: CGFloat = 8
    static let bubbleMaxWidth: CGFloat = 320
    static let bubbleMaxFraction: CGFloat = 0.8
    static let avatar: CGFloat = 32
    static let avatarGap: CGFloat = 8
    static let touchTarget: CGFloat = 48
}

private struct ChatColorsKey: EnvironmentKey {
    static let defaultValue = ChatwootColors.derived.resolve(dark: false)
}

extension EnvironmentValues {
    var chatColors: ResolvedChatColors {
        get { self[ChatColorsKey.self] }
        set { self[ChatColorsKey.self] = newValue }
    }
}
