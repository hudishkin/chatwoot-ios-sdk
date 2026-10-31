import Combine
import Foundation

final class GraphChatRepository: ChatRepository {
    let request: ChatRequest

    private let database: ChatwootDatabase
    private let syncManager: SyncManager
    private let sendQueue: SendQueue
    private let realtime: RealtimeController
    private let unreadTracker: UnreadTracker
    private let surveyRepository: SurveyRepository
    private let inboxId: Int

    private let conversationAttributes: [String: JSONValue]?

    private let conversationSubject = CurrentValueSubject<Int?, Never>(nil)
    private let messagesSubject = CurrentValueSubject<[MessageWithAttachments], Never>([])
    private let pendingSubject = CurrentValueSubject<[StoredPendingMessage], Never>([])
    private let connectionSubject = CurrentValueSubject<ConnectionBanner, Never>(.none)

    private var cancellables = Set<AnyCancellable>()

    init(
        stack: ChatwootCore.SessionStack,
        inboxId: Int,
        request: ChatRequest,
        transportAvailable: AnyPublisher<Bool, Never>,
        socketState: CurrentValueSubject<SocketConnectionState, Never>
    ) {
        self.request = request
        database = stack.database
        syncManager = stack.sync
        sendQueue = stack.sendQueue
        realtime = stack.realtime
        unreadTracker = stack.unreadTracker
        surveyRepository = stack.surveyRepository
        self.inboxId = inboxId
        conversationAttributes = request.conversationAttributes.isEmpty ? nil : request.conversationAttributes

        repoll()
        stack.database.changes.sink { [weak self] in self?.repoll() }.store(in: &cancellables)
        Publishers.CombineLatest4(
            transportAvailable,
            socketState,
            stack.realtime.failedHandshakes,
            stack.realtime.closedByServer
        )
        .map { connectionBanner(transportAvailable: $0, socket: $1, failedHandshakes: $2, closedByServer: $3) }
        .removeDuplicates()
        .subscribe(connectionSubject)
        .store(in: &cancellables)
    }

    private func repoll() {
        conversationSubject.send((try? database.conversations.summaries(inboxId: inboxId))?.first?.id)
        messagesSubject.send((try? database.messages.messagesOfInbox(inboxId: inboxId)) ?? [])
        pendingSubject.send((try? database.pending.pendingOfInbox(inboxId: inboxId)) ?? [])
    }

    var conversationId: AnyPublisher<Int?, Never> {
        conversationSubject.removeDuplicates().eraseToAnyPublisher()
    }

    func messages(conversationId: Int) -> AnyPublisher<[MessageWithAttachments], Never> {
        messagesSubject.eraseToAnyPublisher()
    }

    var pending: AnyPublisher<[StoredPendingMessage], Never> {
        pendingSubject.eraseToAnyPublisher()
    }

    var typing: AnyPublisher<[Int: Bool], Never> {
        realtime.typing.eraseToAnyPublisher()
    }

    var connection: AnyPublisher<ConnectionBanner, Never> {
        connectionSubject.eraseToAnyPublisher()
    }

    func sync() async {
        _ = await syncManager.sync(.refresh)
    }

    func catchUpWhileRealtimeDown() async {
        await realtime.catchUpWhileNotLive()
    }

    func sendText(_ text: String) async throws {
        await sendQueue.enqueueText(text, conversationAttributes: conversationAttributes)
    }

    func sendFile(url: URL, mime: String?) async -> Result<Void, ChatwootError> {
        await sendQueue.enqueueFile(url: url, mime: mime, conversationAttributes: conversationAttributes)
    }

    func retry(_ echoId: String) async {
        await sendQueue.retry(echoId)
    }

    func markShown(conversationId: Int, createdAt: Int) {
        Task { [unreadTracker] in
            await unreadTracker.onMessagesShown(conversationId: conversationId, lastCreatedAt: createdAt)
        }
    }

    func submitSurvey(conversationId: Int, messageId: Int, rating: Int, comment: String?) async -> SurveySubmitResult {
        await surveyRepository.submit(conversationId: conversationId, messageId: messageId, rating: rating, comment: comment)
    }
}
