import SwiftUI

extension Chatwoot {
    /// Ready-made chat screen with the given theme; the screen assembles once the
    /// session is identified (until then it shows a loading indicator).
    public static func chatView(
        request: ChatRequest = .default,
        theme: ChatwootTheme = .default
    ) -> ChatwootChatView {
        ChatwootChatView(request: request, theme: theme)
    }
}

/// Ready-made conversation screen. Embed it into the host's `NavigationStack` —
/// the host owns the title bar and the back button; the SDK only sets
/// [ChatRequest.title] as `.navigationTitle`.
///
/// ```swift
/// NavigationStack { Chatwoot.chatView() }
/// ```
public struct ChatwootChatView: View {
    private let request: ChatRequest
    private let theme: ChatwootTheme

    public init(request: ChatRequest = .default, theme: ChatwootTheme = .default) {
        self.request = request
        self.theme = theme
    }

    @Environment(\.colorScheme) private var systemScheme

    public var body: some View {
        let resolved = theme.resolve(systemDark: systemScheme == .dark)
        ChatwootChatContent(request: request)
            .environment(\.chatColors, resolved.colors)
            .environment(\.colorScheme, resolved.dark ? .dark : .light)
    }
}

private struct ChatwootChatContent: View {
    let request: ChatRequest

    @State private var repository: ChatRepository?

    var body: some View {
        Group {
            if let repository {
                ChatScreen(repository: repository)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if repository == nil {
                repository = await Chatwoot.core?.makeChatRepository(request: request)
            }
        }
    }
}

private struct ChatScreen: View {
    @StateObject private var viewModel: ChatViewModel

    init(repository: ChatRepository) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(
            source: repository,
            builder: ChatItemsBuilder(zone: .current, nowMs: { UInt64(Date().timeIntervalSince1970 * 1000) })
        ))
    }

    @Environment(\.chatColors) private var colors
    @Environment(\.openURL) private var openURL

    private let format = ChatFormat()

    @State private var seenKey: String?
    @State private var previousNewestKey: String?
    @State private var snackbar: String?
    @State private var snackbarTask: Task<Void, Never>?

    private static let loadAhead = 10
    private static let snackbarSeconds: UInt64 = 3
    private static let feedAnimation = Animation.easeOut(duration: 0.2)

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBannerBar(state: viewModel.state.connection)
            ZStack(alignment: .bottomTrailing) {
                feed
                let unseen = viewModel.state.items.unseenAgentRows(seenKey: seenKey)
                if unseen > 0 {
                    NewMessagesChip(count: unseen) {
                        scrollProxy?.scrollTo(viewModel.state.items.newestMessageKey(), anchor: .top)
                        seenKey = viewModel.state.items.newestMessageKey()
                    }
                    .padding(16)
                    .transition(.opacity)
                }
            }
            ComposerCell(
                text: Binding(
                    get: { viewModel.state.composer },
                    set: { viewModel.onComposerChanged($0) }
                ),
                sending: viewModel.state.sending,
                onSend: viewModel.onSend,
                attachmentMenu: viewModel.attachmentMenu,
                onAttachmentPicked: { url, mime, cleanup in
                    viewModel.onAttachmentPicked(url: url, mime: mime, afterQueued: cleanup)
                },
                onAttachFailed: viewModel.onAttachFailed
            )
        }
        .background {
            colors.chatBackground.ignoresSafeArea(edges: .bottom)
        }
        .navigationTitle(viewModel.state.title ?? ChatStrings.chatTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .bottom) { snackbarView }
        .onAppear { viewModel.onScreenStarted() }
        .onDisappear { viewModel.onScreenStopped() }
        .onReceive(viewModel.effects) { effect in
            switch effect {
            case .scrollToNewest:
                scrollProxy?.scrollTo(viewModel.state.items.newestMessageKey(), anchor: .top)
            case .openFile(let source):
                if let url = URL(string: source) { openURL(url) }
            case .showError(let kind):
                showSnackbar(text(for: kind))
            }
        }
        .onChange(of: viewModel.state.items.newestMessageKey()) { newKey in
            if let newKey, seenKey == previousNewestKey, previousNewestKey != nil {
                scrollProxy?.scrollTo(newKey, anchor: .top)
                seenKey = newKey
            }
            previousNewestKey = newKey
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.state.items.unseenAgentRows(seenKey: seenKey) > 0)
        .animation(.easeInOut(duration: 0.2), value: viewModel.state.connection)
    }

    @State private var scrollProxy: ScrollViewProxy?

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.state.typing {
                        TypingIndicator()
                            .rotationEffect(.degrees(180))
                            .id("typing")
                            .transition(.opacity)
                    }
                    ForEach(Array(viewModel.state.items.enumerated()), id: \.element.key) { index, item in
                        row(for: item)
                            .rotationEffect(.degrees(180))
                            .id(item.key)
                            .onAppear {
                                viewModel.onVisibleRange(first: index, last: index)
                                if index == 0, seenKey == nil || seenKey == previousNewestKey {
                                    seenKey = item.key
                                }
                                if index >= viewModel.state.items.count - ChatScreen.loadAhead {
                                    viewModel.onLoadOlder()
                                }
                            }
                    }
                }
                .padding(.horizontal, Spacing.listInset)
                .padding(.vertical, 8)
                .animation(ChatScreen.feedAnimation, value: viewModel.state.items)
                .animation(ChatScreen.feedAnimation, value: viewModel.state.typing)
            }
            .rotationEffect(.degrees(180))
            .onAppear { scrollProxy = proxy }
        }
        .overlay {
            if viewModel.state.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.state.items.isEmpty {
                EmptyState()
            }
        }
    }

    @ViewBuilder
    private func row(for item: ChatItem) -> some View {
        let maxWidth = Spacing.bubbleMaxWidth
        switch item {
        case .mine(let mine):
            mineRow(mine, maxWidth: maxWidth)
        case .theirs(let theirs):
            theirsRow(theirs, maxWidth: maxWidth)
        case .system(let system):
            SystemCell(text: system.text)
        case .survey(let survey):
            SurveyCell(
                item: survey,
                draft: viewModel.state.surveys[survey.messageId],
                callbacks: SurveyCallbacks(
                    onRate: { viewModel.onSurveyRating(messageId: survey.messageId, rating: $0) },
                    onComment: { viewModel.onSurveyComment(messageId: survey.messageId, text: $0) },
                    onAddComment: { viewModel.onSurveyAddComment(messageId: survey.messageId) },
                    onSend: {
                        viewModel.onSurveySend(conversationId: survey.conversationId, messageId: survey.messageId)
                    }
                )
            )
        case .dateHeader(let header):
            DateHeaderCell(item: header, format: format)
        }
    }

    @ViewBuilder
    private func mineRow(_ item: ChatItem.Mine, maxWidth: CGFloat) -> some View {
        let time = format.time(item.createdAt)
        VStack(alignment: .trailing, spacing: 0) {
            if let attachment = item.attachment {
                if attachment.isImage {
                    ImageAttachmentCell(
                        mine: true,
                        attachment: attachment,
                        caption: item.deleted ? nil : item.text,
                        run: item.run,
                        time: time,
                        showMeta: item.showMeta,
                        status: item.deleted ? nil : item.status,
                        maxWidth: maxWidth,
                        onOpen: { viewModel.onAttachmentOpen(attachment) },
                        onCopy: { PlatformClipboard.copy($0) },
                        description: attachmentDescription(
                            mine: true, attachment: attachment, text: item.text,
                            time: time, deleted: item.deleted, status: item.status
                        )
                    )
                    .padding(.bottom, runGap(item.run))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    FileAttachmentCell(
                        mine: true,
                        attachment: attachment,
                        caption: item.deleted ? nil : item.text,
                        run: item.run,
                        time: time,
                        showMeta: item.showMeta,
                        status: item.deleted ? nil : item.status,
                        maxWidth: maxWidth,
                        format: format,
                        onOpen: { viewModel.onAttachmentOpen(attachment) },
                        onCopy: { PlatformClipboard.copy($0) },
                        description: attachmentDescription(
                            mine: true, attachment: attachment, text: item.text,
                            time: time, deleted: item.deleted, status: item.status
                        )
                    )
                    .padding(.bottom, runGap(item.run))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                OwnTextCell(
                    item: item,
                    time: time,
                    maxWidth: maxWidth,
                    onCopy: { PlatformClipboard.copy($0) },
                    onRetry: { viewModel.onRetry($0) }
                )
            }
            if item.status == .failed, let echoId = item.echoId {
                FailedState(onRetry: { viewModel.onRetry(echoId) })
            }
        }
    }

    @ViewBuilder
    private func theirsRow(_ item: ChatItem.Theirs, maxWidth: CGFloat) -> some View {
        let time = format.time(item.createdAt)
        if let attachment = item.attachment {
            if attachment.isImage {
                AgentRow(item: item) {
                    ImageAttachmentCell(
                        mine: false,
                        attachment: attachment,
                        caption: item.deleted ? nil : item.text,
                        run: item.run,
                        time: time,
                        showMeta: item.showMeta,
                        status: nil,
                        maxWidth: maxWidth,
                        onOpen: { viewModel.onAttachmentOpen(attachment) },
                        onCopy: { PlatformClipboard.copy($0) },
                        description: attachmentDescription(
                            mine: false, attachment: attachment, text: item.text,
                            time: time, deleted: item.deleted, status: nil, senderName: item.senderName
                        )
                    )
                }
            } else {
                AgentRow(item: item) {
                    FileAttachmentCell(
                        mine: false,
                        attachment: attachment,
                        caption: item.deleted ? nil : item.text,
                        run: item.run,
                        time: time,
                        showMeta: item.showMeta,
                        status: nil,
                        maxWidth: maxWidth,
                        format: format,
                        onOpen: { viewModel.onAttachmentOpen(attachment) },
                        onCopy: { PlatformClipboard.copy($0) },
                        description: attachmentDescription(
                            mine: false, attachment: attachment, text: item.text,
                            time: time, deleted: item.deleted, status: nil, senderName: item.senderName
                        )
                    )
                }
            }
        } else {
            AgentTextCell(
                item: item,
                time: time,
                maxWidth: maxWidth,
                onCopy: { PlatformClipboard.copy($0) }
            )
        }
    }

    private func attachmentDescription(
        mine: Bool,
        attachment: AttachmentUi,
        text: String?,
        time: String,
        deleted: Bool,
        status: SendStatus?,
        senderName: String? = nil
    ) -> String {
        let who: String
        if mine {
            let state: String
            switch status ?? .sent {
            case .sending: state = ChatStrings.sendingStatus
            case .sent: state = ChatStrings.sentStatus
            case .failed: state = ChatStrings.failed
            }
            who = "\(ChatStrings.you), \(time), \(state)"
        } else if let senderName, !senderName.trimmingCharacters(in: .whitespaces).isEmpty {
            who = "\(ChatStrings.agent(senderName)), \(time)"
        } else {
            who = "\(ChatStrings.agentUnnamed), \(time)"
        }
        if deleted {
            return "\(who): \(ChatStrings.messageDeleted)"
        }
        let kind = attachment.isImage ? ChatStrings.image : ChatStrings.file(attachment.name)
        if let text, !text.isEmpty {
            return "\(who): \(kind), \(text)"
        }
        return "\(who): \(kind)"
    }

    private func text(for kind: ChatErrorKind) -> String {
        switch kind {
        case .sendFailed: return ChatStrings.sendFailed
        case .attachTooLarge: return ChatStrings.attachTooLarge
        case .attachFailed: return ChatStrings.attachFailed
        }
    }

    private func showSnackbar(_ text: String) {
        snackbarTask?.cancel()
        snackbar = text
        snackbarTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ChatScreen.snackbarSeconds * 1_000_000_000)
            if !Task.isCancelled { snackbar = nil }
        }
    }

    @ViewBuilder
    private var snackbarView: some View {
        ZStack {
            if let snackbar {
                Text(snackbar)
                    .font(.subheadline)
                    .foregroundColor(colors.scheme.onSurface)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(colors.scheme.surfaceVariant)
                    .clipShape(Capsule())
                    .shadow(radius: 2, y: 1)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: snackbar)
    }
}
