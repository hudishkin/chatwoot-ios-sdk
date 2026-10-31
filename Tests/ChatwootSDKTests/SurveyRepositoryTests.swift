import Combine
import XCTest
@testable import ChatwootSDK

final class SurveyRepositoryTests: XCTestCase {
    private var api: MockChatwootAPI!
    private var database: ChatwootDatabase!
    private var store: SessionStore!
    private var sessionGuard: SessionGuard!
    private var sync: SyncManager!
    private var repository: SurveyRepository!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        api = MockChatwootAPI()
        database = try! ChatwootDatabase.inMemory()
        store = SessionStore(directory: Fixtures.makeTempDirectory())
        try! store.write(Fixtures.session)
        sessionGuard = SessionGuard()
        sync = SyncManager(
            api: api,
            inboxIdentifier: "inbox-1",
            inboxId: 1,
            store: store,
            messageDAO: database.messages,
            sessionGuard: sessionGuard
        )
        repository = SurveyRepository(
            api: api,
            inboxIdentifier: "inbox-1",
            store: store,
            messageDAO: database.messages,
            sync: sync,
            sessionGuard: sessionGuard
        )
        try! database.conversations.upsert(StorageFixtures.conversation(7))
    }

    private func surveyDTO(id: Int = 55, conversationID: Int? = 7) -> MessageDTO {
        MessageDTO(
            id: id, content: "Как вам поддержка?", messageType: 3, contentType: "input_csat",
            contentAttributes: nil, createdAt: 100, conversationID: conversationID, inboxID: 1,
            echoID: nil, attachments: nil, sender: nil
        )
    }

    func testRatingOutOfRangeFails() async {
        for rating in [0, 6] {
            let result = await repository.submit(conversationId: 7, messageId: 55, rating: rating, comment: nil)
            XCTAssertEqual(result, .failed)
        }
        XCTAssertEqual(api.updateMessageCalls.count, 0, "невалидная оценка не уходит в сеть")
    }

    func testSuccessPersistsAndEmits() async {
        var submissions: [SurveySubmission] = []
        repository.responses.sink { submissions.append($0) }.store(in: &cancellables)
        api.updateMessageStub = .success(surveyDTO())
        let result = await repository.submit(conversationId: 7, messageId: 55, rating: 4, comment: "  ")
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(api.updateMessageCalls.count, 1)
        let call = api.updateMessageCalls[0]
        XCTAssertEqual(call.body, .csat(rating: 4, feedback: nil), "пустой отзыв не отправляется")
        XCTAssertEqual(submissions, [SurveySubmission(conversationId: 7, messageId: 55, rating: 4)])
        XCTAssertEqual(try database.messages.get(55)?.contentType, "input_csat", "ответ сохранён как message.updated")
    }

    func testCommentTrimmed() async {
        api.updateMessageStub = .success(surveyDTO())
        _ = await repository.submit(conversationId: 7, messageId: 55, rating: 2, comment: "  плохо  ")
        XCTAssertEqual(api.updateMessageCalls[0].body, .csat(rating: 2, feedback: "плохо"))
    }

    func testHttp422IsClosed() async {
        api.updateMessageStub = .failure(ChatwootError.http(code: 422))
        let result = await repository.submit(conversationId: 7, messageId: 55, rating: 3, comment: nil)
        XCTAssertEqual(result, .closed)
    }

    func testHttp404IsClosedAndReported() async {
        var reasons: [String] = []
        sessionGuard.reidentifyRequests.sink { reasons.append($0) }.store(in: &cancellables)
        api.updateMessageStub = .failure(ChatwootError.http(code: 404))
        let result = await repository.submit(conversationId: 7, messageId: 55, rating: 3, comment: nil)
        XCTAssertEqual(result, .closed)
        XCTAssertEqual(reasons, ["http_404"])
    }

    func testHttp401IsFailedAndReported() async {
        var reasons: [String] = []
        sessionGuard.reidentifyRequests.sink { reasons.append($0) }.store(in: &cancellables)
        api.updateMessageStub = .failure(ChatwootError.http(code: 401))
        let result = await repository.submit(conversationId: 7, messageId: 55, rating: 3, comment: nil)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(reasons, ["http_401"])
    }

    func testNetworkIsFailed() async {
        api.updateMessageStub = .failure(ChatwootError.network)
        let result = await repository.submit(conversationId: 7, messageId: 55, rating: 3, comment: nil)
        XCTAssertEqual(result, .failed)
    }

    func testNoSessionIsFailed() async {
        store.clear()
        let result = await repository.submit(conversationId: 7, messageId: 55, rating: 3, comment: nil)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(api.updateMessageCalls.count, 0)
    }

    func testConcurrentSubmitsShareRequest() async {
        api.updateMessageHandler = { _, _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return self.surveyDTO()
        }
        async let first = repository.submit(conversationId: 7, messageId: 55, rating: 5, comment: nil)
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let second = repository.submit(conversationId: 7, messageId: 55, rating: 1, comment: "другой ответ")
        let (firstResult, secondResult) = await (first, second)
        XCTAssertEqual(firstResult, .sent)
        XCTAssertEqual(secondResult, .sent, "второй вызов ждёт и получает итог первого")
        XCTAssertEqual(api.updateMessageCalls.count, 1, "один запрос на сообщение")
    }

    func testResetSessionDoesNotEmit() async {
        var submissions: [SurveySubmission] = []
        repository.responses.sink { submissions.append($0) }.store(in: &cancellables)
        api.updateMessageHandler = { [sync] _, _, _ in
            await sync?.invalidate {}
            return self.surveyDTO()
        }
        let result = await repository.submit(conversationId: 7, messageId: 55, rating: 4, comment: nil)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(submissions, [], "ответ за сброшенную сессию не репортится")
    }
}
