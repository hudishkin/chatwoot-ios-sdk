import Combine
import Foundation

enum SurveySubmitResult: Equatable {
    case sent
    case closed
    case failed
}

struct SurveySubmission: Equatable {
    let conversationId: Int
    let messageId: Int
    let rating: Int
}

actor SurveyRepository {
    nonisolated let responses = PassthroughSubject<SurveySubmission, Never>()

    private let api: ChatwootAPI
    private let inboxIdentifier: String
    private let store: SessionStore
    private let messageDAO: MessageDAO
    private let sync: SyncManager
    private let sessionGuard: SessionGuard

    private var inFlight: [Int: [CheckedContinuation<SurveySubmitResult, Never>]] = [:]

    init(
        api: ChatwootAPI,
        inboxIdentifier: String,
        store: SessionStore,
        messageDAO: MessageDAO,
        sync: SyncManager,
        sessionGuard: SessionGuard
    ) {
        self.api = api
        self.inboxIdentifier = inboxIdentifier
        self.store = store
        self.messageDAO = messageDAO
        self.sync = sync
        self.sessionGuard = sessionGuard
    }

    func submit(conversationId: Int, messageId: Int, rating: Int, comment: String?) async -> SurveySubmitResult {
        guard (Self.minRating...Self.maxRating).contains(rating) else {
            CWLog.w(.send, "survey answer rejected: rating out of range")
            return .failed
        }
        if inFlight[messageId] != nil {
            return await withCheckedContinuation { continuation in
                inFlight[messageId, default: []].append(continuation)
            }
        }
        inFlight[messageId] = []
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await send(conversationId: conversationId, messageId: messageId, rating: rating,
                                feedback: trimmed?.isEmpty == true ? nil : trimmed)
        let waiters = inFlight.removeValue(forKey: messageId) ?? []
        for waiter in waiters { waiter.resume(returning: result) }
        return result
    }

    private func send(conversationId: Int, messageId: Int, rating: Int, feedback: String?) async -> SurveySubmitResult {
        let epoch = sync.currentEpoch
        guard let session = store.current else {
            CWLog.w(.send, "survey answer skipped: no session")
            return .failed
        }
        do {
            let dto = try await api.updateMessage(
                sourceID: session.sourceID, conversationID: conversationId, messageID: messageId,
                body: .csat(rating: rating, feedback: feedback)
            )
            return await accepted(SurveySubmission(conversationId: conversationId, messageId: messageId, rating: rating),
                                  epoch: epoch, dto: dto)
        } catch let error as ChatwootError {
            switch error {
            case .http(let code):
                CWLog.w(.send, "survey answer failed http \(code) id=\(messageId)")
                switch code {
                case 422: return .closed
                case 404:
                    sessionGuard.onHttp(code: code, path: Self.pathTemplate)
                    return .closed
                case 401:
                    sessionGuard.onHttp(code: code, path: Self.pathTemplate)
                    return .failed
                default: return .failed
                }
            case .network:
                CWLog.w(.send, "survey answer failed network")
                return .failed
            default:
                CWLog.w(.send, "survey answer failed \(error)")
                return .failed
            }
        } catch {
            CWLog.w(.send, "survey answer failed \(type(of: error))")
            return .failed
        }
    }

    private func accepted(_ submission: SurveySubmission, epoch: Int, dto: MessageDTO) async -> SurveySubmitResult {
        let current = await persist(dto, conversationId: submission.conversationId, epoch: epoch)
        if current {
            responses.send(submission)
            CWLog.i(.send, "survey answer sent id=\(submission.messageId)")
        } else {
            CWLog.d(.send, "survey answer sent for a reset session: not reported")
        }
        return .sent
    }

    private func persist(_ dto: MessageDTO, conversationId: Int, epoch: Int) async -> Bool {
        guard let (entity, attachments) = dto.toEntities() else {
            return sync.generation.isCurrent(epoch)
        }
        var row = entity
        if dto.conversationID == nil { row.conversationId = conversationId }
        do {
            return try await sync.applyRealtime(epoch: epoch) {
                try self.messageDAO.applyServerMessage(row, attachments: attachments, echoId: nil)
            }
        } catch {
            CWLog.w(.send, "survey answer store failed \(type(of: error))")
            return sync.generation.isCurrent(epoch)
        }
    }

    static let minRating = 1
    static let maxRating = 5
    private static let pathTemplate = "public/api/v1/inboxes/{inbox}/contacts/{sourceId}/conversations/{conversationId}/messages/{messageId}"
}
