import Foundation

final class ChatFormat {
    private let timeFormatter: DateFormatter
    private let thisYearFormatter: DateFormatter
    private let olderFormatter: DateFormatter
    private let sizeFormatter = ByteCountFormatter()

    init(locale: Locale = .current) {
        timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        thisYearFormatter = DateFormatter()
        thisYearFormatter.locale = locale
        thisYearFormatter.setLocalizedDateFormatFromTemplate("dMMMM")
        thisYearFormatter.timeZone = TimeZone(identifier: "UTC")

        olderFormatter = DateFormatter()
        olderFormatter.locale = locale
        olderFormatter.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        olderFormatter.timeZone = TimeZone(identifier: "UTC")

        sizeFormatter.countStyle = .file
    }

    func time(_ epochSeconds: Int) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    func day(_ header: ChatItem.DateHeader) -> String {
        switch header.relation {
        case .today:
            return ChatStrings.today
        case .yesterday:
            return ChatStrings.yesterday
        case .thisYear:
            return thisYearFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(header.epochDay) * 86_400))
        case .older:
            return olderFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(header.epochDay) * 86_400))
        }
    }

    func size(_ bytes: Int) -> String {
        sizeFormatter.string(fromByteCount: Int64(bytes))
    }
}

func bubbleMaxWidth(_ listWidth: CGFloat) -> CGFloat {
    min(listWidth * Spacing.bubbleMaxFraction, Spacing.bubbleMaxWidth)
}
