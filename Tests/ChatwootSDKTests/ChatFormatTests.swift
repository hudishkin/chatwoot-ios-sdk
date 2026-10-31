import XCTest
@testable import ChatwootSDK

final class ChatFormatTests: XCTestCase {
    private let format = ChatFormat(locale: Locale(identifier: "en_US"))

    func testTimeFormatsShortLocalTime() {
        let string = format.time(feedNoon)
        XCTAssertFalse(string.isEmpty)
        XCTAssertTrue(string.contains(":"))
    }

    func testDayShowsTodayAndYesterdayAsWords() {
        let today = dayHeader(offsetDays: 0, relation: .today)
        let yesterday = dayHeader(offsetDays: -1, relation: .yesterday)
        XCTAssertEqual(format.day(today), ChatStrings.today)
        XCTAssertEqual(format.day(yesterday), ChatStrings.yesterday)
    }

    func testDayThisYearOmitsYear() {
        let header = ChatItem.DateHeader(key: "d", epochDay: 20_000, relation: .thisYear)
        let day = format.day(header)
        XCTAssertFalse(day.isEmpty)
        XCTAssertFalse(day.contains("2024"))
    }

    func testDayOlderIncludesYear() {
        let header = ChatItem.DateHeader(key: "d", epochDay: 20_000, relation: .older)
        XCTAssertTrue(format.day(header).contains("2024"))
    }

    func testSizeFormatsBytes() {
        XCTAssertFalse(format.size(0).isEmpty)
        XCTAssertTrue(format.size(2_500_000).contains("2"))
    }

    private func dayHeader(offsetDays: Int64, relation: DayRelation) -> ChatItem.DateHeader {
        let nowDay = Int64(Date().timeIntervalSince1970) / 86_400
        return ChatItem.DateHeader(key: "d\(offsetDays)", epochDay: nowDay + offsetDays, relation: relation)
    }
}

final class FileTypeTests: XCTestCase {
    func testExtensionUppercased() {
        XCTAssertEqual(fileType("report.pdf"), "PDF")
        XCTAssertEqual(fileType("photo.JPEG"), "JPEG")
    }

    func testLongOrMissingExtensionIsNil() {
        XCTAssertNil(fileType("archive.tar.gz.packed"))
        XCTAssertNil(fileType("noextension"))
        XCTAssertNil(fileType("dot."))
    }
}

final class LinkHostTests: XCTestCase {
    func testStripsSchemeAndPath() {
        XCTAssertEqual(linkHost("https://chatwoot.com/path?q=1#f"), "chatwoot.com")
        XCTAssertEqual(linkHost("http://sub.example.org"), "sub.example.org")
    }

    func testWithoutScheme() {
        XCTAssertEqual(linkHost("example.com/a"), "example.com")
    }
}

final class RunGapTests: XCTestCase {
    func testFirstOfRunGetsWiderGap() {
        XCTAssertEqual(runGap(.single), Spacing.betweenRuns)
        XCTAssertEqual(runGap(.first), Spacing.betweenRuns)
        XCTAssertEqual(runGap(.middle), Spacing.inRun)
        XCTAssertEqual(runGap(.last), Spacing.inRun)
    }
}

final class BubbleMaxWidthTests: XCTestCase {
    func testCappedByFractionAndConstant() {
        XCTAssertEqual(bubbleMaxWidth(400), 320)
        XCTAssertEqual(bubbleMaxWidth(500), 320)
        XCTAssertEqual(bubbleMaxWidth(300), 240)
    }
}

final class InitialsTests: XCTestCase {
    func testTwoWordsAndFallback() {
        XCTAssertEqual(initials("Ada Lovelace"), "AL")
        XCTAssertEqual(initials("ada"), "A")
        XCTAssertEqual(initials(nil), "?")
        XCTAssertEqual(initials("  "), "?")
    }
}

final class ComposerMimeTests: XCTestCase {
    func testKnownExtensions() {
        XCTAssertEqual(ComposerCell.mimeType(for: "PDF"), "application/pdf")
        XCTAssertEqual(ComposerCell.mimeType(for: "heic"), "image/heic")
        XCTAssertNil(ComposerCell.mimeType(for: "xyz123"))
    }
}
