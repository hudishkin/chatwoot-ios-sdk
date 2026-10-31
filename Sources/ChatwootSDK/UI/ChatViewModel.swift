import Combine
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var state: ChatUiState

    let effects = PassthroughSubject<ChatSideEffect, Never>()

    private let source: ChatRepository
    private let window: MessagesWindow
    private let bannerDelayMs: UInt64
    private let emptyWaitMs: UInt64

    private var tasks: [Task<Void, Never>] = []
    private var catchUp: Task<Void, Never>?
    private var currentConversation: Int?
    private var lastShownAt = Int.min
    private var firstSyncSettled = false {
        didSet { apply(window: window.state) }
    }

    init(
        source: ChatRepository,
        builder: ChatItemsBuilder,
        pageSize: Int = MessagesWindow.defaultPageSize,
        bannerDelayMs: UInt64 = ChatViewModel.bannerDelayMs,
        emptyWaitMs: UInt64 = ChatViewModel.emptyWaitMs
    ) {
        self.source = source
        self.window = MessagesWindow(builder: builder, pageSize: pageSize)
        self.bannerDelayMs = bannerDelayMs
        self.emptyWaitMs = emptyWaitMs
        state = ChatUiState(composer: source.request.initialMessage ?? "", title: source.request.title)

        let feed = source.conversationId.removeDuplicates()
            .map { [source] id -> AnyPublisher<FeedInput, Never> in
                let messages = id.map { source.messages(conversationId: $0) }
                    ?? Just([MessageWithAttachments]()).eraseToAnyPublisher()
                return Publishers.CombineLatest(messages, source.pending)
                    .map { FeedInput(messages: $0, pending: $1, conversationId: id) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
        tasks.append(Task { [weak self] in
            for await input in feed.values {
                self?.currentConversation = input.conversationId
                self?.applyFeed(input)
            }
        })

        tasks.append(Task { [weak self, typing = source.typing, conversationId = source.conversationId] in
            let stream = Publishers.CombineLatest(conversationId.removeDuplicates(), typing.removeDuplicates())
                .map { id, typingByConversation in id.flatMap { typingByConversation[$0] } == true }
                .values
            for await typing in stream {
                guard let self else { return }
                if typing != self.state.typing { self.state.typing = typing }
            }
        })

        tasks.append(Task { [weak self, connection = source.connection] in
            var pending: Task<Void, Never>?
            for await banner in connection.removeDuplicates().values {
                pending?.cancel()
                pending = Task { [weak self] in
                    guard let self else { return }
                    if banner != .none {
                        try? await Task.sleep(nanoseconds: self.bannerDelayMs * 1_000_000)
                        if Task.isCancelled { return }
                    }
                    self.state.connection = banner
                }
            }
            pending?.cancel()
        })

        tasks.append(Task { [weak self] in
            await self?.guarded("sync") { try await self?.source.sync() ?? () }
            self?.firstSyncSettled = true
        })
        tasks.append(Task { [weak self, emptyWaitMs] in
            try? await Task.sleep(nanoseconds: emptyWaitMs * 1_000_000)
            self?.firstSyncSettled = true
        })
    }

    func onScreenStarted() {
        guard catchUp == nil else { return }
        catchUp = Task { [weak self] in
            await self?.guarded("catch-up") { try await self?.source.catchUpWhileRealtimeDown() ?? () }
        }
    }

    func onScreenStopped() {
        catchUp?.cancel()
        catchUp = nil
    }

    func onComposerChanged(_ text: String) {
        state.composer = text
    }

    func onSend() {
        let text = state.composer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || state.sending { return }
        state.composer = ""
        state.sending = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await source.sendText(text)
                effects.send(.scrollToNewest)
            } catch {
                CWLog.w(.ui, "send failed \(type(of: error))")
                if state.composer.isEmpty { state.composer = text }
                effects.send(.showError(.sendFailed))
            }
            state.sending = false
        }
    }

    func onRetry(_ echoId: String) {
        Task { [weak self] in
            await self?.guarded("retry") { try await self?.source.retry(echoId) ?? () }
        }
    }

    func onVisibleRange(first: Int, last: Int) {
        guard let id = currentConversation else { return }
        let items = state.items
        guard !items.isEmpty, first <= last else { return }
        let newest = (max(first, 0)...min(last, items.count - 1))
            .compactMap { items[$0].serverCreatedAt }
            .max()
        guard let newest, newest > lastShownAt else { return }
        lastShownAt = newest
        source.markShown(conversationId: id, createdAt: newest)
    }

    func onLoadOlder() {
        if state.hasOlder { window.loadOlder() }
        apply(window: window.state)
    }

    func onAttachmentPicked(url: URL?, mime: String?, afterQueued: @escaping () -> Void = {}) {
        guard let url else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await source.sendFile(url: url, mime: mime)
            afterQueued()
            switch result {
            case .success:
                effects.send(.scrollToNewest)
            case .failure(.tooLarge):
                effects.send(.showError(.attachTooLarge))
            case .failure:
                effects.send(.showError(.attachFailed))
            }
        }
    }

    func onAttachmentOpen(_ attachment: AttachmentUi) {
        if !attachment.isLocal { effects.send(.openFile(attachment.source)) }
    }

    func onSurveyRating(messageId: Int, rating: Int) {
        guard (1...surveyMaxRating).contains(rating) else { return }
        updateSurvey(messageId) { draft in
            guard draft.editable else { return }
            draft.rating = rating
            draft.phase = .idle
        }
    }

    func onSurveyComment(messageId: Int, text: String) {
        updateSurvey(messageId) { draft in
            guard draft.editable else { return }
            draft.comment = text
        }
    }

    func onSurveyAddComment(messageId: Int) {
        updateSurvey(messageId) { draft in
            guard draft.editable else { return }
            draft.commentRequested = true
        }
    }

    func onSurveySend(conversationId: Int, messageId: Int) {
        guard let draft = state.surveys[messageId], let rating = draft.rating, draft.editable else { return }
        updateSurvey(messageId) { $0.phase = .sending }
        let comment = draft.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self else { return }
            let result = await source.submitSurvey(
                conversationId: conversationId, messageId: messageId,
                rating: rating, comment: comment.isEmpty ? nil : comment
            )
            let phase: SurveyPhase
            switch result {
            case .sent: phase = .sent
            case .closed: phase = .closed
            case .failed: phase = .failed
            }
            CWLog.i(.ui, "survey message=\(messageId) phase=\(phase)")
            updateSurvey(messageId) { $0.phase = phase }
        }
    }

    private func updateSurvey(_ messageId: Int, _ change: (inout SurveyDraft) -> Void) {
        var draft = state.surveys[messageId] ?? SurveyDraft()
        change(&draft)
        state.surveys[messageId] = draft
    }

    private func applyFeed(_ input: FeedInput) {
        apply(window: window.update(with: input))
    }

    private func apply(window windowState: MessagesWindow.State) {
        var next = state
        next.items = windowState.items
        next.hasOlder = windowState.hasOlder
        next.isLoading = windowState.isLoading || (windowState.items.isEmpty && !firstSyncSettled)
        if next != state { state = next }
    }

    private func guarded(_ step: String, _ block: () async throws -> Void) async {
        do {
            try await block()
        } catch {
            CWLog.w(.ui, "\(step) failed \(type(of: error))")
        }
    }

    deinit {
        tasks.forEach { $0.cancel() }
        catchUp?.cancel()
    }

    nonisolated static let bannerDelayMs: UInt64 = 1_500
    nonisolated static let emptyWaitMs: UInt64 = 1_000
}
