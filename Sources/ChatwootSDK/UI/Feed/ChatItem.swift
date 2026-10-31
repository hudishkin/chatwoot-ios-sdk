import Foundation

enum RunPosition: Equatable {
    case single, first, middle, last

    var isFirst: Bool { self == .single || self == .first }
    var isLast: Bool { self == .single || self == .last }
}

enum SendStatus: Equatable {
    case sent, sending, failed
}

struct AttachmentUi: Equatable {
    let source: String
    let isLocal: Bool
    let isImage: Bool
    let thumbnail: String?
    let name: String
    let sizeBytes: Int?
    let width: Int?
    let height: Int?
}

enum ChatItem: Equatable {
    case mine(Mine)
    case theirs(Theirs)
    case system(System)
    case survey(Survey)
    case dateHeader(DateHeader)

    struct Mine: Equatable {
        let key: String
        let echoId: String?
        let text: String?
        let attachment: AttachmentUi?
        let status: SendStatus
        let createdAt: Int
        let run: RunPosition
        let showMeta: Bool
        let deleted: Bool
    }

    struct Theirs: Equatable {
        let key: String
        let text: String?
        let attachment: AttachmentUi?
        let senderName: String?
        let createdAt: Int
        let run: RunPosition
        let showName: Bool
        let showAvatar: Bool
        let showMeta: Bool
        let deleted: Bool
    }

    struct System: Equatable {
        let key: String
        let text: String
        let createdAt: Int
    }

    struct Survey: Equatable {
        let key: String
        let messageId: Int
        let conversationId: Int
        let prompt: String
        let display: SurveyDisplay
        let answeredRating: Int?
        let closedHint: Bool
        let createdAt: Int
    }

    struct DateHeader: Equatable {
        let key: String
        let epochDay: Int64
        let relation: DayRelation
    }

    var key: String {
        switch self {
        case .mine(let item): return item.key
        case .theirs(let item): return item.key
        case .system(let item): return item.key
        case .survey(let item): return item.key
        case .dateHeader(let item): return item.key
        }
    }
}

enum SurveyDisplay: Equatable {
    case stars, emoji

    static func of(_ value: String?) -> SurveyDisplay {
        value == "emoji" ? .emoji : .stars
    }
}

enum DayRelation: Equatable {
    case today, yesterday, thisYear, older
}

extension ChatItem {
    var serverCreatedAt: Int? {
        switch self {
        case .mine(let item): return item.echoId == nil ? item.createdAt : nil
        case .theirs(let item): return item.createdAt
        case .system(let item): return item.createdAt
        case .survey(let item): return item.createdAt
        case .dateHeader: return nil
        }
    }
}

extension Array where Element == ChatItem {
    func newestMessageKey() -> String? {
        first?.key
    }

    func unseenAgentRows(seenKey: String?) -> Int {
        guard let seen = firstIndex(where: { $0.key == seenKey }), seen > 0 else { return 0 }
        return self[..<seen].reduce(0) { count, item in
            if case .theirs = item { return count + 1 }
            return count
        }
    }
}

func newestSeen(newestKey: String?, visibleKeys: [String]) -> Bool {
    guard let newestKey else { return true }
    return visibleKeys.contains(newestKey)
}
