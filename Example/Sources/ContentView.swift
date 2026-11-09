import ChatwootSDK
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var systemScheme
    @State private var showChat = false
    @State private var busy = false
    @State private var status: String?
    @State private var theme: SampleTheme = .sdk
    @State private var appearance: SampleAppearance = .system

    private var resolvedDark: Bool {
        switch appearance {
        case .system: return systemScheme == .dark
        case .light: return false
        case .dark: return true
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Chatwoot SDK Example")
                .font(.headline)
            Text("SDK version: \(ChatwootSDK.version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Theme", selection: $theme) {
                    ForEach(SampleTheme.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Appearance", selection: $appearance) {
                    ForEach(SampleAppearance.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Button(action: { Task { await openChat() } }) {
                Text(busy ? "Opening…" : "Open chat")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

            if let status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: 420)
        .onAppear {
            if !SampleConfig.isConfigured {
                status = "Test server is not configured. Copy Example/config.example.json to Example/Resources/config.json, fill it in and run tuist generate."
            } else if SampleConfig.installFailed {
                status = "SDK config is invalid. Check baseURL, inboxIdentifier and inboxID."
            }
        }
        .fullScreenCover(isPresented: $showChat) {
            NavigationView {
                Chatwoot.chatView(request: chatRequest, theme: theme.theme(appearance))
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") { showChat = false }
                                .foregroundColor(theme.barForeground(dark: resolvedDark))
                        }
                    }
            }
            .navigationViewStyle(.stack)
            .preferredColorScheme(appearance.colorScheme)
        }
    }

    private var chatRequest: ChatRequest {
        ChatRequest(attachmentMenu: [
            .camera,
            .photo,
            .file,
            .custom(CustomAttachment(title: "Sample note", systemImage: "note.text") {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sample-note-\(UUID().uuidString).txt")
                do {
                    try Data("Sample note\n".utf8).write(to: url)
                    return ChatAttachmentFile(url: url, mimeType: "text/plain")
                } catch {
                    return nil
                }
            })
        ],
                    galleryRepresentation: .compatible)
    }

    private func openChat() async {
        guard SampleConfig.isConfigured, !SampleConfig.installFailed else { return }
        busy = true
        defer { busy = false }
        let result = await Chatwoot.identify(
            user: ChatwootUser(name: SampleConfig.userID),
            identity: DebugIdentityProvider(userId: SampleConfig.userID, hmacToken: SampleConfig.hmacToken)
        )
        switch result {
        case .success:
            status = nil
            showChat = true
        case .failure:
            status = "Sign in failed"
        }
    }
}

private enum SampleTheme: String, CaseIterable, Identifiable {
    case sdk
    case blue
    case ember

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sdk: return "SDK"
        case .blue: return "Blue"
        case .ember: return "Ember"
        }
    }

    func theme(_ appearance: SampleAppearance) -> ChatwootTheme {
        var theme: ChatwootTheme
        switch self {
        case .sdk: theme = .default
        case .blue: theme = .blue
        case .ember: theme = .ember
        }
        theme.darkMode = appearance.darkMode
        return theme
    }

    func barForeground(dark: Bool) -> Color {
        switch (self, dark) {
        case (.sdk, false): return Color(hex: 0x222222)
        case (.sdk, true): return Color(hex: 0xECECEC)
        case (.blue, false): return Color(hex: 0xFFFFFF)
        case (.blue, true): return Color(hex: 0xDBEAFE)
        case (.ember, false): return Color(hex: 0xFFF7ED)
        case (.ember, true): return Color(hex: 0xFFEDD5)
        }
    }
}

private enum SampleAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var darkMode: ChatwootDarkMode {
        switch self {
        case .system: return .followSystem
        case .light: return .light
        case .dark: return .dark
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private extension ChatwootTheme {
    static let blue = ChatwootTheme(
        lightChatColors: ChatwootColors(
            chatBackground: Color(hex: 0xF4F7FB),
            incomingBubble: Color(hex: 0xFFFFFF),
            onIncomingBubble: Color(hex: 0x0F172A),
            incomingMeta: Color(hex: 0x64748B),
            composerContainer: Color(hex: 0xFFFFFF),
            composerField: Color(hex: 0xE8EEF6),
            composerText: Color(hex: 0x0F172A),
            composerPlaceholder: Color(hex: 0x64748B),
            composerDivider: Color(hex: 0xD5DEEA),
            avatarPlaceholder: Color(hex: 0xDBE7FF),
            onAvatarPlaceholder: Color(hex: 0x1E3A8A),
            dateChip: Color(hex: 0xE2E8F0),
            onDateChip: Color(hex: 0x334155),
            navigationBar: Color(hex: 0x1D4ED8),
            onNavigationBar: Color(hex: 0xFFFFFF),
            accent: Color(hex: 0x1D4ED8),
            onAccent: Color(hex: 0xFFFFFF)
        ),
        darkChatColors: ChatwootColors(
            chatBackground: Color(hex: 0x0B1220),
            incomingBubble: Color(hex: 0x1E293B),
            onIncomingBubble: Color(hex: 0xE2E8F0),
            incomingMeta: Color(hex: 0x94A3B8),
            composerContainer: Color(hex: 0x111827),
            composerField: Color(hex: 0x1E293B),
            composerText: Color(hex: 0xE2E8F0),
            composerPlaceholder: Color(hex: 0x94A3B8),
            composerDivider: Color(hex: 0x334155),
            avatarPlaceholder: Color(hex: 0x1E3A8A),
            onAvatarPlaceholder: Color(hex: 0xDBEAFE),
            dateChip: Color(hex: 0x334155),
            onDateChip: Color(hex: 0xE2E8F0),
            navigationBar: Color(hex: 0x1E3A8A),
            onNavigationBar: Color(hex: 0xDBEAFE),
            accent: Color(hex: 0x93C5FD),
            onAccent: Color(hex: 0x0B1B3A)
        )
    )

    static let ember = ChatwootTheme(
        lightChatColors: ChatwootColors(
            chatBackground: Color(hex: 0xFBF6F1),
            incomingBubble: Color(hex: 0xFFFFFF),
            onIncomingBubble: Color(hex: 0x292524),
            incomingMeta: Color(hex: 0x78716C),
            composerContainer: Color(hex: 0xFFFBF7),
            composerField: Color(hex: 0xF3EBE3),
            composerText: Color(hex: 0x292524),
            composerPlaceholder: Color(hex: 0xA8A29E),
            composerDivider: Color(hex: 0xE7D9CC),
            avatarPlaceholder: Color(hex: 0xFFEDD5),
            onAvatarPlaceholder: Color(hex: 0x9A3412),
            dateChip: Color(hex: 0xF5E6D8),
            onDateChip: Color(hex: 0x57534E),
            navigationBar: Color(hex: 0xC2410C),
            onNavigationBar: Color(hex: 0xFFF7ED),
            accent: Color(hex: 0xC2410C),
            onAccent: Color(hex: 0xFFF7ED)
        ),
        darkChatColors: ChatwootColors(
            chatBackground: Color(hex: 0x1C1410),
            incomingBubble: Color(hex: 0x2A211C),
            onIncomingBubble: Color(hex: 0xFAF5F0),
            incomingMeta: Color(hex: 0xA8A29E),
            composerContainer: Color(hex: 0x241C17),
            composerField: Color(hex: 0x322820),
            composerText: Color(hex: 0xFAF5F0),
            composerPlaceholder: Color(hex: 0xA8A29E),
            composerDivider: Color(hex: 0x44403C),
            avatarPlaceholder: Color(hex: 0x7C2D12),
            onAvatarPlaceholder: Color(hex: 0xFFEDD5),
            dateChip: Color(hex: 0x44403C),
            onDateChip: Color(hex: 0xE7E5E4),
            navigationBar: Color(hex: 0x7C2D12),
            onNavigationBar: Color(hex: 0xFFEDD5),
            accent: Color(hex: 0xFDBA74),
            onAccent: Color(hex: 0x431407)
        )
    )
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

#Preview {
    ContentView()
}
