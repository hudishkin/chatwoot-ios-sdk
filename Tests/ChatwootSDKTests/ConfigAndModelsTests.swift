import XCTest
@testable import ChatwootSDK

final class ConfigAndModelsTests: XCTestCase {
    func testConfigAcceptsValidValues() throws {
        let config = try ChatwootConfig(baseURL: "https://chat.example.com", inboxIdentifier: "inbox-1", inboxID: 1)
        XCTAssertEqual(config.baseURL.host, "chat.example.com")
        XCTAssertEqual(config.inboxID, 1)
        XCTAssertEqual(config.realtime, .whileForeground)
    }

    func testConfigRejectsInvalidBaseURL() {
        XCTAssertThrowsError(try ChatwootConfig(baseURL: "http://chat.example.com", inboxIdentifier: "i", inboxID: 1)) { error in
            XCTAssertEqual(error as? ChatwootConfig.ValidationError, .invalidBaseURL)
        }
        XCTAssertThrowsError(try ChatwootConfig(baseURL: "https://chat.example.com/app", inboxIdentifier: "i", inboxID: 1))
        XCTAssertThrowsError(try ChatwootConfig(baseURL: "https://chat.example.com?x=1", inboxIdentifier: "i", inboxID: 1))
    }

    func testConfigRejectsInvalidInbox() {
        XCTAssertThrowsError(try ChatwootConfig(baseURL: "https://chat.example.com", inboxIdentifier: "  ", inboxID: 1)) { error in
            XCTAssertEqual(error as? ChatwootConfig.ValidationError, .blankInboxIdentifier)
        }
        XCTAssertThrowsError(try ChatwootConfig(baseURL: "https://chat.example.com", inboxIdentifier: "i", inboxID: 0)) { error in
            XCTAssertEqual(error as? ChatwootConfig.ValidationError, .invalidInboxID)
        }
    }

    func testConfigRejectsInvalidRedactedKey() {
        XCTAssertThrowsError(try ChatwootConfig(baseURL: "https://chat.example.com", inboxIdentifier: "i", inboxID: 1, redactedKeys: ["bad key!"])) { error in
            XCTAssertEqual(error as? ChatwootConfig.ValidationError, .invalidRedactedKey)
        }
    }

    func testConversationStatusFallback() {
        XCTAssertEqual(ConversationStatus(apiName: "snoozed"), .snoozed)
        XCTAssertEqual(ConversationStatus(apiName: "unknown"), .open)
        XCTAssertEqual(ConversationStatus(apiName: nil), .open)
    }

    func testMessageTypeFallback() {
        XCTAssertEqual(MessageType(code: 0), .incoming)
        XCTAssertEqual(MessageType(code: 3), .template)
        XCTAssertEqual(MessageType(code: 99), .activity)
        XCTAssertEqual(MessageType(code: nil), .activity)
    }

    func testAttributeDateRoundTrip() throws {
        let date = try XCTUnwrap(AttributeDate(parsing: "2024-02-29"))
        XCTAssertEqual(date.description, "2024-02-29")
        XCTAssertNil(AttributeDate(parsing: "2023-02-29"), "2023 — не високосный")
        XCTAssertNil(AttributeDate(parsing: "29.02.2024"))
        XCTAssertNil(AttributeDate(year: 2024, month: 13, day: 1))
    }

    func testAttributeValueEncoding() throws {
        let values: [String: AttributeValue] = [
            "plan": .text("pro"),
            "seats": .integer(5),
            "rate": .decimal(4.5),
            "trial": .bool(false),
            "since": .date(try XCTUnwrap(AttributeDate(parsing: "2024-01-15"))),
        ]
        let data = try JSONEncoder().encode(values)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["plan"] as? String, "pro")
        XCTAssertEqual(object["seats"] as? Int, 5)
        XCTAssertEqual(object["rate"] as? Double, 4.5)
        XCTAssertEqual(object["trial"] as? Bool, false)
        XCTAssertEqual(object["since"] as? String, "2024-01-15")
    }

    func testPersonalDataMaskedInDescriptions() {
        let identity = Identity(identifier: "user-42", identifierHash: "hash")
        XCTAssertEqual(identity.description, "Identity(***)")
        let user = ChatwootUser(name: "Jane")
        XCTAssertEqual(user.description, "ChatwootUser(***)")
    }
}
