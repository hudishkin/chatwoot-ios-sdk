import Combine
import XCTest
@testable import ChatwootSDK

@MainActor
final class ChatViewModelTests: XCTestCase {
    private let surveyMessageId = 42

    private func makeViewModel(
        _ source: FakeChatRepository,
        bannerDelayMs: UInt64 = ChatViewModel.bannerDelayMs,
        emptyWaitMs: UInt64 = ChatViewModel.emptyWaitMs
    ) -> ChatViewModel {
        ChatViewModel(
            source: source,
            builder: ChatItemsBuilder(zone: TimeZone(identifier: "UTC")!) { UInt64(feedNoon) * 1000 },
            bannerDelayMs: bannerDelayMs,
            emptyWaitMs: emptyWaitMs
        )
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "условие не наступило за 2с", file: file, line: line)
    }

    private func settle(ms: UInt64 = 120) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    func testItemsFromDbAppearWithoutNetworkWait() async {
        let source = FakeChatRepository()
        source.slowSync = true
        source.messagesSubject.send([feedMine(1), feedAgent(2)])
        source.conversationSubject.send(feedConversation)
        let vm = makeViewModel(source)

        await eventually {
            vm.state.items.map(\.key).contains("m:2") && !vm.state.isLoading
        }

        XCTAssertEqual(Array(vm.state.items.map(\.key).prefix(2)), ["m:2", "m:1"])
        XCTAssertFalse(source.syncSettled)
    }

    func testEmptyDbAndSlowSyncShowsLoadingUntilWaitEndsThenEmpty() async {
        let source = FakeChatRepository()
        source.slowSync = true
        let vm = makeViewModel(source, emptyWaitMs: 500)

        await settle(ms: 20)
        XCTAssertTrue(vm.state.isLoading)

        await eventually { !vm.state.isLoading }
        XCTAssertTrue(vm.state.items.isEmpty)
    }

    func testSendEnqueuesTextAndClearsComposer() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source)
        vm.onComposerChanged("  Hello  ")

        vm.onSend()
        await eventually { source.sentTexts.count == 1 }

        XCTAssertEqual(source.sentTexts, ["Hello"])
        XCTAssertEqual(vm.state.composer, "")
        XCTAssertFalse(vm.state.sending)
    }

    func testBlankTextSendsNothing() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source)
        vm.onComposerChanged("   ")

        vm.onSend()
        await settle()

        XCTAssertTrue(source.sentTexts.isEmpty)
    }

    func testInitialMessageAndTitlePrefill() async {
        let source = FakeChatRepository(request: ChatRequest(initialMessage: "About my bill", title: "Billing"))
        let vm = makeViewModel(source)

        XCTAssertEqual(vm.state.composer, "About my bill")
        XCTAssertEqual(vm.state.title, "Billing")
    }

    func testFailedItemRetriesThroughTheQueue() async {
        let source = FakeChatRepository()
        source.pendingSubject.send([feedPending("e1", state: .failed)])
        source.conversationSubject.send(feedConversation)
        let vm = makeViewModel(source)
        await eventually {
            vm.state.items.contains { item in
                guard case .mine(let mine) = item else { return false }
                return mine.status == .failed
            }
        }
        guard case .mine(let failed) = vm.state.items.first(where: {
            if case .mine = $0 { return true }
            return false
        }) else {
            return XCTFail("ожидалась своя строка из очереди")
        }

        vm.onRetry(failed.echoId ?? "")
        await eventually { source.retries.count == 1 }

        XCTAssertEqual(source.retries, ["e1"])
    }

    func testSettledScrollMarksShownOnlyOnce() async {
        let source = FakeChatRepository()
        source.messagesSubject.send([
            feedAgent(1, at: feedNoon + 10),
            feedAgent(2, at: feedNoon + 20),
            feedAgent(3, at: feedNoon + 30),
        ])
        source.pendingSubject.send([feedPending("e1", at: feedNoon + 40)])
        source.conversationSubject.send(feedConversation)
        let vm = makeViewModel(source)
        await eventually { vm.state.items.count >= 4 }

        vm.onVisibleRange(first: 0, last: 2)
        vm.onVisibleRange(first: 0, last: 2)

        XCTAssertEqual(source.shown.count, 1)
        XCTAssertEqual(source.shown.first?.0, feedConversation)
        XCTAssertEqual(source.shown.first?.1, feedNoon + 30)
    }

    func testOlderVisibleItemsNeverMoveSeenBack() async {
        let source = FakeChatRepository()
        source.messagesSubject.send([
            feedAgent(1, at: feedNoon + 10),
            feedAgent(2, at: feedNoon + 20),
            feedAgent(3, at: feedNoon + 30),
        ])
        source.conversationSubject.send(feedConversation)
        let vm = makeViewModel(source)
        await eventually { vm.state.items.count >= 3 }

        vm.onVisibleRange(first: 0, last: 0)
        vm.onVisibleRange(first: 2, last: 3)

        XCTAssertEqual(source.shown.count, 1)
        XCTAssertEqual(source.shown.first?.1, feedNoon + 30)
    }

    func testTemplateMessageBecomesSystemItem() async {
        let source = FakeChatRepository()
        source.messagesSubject.send([feedTemplate(1)])
        source.conversationSubject.send(feedConversation)
        let vm = makeViewModel(source)

        await eventually {
            if case .system = vm.state.items.first { return true }
            return false
        }
    }

    func testDeletedMessageBecomesPlaceholder() async {
        let source = FakeChatRepository()
        source.messagesSubject.send([feedAgent(1, text: "secret", deleted: true)])
        source.conversationSubject.send(feedConversation)
        let vm = makeViewModel(source)

        await eventually {
            vm.state.items.contains { item in
                guard case .theirs(let theirs) = item else { return false }
                return theirs.deleted
            }
        }
        guard case .theirs(let theirs) = vm.state.items.first(where: {
            if case .theirs = $0 { return true }
            return false
        }) else {
            return XCTFail("ожидалась строка агента")
        }
        XCTAssertTrue(theirs.deleted)
        XCTAssertNil(theirs.text)
    }

    func testTypingOnlyForTheShownConversation() async {
        let source = FakeChatRepository()
        source.conversationSubject.send(feedConversation)
        let vm = makeViewModel(source)

        source.typingSubject.send([feedConversation: true])
        await eventually { vm.state.typing }

        source.typingSubject.send([feedConversation + 1: true])
        await eventually { !vm.state.typing }
    }

    func testBriefOfflineBeforeDelayShowsNoBanner() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source, bannerDelayMs: 150)

        source.connectionSubject.send(.offline)
        await settle(ms: 60)
        source.connectionSubject.send(.none)
        await settle(ms: 250)

        XCTAssertEqual(vm.state.connection, .none)
    }

    func testNoPeriodicCatchUpUntilScreenStarts() async {
        let source = FakeChatRepository()
        _ = makeViewModel(source)
        await settle()

        XCTAssertEqual(source.catchUpRuns, 0)
    }

    func testCatchUpFollowsScreenLifecycle() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source)

        vm.onScreenStarted()
        vm.onScreenStarted()
        await eventually { source.catchUpRuns == 1 }
        await eventually { source.catchUpActive }

        vm.onScreenStopped()
        await eventually { !source.catchUpActive }

        vm.onScreenStarted()
        await eventually { source.catchUpRuns == 2 }
        vm.onScreenStopped()
    }

    func testLiveUpdatesUnavailableBannerAfterDelay() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source, bannerDelayMs: 40)

        source.connectionSubject.send(.liveUpdatesUnavailable)
        await eventually { vm.state.connection == .liveUpdatesUnavailable }
    }

    func testOfflineBannerAfterDelay() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source, bannerDelayMs: 40)

        source.connectionSubject.send(.offline)
        await eventually { vm.state.connection == .offline }
    }

    func testTooLargeFileShowsError() async {
        let source = FakeChatRepository()
        source.fileResult = .failure(.tooLarge)
        let vm = makeViewModel(source)
        var effects: [ChatSideEffect] = []
        let cancellable = vm.effects.sink { effects.append($0) }
        defer { cancellable.cancel() }
        let url = URL(fileURLWithPath: "/tmp/report.pdf")

        vm.onAttachmentPicked(url: url, mime: "application/pdf")
        await eventually { !effects.isEmpty }

        XCTAssertEqual(source.sentFiles.count, 1)
        XCTAssertEqual(source.sentFiles.first?.1, "application/pdf")
        XCTAssertEqual(effects.first, .showError(.attachTooLarge))
    }

    func testAfterQueuedRunsForAcceptedAndRejectedFiles() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source)
        var done = 0
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")

        vm.onAttachmentPicked(url: url, mime: "image/jpeg") { done += 1 }
        await eventually { done == 1 }
        source.fileResult = .failure(.unreadable)
        vm.onAttachmentPicked(url: url, mime: "image/jpeg") { done += 1 }
        await eventually { done == 2 }
    }

    func testAttachFailedEmitsError() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source)
        var effects: [ChatSideEffect] = []
        let cancellable = vm.effects.sink { effects.append($0) }
        defer { cancellable.cancel() }

        vm.onAttachFailed()

        XCTAssertEqual(effects, [.showError(.attachFailed)])
    }

    func testRemoteAttachmentOpenEmitsOpenFile() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source)
        var effects: [ChatSideEffect] = []
        let cancellable = vm.effects.sink { effects.append($0) }
        defer { cancellable.cancel() }
        let remote = AttachmentUi(
            source: "https://chat.example.com/f.pdf", isLocal: false, isImage: false,
            thumbnail: nil, name: "f.pdf", sizeBytes: 1, width: nil, height: nil
        )

        vm.onAttachmentOpen(remote)
        await eventually { !effects.isEmpty }

        XCTAssertEqual(effects.first, .openFile("https://chat.example.com/f.pdf"))
    }

    func testLoadOlderAddsItems() async {
        let source = FakeChatRepository()
        source.messagesSubject.send((1...80).map { feedAgent($0) })
        source.conversationSubject.send(feedConversation)
        let vm = makeViewModel(source)
        await eventually { !vm.state.items.isEmpty && vm.state.hasOlder }
        let before = vm.state.items.count

        vm.onLoadOlder()

        XCTAssertGreaterThan(vm.state.items.count, before)
    }

    func testLowRatingExpandsComment() async {
        let vm = makeViewModel(FakeChatRepository())

        vm.onSurveyRating(messageId: surveyMessageId, rating: 2)

        let draft = vm.state.surveys[surveyMessageId]
        XCTAssertEqual(draft?.rating, 2)
        XCTAssertEqual(draft?.commentExpanded, true)
    }

    func testHighRatingKeepsCommentCollapsedUntilRequested() async {
        let vm = makeViewModel(FakeChatRepository())

        vm.onSurveyRating(messageId: surveyMessageId, rating: 5)
        XCTAssertEqual(vm.state.surveys[surveyMessageId]?.commentExpanded, false)

        vm.onSurveyAddComment(messageId: surveyMessageId)
        XCTAssertEqual(vm.state.surveys[surveyMessageId]?.commentExpanded, true)
    }

    func testSurveySendSubmitsTrimmedCommentAndSetsSentPhase() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source)
        vm.onSurveyRating(messageId: surveyMessageId, rating: 3)
        vm.onSurveyComment(messageId: surveyMessageId, text: "  slow reply  ")

        vm.onSurveySend(conversationId: feedConversation, messageId: surveyMessageId)
        XCTAssertEqual(vm.state.surveys[surveyMessageId]?.phase, .sending)
        await eventually { !source.surveyCalls.isEmpty }

        XCTAssertEqual(source.surveyCalls, [
            FakeChatRepository.SurveyCall(conversationId: feedConversation, messageId: surveyMessageId, rating: 3, comment: "slow reply"),
        ])
        await eventually { vm.state.surveys[self.surveyMessageId]?.phase == .sent }
    }

    func testBlankCommentBecomesNil() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source)
        vm.onSurveyRating(messageId: surveyMessageId, rating: 5)
        vm.onSurveyComment(messageId: surveyMessageId, text: "   ")

        vm.onSurveySend(conversationId: feedConversation, messageId: surveyMessageId)
        await eventually { !source.surveyCalls.isEmpty }

        XCTAssertNil(source.surveyCalls.first?.comment)
    }

    func testNoRatingSubmitsNothing() async {
        let source = FakeChatRepository()
        let vm = makeViewModel(source)

        vm.onSurveySend(conversationId: feedConversation, messageId: surveyMessageId)
        await settle()

        XCTAssertTrue(source.surveyCalls.isEmpty)
    }

    func testClosedResultSetsClosedPhaseAndBlocksChanges() async {
        let source = FakeChatRepository()
        source.surveyResult = .closed
        let vm = makeViewModel(source)
        vm.onSurveyRating(messageId: surveyMessageId, rating: 4)

        vm.onSurveySend(conversationId: feedConversation, messageId: surveyMessageId)
        await eventually { vm.state.surveys[self.surveyMessageId]?.phase == .closed }

        vm.onSurveyRating(messageId: surveyMessageId, rating: 2)
        vm.onSurveySend(conversationId: feedConversation, messageId: surveyMessageId)
        await settle()

        XCTAssertEqual(source.surveyCalls.count, 1)
    }

    func testFailedResultAllowsRetryResend() async {
        let source = FakeChatRepository()
        source.surveyResult = .failed
        let vm = makeViewModel(source)
        vm.onSurveyRating(messageId: surveyMessageId, rating: 1)
        vm.onSurveyComment(messageId: surveyMessageId, text: "late")

        vm.onSurveySend(conversationId: feedConversation, messageId: surveyMessageId)
        await eventually { vm.state.surveys[self.surveyMessageId]?.phase == .failed }

        source.surveyResult = .sent
        vm.onSurveySend(conversationId: feedConversation, messageId: surveyMessageId)
        await eventually { source.surveyCalls.count == 2 }

        XCTAssertEqual(source.surveyCalls.map { "\($0.rating):\($0.comment ?? "")" }, ["1:late", "1:late"])
        await eventually { vm.state.surveys[self.surveyMessageId]?.phase == .sent }
    }

    func testSendingIgnoresRatingChangeAndSecondSend() async {
        let source = FakeChatRepository()
        source.surveyGates = true
        let vm = makeViewModel(source)
        vm.onSurveyRating(messageId: surveyMessageId, rating: 2)

        vm.onSurveySend(conversationId: feedConversation, messageId: surveyMessageId)
        await eventually { source.surveyCalls.count == 1 }

        vm.onSurveyRating(messageId: surveyMessageId, rating: 5)
        vm.onSurveySend(conversationId: feedConversation, messageId: surveyMessageId)
        await settle()

        XCTAssertEqual(vm.state.surveys[surveyMessageId]?.rating, 2)
        XCTAssertEqual(source.surveyCalls.count, 1)
        source.resumeSurveyCalls()
        await eventually { vm.state.surveys[self.surveyMessageId]?.phase == .sent }
    }
}

final class FakeChatRepository: ChatRepository {
    let request: ChatRequest

    let conversationSubject = CurrentValueSubject<Int?, Never>(nil)
    let messagesSubject = CurrentValueSubject<[MessageWithAttachments], Never>([])
    let pendingSubject = CurrentValueSubject<[StoredPendingMessage], Never>([])
    let typingSubject = CurrentValueSubject<[Int: Bool], Never>([:])
    let connectionSubject = CurrentValueSubject<ConnectionBanner, Never>(.none)

    private(set) var sentTexts: [String] = []
    private(set) var retries: [String] = []
    private(set) var shown: [(Int, Int)] = []
    struct SurveyCall: Equatable {
        let conversationId: Int
        let messageId: Int
        let rating: Int
        let comment: String?
    }
    private(set) var surveyCalls: [SurveyCall] = []
    var surveyResult: SurveySubmitResult = .sent
    private(set) var sentFiles: [(URL, String?)] = []
    var fileResult: Result<Void, ChatwootError> = .success(())
    private(set) var syncCalls = 0
    var slowSync = false
    private var syncContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var syncSettled = false
    private(set) var catchUpRuns = 0
    private(set) var catchUpActive = false
    var surveyGates = false
    private var surveyContinuations: [CheckedContinuation<Void, Never>] = []

    init(request: ChatRequest = .default) {
        self.request = request
    }

    var conversationId: AnyPublisher<Int?, Never> { conversationSubject.eraseToAnyPublisher() }
    func messages(conversationId: Int) -> AnyPublisher<[MessageWithAttachments], Never> {
        messagesSubject.eraseToAnyPublisher()
    }
    var pending: AnyPublisher<[StoredPendingMessage], Never> { pendingSubject.eraseToAnyPublisher() }
    var typing: AnyPublisher<[Int: Bool], Never> { typingSubject.eraseToAnyPublisher() }
    var connection: AnyPublisher<ConnectionBanner, Never> { connectionSubject.eraseToAnyPublisher() }

    func sync() async {
        syncCalls += 1
        if slowSync {
            await withCheckedContinuation { continuation in
                syncContinuations.append(continuation)
            }
        }
        syncSettled = true
    }

    func catchUpWhileRealtimeDown() async {
        catchUpRuns += 1
        catchUpActive = true
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        catchUpActive = false
    }

    func sendText(_ text: String) async throws {
        sentTexts.append(text)
    }

    func sendFile(url: URL, mime: String?) async -> Result<Void, ChatwootError> {
        sentFiles.append((url, mime))
        return fileResult
    }

    func retry(_ echoId: String) async {
        retries.append(echoId)
    }

    func markShown(conversationId: Int, createdAt: Int) {
        shown.append((conversationId, createdAt))
    }

    func submitSurvey(conversationId: Int, messageId: Int, rating: Int, comment: String?) async -> SurveySubmitResult {
        surveyCalls.append(SurveyCall(conversationId: conversationId, messageId: messageId, rating: rating, comment: comment))
        if surveyGates {
            await withCheckedContinuation { continuation in
                surveyContinuations.append(continuation)
            }
        }
        return surveyResult
    }

    func resumeSurveyCalls() {
        let continuations = surveyContinuations
        surveyContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
