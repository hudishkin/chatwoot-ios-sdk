import Foundation

final class MessagesWindow {
    struct State: Equatable {
        var items: [ChatItem] = []
        var isLoading = true
        var hasOlder = false
    }

    private(set) var state = State()

    private let builder: ChatItemsBuilder
    private let pageSize: Int
    private var anchor: Anchor?
    private var latest: FeedInput?

    init(builder: ChatItemsBuilder, pageSize: Int = MessagesWindow.defaultPageSize) {
        self.builder = builder
        self.pageSize = pageSize
    }

    @discardableResult
    func update(with input: FeedInput) -> State {
        latest = input
        let effective = anchor.flatMap { $0.conversationId == input.conversationId ? $0 : nil }
            ?? newestPage(input)
        anchor = effective
        let from = effective?.indexIn(input.messages) ?? 0
        let shown = from == 0 ? input.messages : Array(input.messages[from...])
        let items = builder.build(FeedInput(
            messages: shown,
            pending: input.pending,
            conversationId: input.conversationId
        ))
        state = State(items: items, isLoading: false, hasOlder: from > 0)
        return state
    }

    @discardableResult
    func loadOlder() -> State? {
        guard let input = latest,
              let current = anchor,
              current.conversationId == input.conversationId else { return nil }
        let shownFrom = current.indexIn(input.messages)
        guard shownFrom > 0 else { return nil }
        anchor = Anchor.of(input.conversationId, input.messages[max(shownFrom - pageSize, 0)])
        return update(with: input)
    }

    private func newestPage(_ input: FeedInput) -> Anchor? {
        let messages = input.messages
        guard !messages.isEmpty else { return nil }
        return Anchor.of(input.conversationId, messages[max(messages.count - pageSize, 0)])
    }

    private struct Anchor {
        let conversationId: Int?
        let createdAt: Int
        let id: Int

        func indexIn(_ messages: [MessageWithAttachments]) -> Int {
            let index = messages.firstIndex { item in
                item.message.createdAt > createdAt
                    || (item.message.createdAt == createdAt && item.message.id >= id)
            }
            return index ?? messages.count
        }

        static func of(_ conversationId: Int?, _ item: MessageWithAttachments) -> Anchor {
            Anchor(conversationId: conversationId, createdAt: item.message.createdAt, id: item.message.id)
        }
    }

    static let defaultPageSize = 50
}
