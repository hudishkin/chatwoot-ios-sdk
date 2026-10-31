import XCTest
@testable import ChatwootSDK

final class ChatItemsBuilderTests: XCTestCase {
    private let builder = ChatItemsBuilder(zone: TimeZone(identifier: "UTC")!) {
        UInt64(feedNoon + 3_600) * 1000
    }

    private func build(_ input: FeedInput) -> [ChatItem] {
        builder.build(input)
    }

    private func bubbles(_ items: [ChatItem]) -> [ChatItem] {
        items.filter {
            if case .mine = $0 { return true }
            if case .theirs = $0 { return true }
            return false
        }
    }

    func testBuiltMessagesAreNewestFirstWithDateHeaderLast() {
        let items = build(FeedInput(messages: [feedMine(1), feedAgent(2)], pending: [], conversationId: feedConversation))

        XCTAssertEqual(items.map(\.key), ["m:2", "m:1", "h:\(feedNoon / 86_400)"])
        guard case .dateHeader(let header) = items.last else {
            return XCTFail("последняя строка — заголовок дня")
        }
        XCTAssertEqual(header.relation, .today)
    }

    func testMessageOfPreviousDayGetsYesterdayHeader() {
        let items = build(FeedInput(messages: [feedAgent(1, at: feedNoon - 86_400)], pending: [], conversationId: feedConversation))

        let headers = items.compactMap { item -> ChatItem.DateHeader? in
            guard case .dateHeader(let header) = item else { return nil }
            return header
        }
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers.first?.relation, .yesterday)
    }

    func testTemplateMessageTypeBecomesSystemItem() {
        let items = build(FeedInput(messages: [feedTemplate(1)], pending: [], conversationId: feedConversation))

        XCTAssertEqual(items.first, .system(ChatItem.System(key: "m:1", text: "We reply within a day", createdAt: feedNoon + 1)))
    }

    func testDeletedMessagesBecomePlaceholdersInSenderCells() {
        let items = build(FeedInput(
            messages: [feedAgent(1, text: "secret", deleted: true), feedMine(2, deleted: true)],
            pending: [], conversationId: feedConversation
        ))

        let theirs = items.compactMap { item -> ChatItem.Theirs? in
            guard case .theirs(let theirs) = item else { return nil }
            return theirs
        }
        let mine = items.compactMap { item -> ChatItem.Mine? in
            guard case .mine(let mine) = item else { return nil }
            return mine
        }
        XCTAssertEqual(theirs.count, 1)
        XCTAssertTrue(theirs[0].deleted)
        XCTAssertNil(theirs[0].text)
        XCTAssertEqual(mine.count, 1)
        XCTAssertTrue(mine[0].deleted)
    }

    func testPendingRowsAreMineSendingOrFailedAfterServerMessages() {
        let items = build(FeedInput(
            messages: [feedAgent(1)],
            pending: [feedPending("e1"), feedPending("e2", at: feedNoon + 1001, state: .failed)],
            conversationId: feedConversation
        ))

        let mine = items.compactMap { item -> ChatItem.Mine? in
            guard case .mine(let mine) = item else { return nil }
            return mine
        }
        XCTAssertEqual(mine.map(\.key), ["p:e2", "p:e1"])
        XCTAssertEqual(mine.map(\.status), [.failed, .sending])
        XCTAssertEqual(mine.first?.echoId, "e2")
        let lastMineIndex = items.firstIndex(of: .mine(mine[1]))
        let serverIndex = items.firstIndex { $0.key == "m:1" }
        XCTAssertNotNil(lastMineIndex)
        XCTAssertNotNil(serverIndex)
        XCTAssertLessThan(lastMineIndex ?? .max, serverIndex ?? .min)
    }

    func testDeliveredMessageKeepsPendingKeyAndHidesItsPending() {
        var delivered = feedMine(5)
        delivered.echoId = "e1"
        let items = build(FeedInput(
            messages: [delivered],
            pending: [feedPending("e1"), feedPending("e2")],
            conversationId: feedConversation
        ))

        let mine = items.compactMap { item -> ChatItem.Mine? in
            guard case .mine(let mine) = item else { return nil }
            return mine
        }
        XCTAssertEqual(mine.map(\.key), ["p:e2", "p:e1"])
        XCTAssertEqual(mine.map(\.status), [.sending, .sent])
    }

    func testRunOfThreeFromOneAgentGetsPositionsNameOnFirstAvatarAndMetaOnLast() {
        let items = build(FeedInput(
            messages: [feedAgent(1), feedAgent(2), feedAgent(3)],
            pending: [], conversationId: feedConversation
        ))

        let run = items.compactMap { item -> ChatItem.Theirs? in
            guard case .theirs(let theirs) = item else { return nil }
            return theirs
        }.reversed()
        XCTAssertEqual(run.map(\.run), [.first, .middle, .last])
        XCTAssertEqual(run.map(\.showName), [true, false, false])
        XCTAssertEqual(run.map(\.showAvatar), [false, false, true])
        XCTAssertEqual(run.map(\.showMeta), [false, false, true])
    }

    func testSenderChangeOrLongGapStartsNewRun() {
        let items = build(FeedInput(
            messages: [
                feedAgent(1, name: "Anna"),
                feedAgent(2, name: "Boris"),
                feedAgent(3, at: feedNoon + 2 + 600, name: "Boris"),
            ],
            pending: [], conversationId: feedConversation
        ))

        let runs = items.compactMap { item -> ChatItem.Theirs? in
            guard case .theirs(let theirs) = item else { return nil }
            return theirs
        }.reversed().map(\.run)
        XCTAssertEqual(runs, [.single, .single, .single])
    }

    func testOwnRunWithDifferentStatusesShowsMetaWhereStatusChanges() {
        let items = build(FeedInput(
            messages: [feedMine(1), feedMine(2)],
            pending: [feedPending("e1", at: feedNoon + 3)],
            conversationId: feedConversation
        ))

        let own = items.compactMap { item -> ChatItem.Mine? in
            guard case .mine(let mine) = item else { return nil }
            return mine
        }.reversed()
        XCTAssertEqual(own.map(\.run), [.first, .middle, .last])
        XCTAssertEqual(own.map(\.showMeta), [false, true, true])
    }

    func testMessageWithTwoAttachmentsAndTextGetsOneItemEachWithCaptionOnLast() {
        let items = build(FeedInput(
            messages: [feedAgent(1, text: "see", attachments: [feedImage(10, messageId: 1), feedFile(11, messageId: 1)])],
            pending: [], conversationId: feedConversation
        ))

        let theirs = items.compactMap { item -> ChatItem.Theirs? in
            guard case .theirs(let theirs) = item else { return nil }
            return theirs
        }.reversed() as [ChatItem.Theirs]
        XCTAssertEqual(theirs.map(\.key), ["m:1:0", "m:1:1"])
        XCTAssertTrue(theirs[0].attachment?.isImage ?? false)
        XCTAssertNil(theirs[0].text)
        XCTAssertEqual(theirs[1].attachment?.name, "report final.pdf")
        XCTAssertEqual(theirs[1].text, "see")
    }

    func testPendingFileBecomesLocalAttachment() {
        let items = build(FeedInput(
            messages: [],
            pending: [feedPending("e1", text: nil, path: "/data/a/e1/photo.jpg", mime: "image/jpeg")],
            conversationId: feedConversation
        ))

        let mine = items.compactMap { item -> ChatItem.Mine? in
            guard case .mine(let mine) = item else { return nil }
            return mine
        }
        XCTAssertEqual(mine.count, 1)
        XCTAssertTrue(mine[0].attachment?.isLocal ?? false)
        XCTAssertTrue(mine[0].attachment?.isImage ?? false)
        XCTAssertEqual(mine[0].attachment?.name, "photo.jpg")
    }

    func testMessageWithoutTextOrFilesIsSkipped() {
        let items = build(FeedInput(messages: [feedAgent(1, text: "  ")], pending: [], conversationId: feedConversation))

        XCTAssertTrue(items.isEmpty)
    }

    func testCsatMessageBecomesSurveyItemNotSystem() {
        let items = build(FeedInput(messages: [feedSurvey(1, display: "emoji")], pending: [], conversationId: feedConversation))

        for item in items {
            if case .system = item { XCTFail("опрос не должен стать системной строкой") }
        }
        let surveys = items.compactMap { item -> ChatItem.Survey? in
            guard case .survey(let survey) = item else { return nil }
            return survey
        }
        XCTAssertEqual(surveys, [
            ChatItem.Survey(
                key: "m:1", messageId: 1, conversationId: feedConversation,
                prompt: "Please rate the conversation", display: .emoji,
                answeredRating: nil, closedHint: false, createdAt: feedNoon + 1
            ),
        ])
    }

    func testUnknownOrMissingSurveyDisplayFallsBackToStars() {
        let items = build(FeedInput(
            messages: [feedSurvey(1, display: "thumbs"), feedSurvey(2, display: nil)],
            pending: [], conversationId: feedConversation
        ))

        let displays = items.compactMap { item -> SurveyDisplay? in
            guard case .survey(let survey) = item else { return nil }
            return survey.display
        }
        XCTAssertEqual(displays, [.stars, .stars])
    }

    func testAnsweredCsatKeepsRating() {
        let items = build(FeedInput(messages: [feedSurvey(1, rating: 4)], pending: [], conversationId: feedConversation))

        let survey = items.compactMap { item -> ChatItem.Survey? in
            guard case .survey(let survey) = item else { return nil }
            return survey
        }
        XCTAssertEqual(survey.first?.answeredRating, 4)
    }

    func testCsatOlderThanTwoWeeksGetsClosedHint() {
        let old = feedSurvey(1, at: feedNoon - 15 * 86_400)
        let recent = feedSurvey(2, at: feedNoon - 13 * 86_400)

        let hints = build(FeedInput(messages: [old, recent], pending: [], conversationId: feedConversation))
            .compactMap { item -> (Int, Bool)? in
                guard case .survey(let survey) = item else { return nil }
                return (survey.messageId, survey.closedHint)
            }

        XCTAssertEqual(Dictionary(uniqueKeysWithValues: hints), [1: true, 2: false])
    }
}
