import SwiftUI
import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import ChatwootSDK

final class ThemeTests: XCTestCase {
    func testFollowSystemSelectsTheMatchingColorSet() {
        let light = Color(red: 1, green: 1, blue: 1)
        let dark = Color(red: 0, green: 0, blue: 0)
        let theme = ChatwootTheme(
            lightChatColors: ChatwootColors(chatBackground: light),
            darkChatColors: ChatwootColors(chatBackground: dark)
        )

        let inLight = theme.resolve(systemDark: false)
        XCTAssertFalse(inLight.dark)
        ColorProbe.assertEqual(inLight.colors.chatBackground, light)

        let inDark = theme.resolve(systemDark: true)
        XCTAssertTrue(inDark.dark)
        ColorProbe.assertEqual(inDark.colors.chatBackground, dark)
    }

    func testPinnedAppearanceIgnoresTheSystem() {
        let light = Color(red: 1, green: 1, blue: 1)
        let dark = Color(red: 0, green: 0, blue: 0)
        let theme = ChatwootTheme(
            lightChatColors: ChatwootColors(chatBackground: light),
            darkChatColors: ChatwootColors(chatBackground: dark),
            darkMode: .light
        )

        let resolved = theme.resolve(systemDark: true)
        XCTAssertFalse(resolved.dark)
        ColorProbe.assertEqual(resolved.colors.chatBackground, light)

        let forcedDark = ChatwootTheme(
            lightChatColors: ChatwootColors(chatBackground: light),
            darkChatColors: ChatwootColors(chatBackground: dark),
            darkMode: .dark
        ).resolve(systemDark: false)
        XCTAssertTrue(forcedDark.dark)
        ColorProbe.assertEqual(forcedDark.colors.chatBackground, dark)
    }

    func testUnsetTokensUseThePaletteOfThatAppearance() {
        let light = ChatwootColors.derived.resolve(dark: false)
        ColorProbe.assertEqual(light.chatBackground, ThemePalette.light.background)
        ColorProbe.assertEqual(light.incomingBubble, ThemePalette.light.surface)
        ColorProbe.assertEqual(light.onIncomingBubble, ThemePalette.light.onSurface)
        ColorProbe.assertEqual(light.composerField, ThemePalette.light.background)
        ColorProbe.assertEqual(light.composerText, ThemePalette.light.onSurface)
        ColorProbe.assertEqual(light.composerPlaceholder, ThemePalette.light.onSurfaceVariant)
        ColorProbe.assertEqual(light.composerDivider, ThemePalette.light.outlineVariant)
        ColorProbe.assertEqual(light.accent, ThemePalette.light.primary)
        ColorProbe.assertEqual(light.outgoingBubble, ThemePalette.light.primary)
        ColorProbe.assertEqual(light.dateChip, ThemePalette.light.secondaryContainer)
        ColorProbe.assertEqual(light.navigationBar, ThemePalette.light.surface)
        ColorProbe.assertEqual(light.onNavigationBar, ThemePalette.light.onSurface)

        let dark = ChatwootColors.derived.resolve(dark: true)
        ColorProbe.assertEqual(dark.chatBackground, ThemePalette.dark.background)
        ColorProbe.assertEqual(dark.accent, ThemePalette.dark.primary)
        ColorProbe.assertEqual(dark.composerField, ThemePalette.dark.background)
        ColorProbe.assertEqual(dark.incomingBubble, ThemePalette.dark.surface)
        ColorProbe.assertEqual(dark.navigationBar, ThemePalette.dark.surface)
        ColorProbe.assertEqual(dark.onNavigationBar, ThemePalette.dark.onSurface)
    }

    func testAccentRecolorsBrandSurfacesUntilATokenOverridesIt() {
        let brand = Color(red: 1, green: 0, blue: 0)
        let onBrand = Color(red: 0, green: 1, blue: 0)
        let bubble = Color(red: 0, green: 0, blue: 1)
        let resolved = ChatwootColors(
            outgoingBubble: bubble,
            accent: brand,
            onAccent: onBrand
        ).resolve(dark: false)

        ColorProbe.assertEqual(resolved.accent, brand)
        ColorProbe.assertEqual(resolved.onAccent, onBrand)
        ColorProbe.assertEqual(resolved.outgoingBubble, bubble)
        ColorProbe.assertEqual(resolved.onOutgoingBubble, onBrand)
        ColorProbe.assertEqual(resolved.outgoingLink, onBrand)
        ColorProbe.assertEqual(resolved.incomingLink, brand)
        ColorProbe.assertEqual(resolved.composerSend, brand)
        ColorProbe.assertEqual(resolved.onComposerSend, onBrand)
        ColorProbe.assertEqual(resolved.unreadDivider, brand)
        ColorProbe.assertEqual(resolved.onUnreadDivider, onBrand)
        ColorProbe.assertEqual(resolved.outgoingMeta, onBrand.opacity(0.85))
    }

    func testExplicitTokenWinsOverThePalette() {
        let field = Color(red: 0.2, green: 0.3, blue: 0.4)
        let text = Color(red: 0.1, green: 0.2, blue: 0.3)
        let bar = Color(red: 0.4, green: 0.5, blue: 0.6)
        let onBar = Color(red: 0.95, green: 0.95, blue: 0.95)
        let resolved = ChatwootColors(
            composerField: field,
            composerText: text,
            navigationBar: bar,
            onNavigationBar: onBar
        ).resolve(dark: true)
        ColorProbe.assertEqual(resolved.composerField, field)
        ColorProbe.assertEqual(resolved.composerText, text)
        ColorProbe.assertEqual(resolved.navigationBar, bar)
        ColorProbe.assertEqual(resolved.onNavigationBar, onBar)
        ColorProbe.assertEqual(resolved.chatBackground, ThemePalette.dark.background)
    }
}

private enum ColorProbe {
    static func assertEqual(
        _ lhs: Color,
        _ rhs: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let left = rgba(lhs)
        let right = rgba(rhs)
        XCTAssertEqual(left.r, right.r, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(left.g, right.g, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(left.b, right.b, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(left.a, right.a, accuracy: 0.02, file: file, line: line)
    }

    private static func rgba(_ color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        #if canImport(UIKit)
        let native = UIColor(color)
        #else
        let native = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        #endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        native.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}
