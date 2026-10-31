import Foundation

struct FeedInput {
    let messages: [MessageWithAttachments]
    let pending: [StoredPendingMessage]
    let conversationId: Int?
}

final class ChatItemsBuilder {
    private enum Entry {
        case server(MessageWithAttachments)
        case queued(StoredPendingMessage)

        var createdAt: Int {
            switch self {
            case .server(let item): return item.message.createdAt
            case .queued(let pending): return pending.createdAt
            }
        }

        var order: Int {
            switch self {
            case .server: return 0
            case .queued: return 1
            }
        }
    }

    private enum Row {
        case plain(ChatItem)
        case bubble(Bubble)

        struct Bubble {
            let key: String
            let sender: String
            let createdAt: Int
            let text: String?
            let attachment: AttachmentUi?
            let status: SendStatus
            let message: StoredMessage?
            let echoId: String?
            let deleted: Bool

            func joins(_ later: Bubble) -> Bool {
                sender == later.sender && later.createdAt - createdAt <= runGapSeconds
            }
        }
    }

    private let zone: TimeZone
    private let nowMs: () -> UInt64

    init(zone: TimeZone, nowMs: @escaping () -> UInt64) {
        self.zone = zone
        self.nowMs = nowMs
    }

    func build(_ input: FeedInput) -> [ChatItem] {
        let delivered = Set(input.messages.compactMap(\.echoId))
        let pending = input.pending.filter { !delivered.contains($0.echoId) }
        let entries = (input.messages.map(Entry.server) + pending.map(Entry.queued))
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                if lhs.element.order != rhs.element.order {
                    return lhs.element.order < rhs.element.order
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        let today = epochDay(Int64(nowMs()))
        var rows = [Row]()
        var lastDay: Int64?
        for entry in entries {
            let produced = rowsOf(entry)
            if produced.isEmpty { continue }
            let day = epochDay(Int64(entry.createdAt) * ChatItemsBuilder.millisPerSecond)
            if day != lastDay {
                rows.append(.plain(.dateHeader(ChatItem.DateHeader(
                    key: "h:\(day)", epochDay: day, relation: relation(day, today)
                ))))
                lastDay = day
            }
            rows.append(contentsOf: produced)
        }
        return group(rows).reversed()
    }

    private func rowsOf(_ entry: Entry) -> [Row] {
        switch entry {
        case .queued(let pending): return queuedRows(pending)
        case .server(let item): return serverRows(item)
        }
    }

    private func serverRows(_ item: MessageWithAttachments) -> [Row] {
        let m = item.message
        let key = item.echoId.map { "p:\($0)" } ?? "m:\(m.id)"
        if m.contentType == ChatItemsBuilder.contentTypeCsat && !m.isMine {
            return m.isDeleted ? [] : [.plain(survey(key: key, m))]
        }
        switch MessageType(code: m.type) {
        case .activity, .template:
            let text = m.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            if m.isDeleted || text?.isEmpty != false { return [] }
            return [.plain(.system(ChatItem.System(key: key, text: text ?? "", createdAt: m.createdAt)))]
        case .incoming, .outgoing:
            let sender = m.isMine ? ChatItemsBuilder.senderMe : "a:\(m.senderType ?? ""):\(m.senderName ?? "")"
            if m.isDeleted {
                return [.bubble(Row.Bubble(
                    key: key, sender: sender, createdAt: m.createdAt, text: nil,
                    attachment: nil, status: .sent, message: m, echoId: nil, deleted: true
                ))]
            }
            let files = item.attachments.compactMap(attachmentUi)
            return bubbles(
                key: key, sender: sender, createdAt: m.createdAt,
                content: m.content, files: files, status: .sent, message: m
            )
        }
    }

    private func survey(key: String, _ m: StoredMessage) -> ChatItem {
        .survey(ChatItem.Survey(
            key: key,
            messageId: m.id,
            conversationId: m.conversationId,
            prompt: m.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            display: SurveyDisplay.of(m.surveyDisplay),
            answeredRating: m.surveyRating,
            closedHint: surveyClosedHint(createdAt: m.createdAt, nowMs: nowMs()),
            createdAt: m.createdAt
        ))
    }

    private func queuedRows(_ p: StoredPendingMessage) -> [Row] {
        let status: SendStatus = p.state == .failed ? .failed : .sending
        let files = p.attachmentPath.map { path in
            [AttachmentUi(
                source: path,
                isLocal: true,
                isImage: p.attachmentMime?.hasPrefix("image/") == true,
                thumbnail: nil,
                name: (path as NSString).lastPathComponent,
                sizeBytes: nil,
                width: nil,
                height: nil
            )]
        } ?? []
        return bubbles(
            key: "p:\(p.echoId)", sender: ChatItemsBuilder.senderMe, createdAt: p.createdAt,
            content: p.content, files: files, status: status, message: nil, echoId: p.echoId
        )
    }

    private func bubbles(
        key: String,
        sender: String,
        createdAt: Int,
        content: String?,
        files: [AttachmentUi],
        status: SendStatus,
        message: StoredMessage?,
        echoId: String? = nil
    ) -> [Row] {
        let text = content.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        if files.isEmpty {
            guard let text else { return [] }
            return [.bubble(Row.Bubble(
                key: key, sender: sender, createdAt: createdAt, text: text,
                attachment: nil, status: status, message: message, echoId: echoId, deleted: false
            ))]
        }
        return files.enumerated().map { index, file in
            .bubble(Row.Bubble(
                key: files.count == 1 ? key : "\(key):\(index)",
                sender: sender,
                createdAt: createdAt,
                text: index == files.count - 1 ? text : nil,
                attachment: file,
                status: status,
                message: message,
                echoId: echoId,
                deleted: false
            ))
        }
    }

    private func group(_ rows: [Row]) -> [ChatItem] {
        rows.enumerated().map { index, row in
            switch row {
            case .plain(let item):
                return item
            case .bubble(let bubble):
                let previous = bubbleAt(rows, index - 1).flatMap { $0.joins(bubble) ? $0 : nil }
                let next = bubbleAt(rows, index + 1).flatMap { bubble.joins($0) ? $0 : nil }
                let position: RunPosition
                switch (previous, next) {
                case (nil, nil): position = .single
                case (nil, _): position = .first
                case (_, nil): position = .last
                default: position = .middle
                }
                return item(bubble, position: position, next: next)
            }
        }
    }

    private func bubbleAt(_ rows: [Row], _ index: Int) -> Row.Bubble? {
        guard rows.indices.contains(index), case .bubble(let bubble) = rows[index] else { return nil }
        return bubble
    }

    private func item(_ bubble: Row.Bubble, position: RunPosition, next: Row.Bubble?) -> ChatItem {
        if bubble.sender == ChatItemsBuilder.senderMe {
            return .mine(ChatItem.Mine(
                key: bubble.key,
                echoId: bubble.echoId,
                text: bubble.text,
                attachment: bubble.attachment,
                status: bubble.status,
                createdAt: bubble.createdAt,
                run: position,
                showMeta: next == nil || next?.status != bubble.status,
                deleted: bubble.deleted
            ))
        }
        return .theirs(ChatItem.Theirs(
            key: bubble.key,
            text: bubble.text,
            attachment: bubble.attachment,
            senderName: bubble.message?.senderName,
            createdAt: bubble.createdAt,
            run: position,
            showName: position.isFirst,
            showAvatar: position.isLast,
            showMeta: position.isLast,
            deleted: bubble.deleted
        ))
    }

    private func attachmentUi(_ attachment: StoredAttachment) -> AttachmentUi? {
        guard let url = attachment.dataUrl else { return nil }
        return AttachmentUi(
            source: url,
            isLocal: false,
            isImage: attachment.fileType == ChatItemsBuilder.fileTypeImage,
            thumbnail: attachment.thumbUrl,
            name: ChatItemsBuilder.fileName(url),
            sizeBytes: attachment.fileSize,
            width: attachment.width,
            height: attachment.height
        )
    }

    static func fileName(_ url: String) -> String {
        var path = url
        if let index = path.firstIndex(of: "?") { path = String(path[..<index]) }
        if let index = path.firstIndex(of: "#") { path = String(path[..<index]) }
        while path.hasSuffix("/") { path.removeLast() }
        let segment = path.split(separator: "/").last.map(String.init) ?? ""
        return segment.removingPercentEncoding ?? segment
    }

    private func epochDay(_ ms: Int64) -> Int64 {
        let offsetMs = Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))) * 1000
        return floorDiv(ms + offsetMs, ChatItemsBuilder.millisPerDay)
    }

    private func relation(_ day: Int64, _ today: Int64) -> DayRelation {
        switch day {
        case today: return .today
        case today - 1: return .yesterday
        default: return year(day) == year(today) ? .thisYear : .older
        }
    }

    private func year(_ epochDay: Int64) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval(epochDay) * 86400))
    }

    private static let senderMe = "me"
    private static let fileTypeImage = "image"
    private static let contentTypeCsat = "input_csat"
    private static let millisPerSecond: Int64 = 1_000
    private static let millisPerDay: Int64 = 86_400_000
}

private let runGapSeconds = 5 * 60

private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let quotient = a / b
    return a % b != 0 && (a < 0) != (b < 0) ? quotient - 1 : quotient
}

let surveyOpenDays = 14

func surveyClosedHint(createdAt: Int, nowMs: UInt64) -> Bool {
    Int64(nowMs / 1000) - Int64(createdAt) > Int64(surveyOpenDays * 86_400)
}
