import XCTest
@testable import ChatwootSDK

final class TextLinksTests: XCTestCase {
    func testLinksAreFoundWithoutTrailingPunctuation() {
        let text = "See https://chat.example.com/help, or http://example.com/a?b=1."

        let links = findLinks(text).map { String(text[$0]) }

        XCTAssertEqual(links, ["https://chat.example.com/help", "http://example.com/a?b=1"])
    }

    func testBareSchemeIsNotALink() {
        XCTAssertTrue(findLinks("call me at noon, https:// is not a link").isEmpty)
    }

    func testLongNameIsEllipsizedInTheMiddleKeepingExtension() {
        let name = String(repeating: "a", count: 40) + String(repeating: "b", count: 40) + ".pdf"

        let short = middleEllipsize(name, maxChars: 20)

        XCTAssertEqual(short.count, 20)
        XCTAssertTrue(short.hasPrefix("aaaaaaa"))
        XCTAssertTrue(short.hasSuffix("bbb.pdf"))
        XCTAssertTrue(short.contains("…"))
        XCTAssertEqual(middleEllipsize("short.txt"), "short.txt")
    }

    func testImageRatiosCapWidthAndClampHeight() {
        XCTAssertTrue(imageBoxSize(width: 1000, height: 1000, maxWidth: 300) == (240, 240))
        XCTAssertTrue(imageBoxSize(width: 4000, height: 1000, maxWidth: 300) == (240, 120))
        XCTAssertTrue(imageBoxSize(width: 1000, height: 4000, maxWidth: 300) == (240, 320))
        XCTAssertTrue(imageBoxSize(width: nil, height: nil, maxWidth: 200) == (200, 150))
    }

    func testInitialsTakeTwoLettersOrPlaceholder() {
        XCTAssertEqual(initials("anna maria smith"), "AM")
        XCTAssertEqual(initials("Bot"), "B")
        XCTAssertEqual(initials("  "), "?")
        XCTAssertEqual(initials(nil), "?")
    }
}
