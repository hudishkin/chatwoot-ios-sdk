import ChatwootSDK
import SwiftUI

struct ContentView: View {
    @State private var showChat = false
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Chatwoot SDK Example")
                .font(.headline)
            Text("SDK version: \(ChatwootSDK.version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
                Chatwoot.chatView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") { showChat = false }
                        }
                    }
            }
            .navigationViewStyle(.stack)
        }
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

#Preview {
    ContentView()
}
