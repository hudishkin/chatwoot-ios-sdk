import Combine
import Foundation

protocol ChatRepository {
    var request: ChatRequest { get }

    var conversationId: AnyPublisher<Int?, Never> { get }

    func messages(conversationId: Int) -> AnyPublisher<[MessageWithAttachments], Never>

    var pending: AnyPublisher<[StoredPendingMessage], Never> { get }

    var typing: AnyPublisher<[Int: Bool], Never> { get }

    var connection: AnyPublisher<ConnectionBanner, Never> { get }

    func sync() async

    func catchUpWhileRealtimeDown() async

    func sendText(_ text: String) async throws

    func sendFile(url: URL, mime: String?) async -> Result<Void, ChatwootError>

    func retry(_ echoId: String) async

    func markShown(conversationId: Int, createdAt: Int)

    func submitSurvey(conversationId: Int, messageId: Int, rating: Int, comment: String?) async -> SurveySubmitResult
}

struct ChatUiState: Equatable {
    var items: [ChatItem] = []
    var composer = ""
    var sending = false
    var typing = false
    var connection: ConnectionBanner = .none
    var isLoading = true
    var hasOlder = false
    var title: String?
    var surveys: [Int: SurveyDraft] = [:]
}

enum SurveyPhase: Equatable {
    case idle, sending, sent, failed, closed
}

struct SurveyDraft: Equatable {
    var rating: Int?
    var comment = ""
    var phase: SurveyPhase = .idle
    var commentRequested = false

    var commentExpanded: Bool {
        guard let rating else { return false }
        return rating <= surveyCommentThreshold || commentRequested || !comment.isEmpty
    }

    var editable: Bool { phase == .idle || phase == .failed }
}

let surveyCommentThreshold = 3

let surveyMaxRating = 5

enum ChatSideEffect: Equatable {
    case showError(ChatErrorKind)
    case openFile(String)
    case scrollToNewest
}

enum ChatErrorKind: Equatable {
    case sendFailed
    case attachTooLarge
    case attachFailed
}
