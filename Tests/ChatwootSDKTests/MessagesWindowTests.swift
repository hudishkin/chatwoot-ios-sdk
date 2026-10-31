import XCTest
@testable import ChatwootSDK

final class MessagesWindowTests: XCTestCase {
    private let page = 5

    private func makeWindow() -> MessagesWindow {
        let builder = ChatItemsBuilder(zone: TimeZone(identifier: "UTC")!) { UInt64(feedNoon) * 1000 }
        return MessagesWindow(builder: builder, pageSize: page)
    }

    private func emit(_ messages: [MessageWithAttachments], to window: MessagesWindow) {
        window.update(with: FeedInput(messages: messages, pending: [], conversationId: feedConversation))
    }

    private func messageKeys(_ state: MessagesWindow.State) -> [String] {
        state.items.compactMap { item in
            if case .dateHeader = item { return nil }
            return item.key
        }
    }

    func testInitialStateIsLoading() {
        let window = makeWindow()

        XCTAssertTrue(window.state.isLoading)
    }

    func testMoreMessagesThanPageShowsNewestPageWithOlderAvailable() {
        let window = makeWindow()

        emit((1...12).map { feedAgent($0) }, to: window)

        XCTAssertFalse(window.state.isLoading)
        XCTAssertEqual(messageKeys(window.state), (8...12).reversed().map { "m:\($0)" })
        XCTAssertTrue(window.state.hasOlder)
    }

    func testChatShorterThanPageShowsEverything() {
        let window = makeWindow()

        emit((1...3).map { feedAgent($0) }, to: window)

        XCTAssertEqual(messageKeys(window.state), ["m:3", "m:2", "m:1"])
        XCTAssertFalse(window.state.hasOlder)
    }

    func testLoadOlderMergesPreviousPageAfterShownWithoutDuplicates() {
        let window = makeWindow()
        emit((1...12).map { feedAgent($0) }, to: window)

        window.loadOlder()

        let keys = messageKeys(window.state)
        XCTAssertEqual(keys, (3...12).reversed().map { "m:\($0)" })
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertTrue(window.state.hasOlder)
    }

    func testLoadOlderUntilHistoryExhaustedShowsEverything() {
        let window = makeWindow()
        emit((1...12).map { feedAgent($0) }, to: window)

        window.loadOlder()
        window.loadOlder()
        window.loadOlder()

        XCTAssertEqual(messageKeys(window.state).count, 12)
        XCTAssertFalse(window.state.hasOlder)
    }

    func testNewMessageInFullWindowAppearsOnTopKeepingOldest() {
        let window = makeWindow()
        emit((1...12).map { feedAgent($0) }, to: window)

        emit((1...13).map { feedAgent($0) }, to: window)

        let keys = messageKeys(window.state)
        XCTAssertEqual(keys.first, "m:13")
        XCTAssertEqual(keys.last, "m:8")
        XCTAssertEqual(keys.count, 6)
    }

    func testNewMessageAfterLoadOlderKeepsLoadedPage() {
        let window = makeWindow()
        emit((1...12).map { feedAgent($0) }, to: window)
        window.loadOlder()

        emit((1...13).map { feedAgent($0) }, to: window)

        XCTAssertEqual(messageKeys(window.state).last, "m:3")
    }

    func testEmptyConversationThenHistoryShowsOnlyNewestPage() {
        let window = makeWindow()
        emit([], to: window)

        emit((1...12).map { feedAgent($0) }, to: window)

        XCTAssertEqual(messageKeys(window.state).count, 5)
        XCTAssertTrue(window.state.hasOlder)
    }

    func testQueuedMessagesAreAlwaysShownNewest() {
        let window = makeWindow()

        window.update(with: FeedInput(
            messages: (1...12).map { feedAgent($0) },
            pending: [feedPending("e1", at: feedNoon + 100)],
            conversationId: feedConversation
        ))

        XCTAssertEqual(window.state.items.first?.key, "p:e1")
    }

    func testConversationChangeResetsWindowToNewestPage() {
        let window = makeWindow()
        emit((1...12).map { feedAgent($0) }, to: window)
        window.loadOlder()

        window.update(with: FeedInput(
            messages: (101...112).map { feedAgent($0) },
            pending: [],
            conversationId: feedConversation + 1
        ))

        XCTAssertEqual(messageKeys(window.state).count, 5)
        XCTAssertEqual(messageKeys(window.state).last, "m:108")
    }
}
