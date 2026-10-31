import XCTest
@testable import ChatwootSDK

final class DTOCodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testMessageDTODecoding() throws {
        let json = """
        {
          "id": 101,
          "content": "Здравствуйте!",
          "message_type": 1,
          "content_type": "text",
          "content_attributes": {},
          "created_at": 1793170512,
          "conversation_id": 7,
          "inbox_id": 3,
          "sender": {
            "id": 5,
            "name": "Agent",
            "available_name": "Agent A",
            "type": "user",
            "avatar_url": "https://chat.example.com/avatar.png"
          },
          "attachments": [
            {
              "id": 11,
              "message_id": 101,
              "file_type": "image",
              "extension": "jpg",
              "data_url": "https://chat.example.com/file.jpg",
              "thumb_url": "https://chat.example.com/thumb.jpg",
              "file_size": 10240,
              "width": 800,
              "height": 600
            }
          ]
        }
        """
        let dto = try decoder.decode(MessageDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id, 101)
        XCTAssertEqual(dto.content, "Здравствуйте!")
        XCTAssertEqual(dto.messageType, 1)
        XCTAssertEqual(dto.createdAt, 1793170512)
        XCTAssertEqual(dto.conversationID, 7)
        XCTAssertEqual(dto.sender?.type, "user")
        XCTAssertEqual(dto.sender?.availableName, "Agent A")
        XCTAssertEqual(dto.attachments?.count, 1)
        XCTAssertEqual(dto.attachments?.first?.fileType, "image")
        XCTAssertEqual(dto.attachments?.first?.fileSize, 10240)
        XCTAssertFalse(dto.isMine)
    }

    func testMessageDTOIsMine() throws {
        let json = """
        {
          "id": 102,
          "content": "Привет",
          "message_type": 0,
          "created_at": 1793170512,
          "sender": { "id": 9, "type": "contact" }
        }
        """
        let dto = try decoder.decode(MessageDTO.self, from: Data(json.utf8))
        XCTAssertTrue(dto.isMine)
    }

    func testSurveyMessageHelpers() throws {
        let json = """
        {
          "id": 103,
          "message_type": 1,
          "content_type": "input_csat",
          "content_attributes": {
            "display_type": "emoji",
            "submitted_values": {
              "csat_survey_response": { "rating": 4, "feedback_message": "Спасибо" }
            }
          },
          "sender": { "type": "user" }
        }
        """
        let dto = try decoder.decode(MessageDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.contentType, contentTypeCSAT)
        XCTAssertEqual(dto.surveyDisplay, "emoji")
        XCTAssertEqual(dto.surveyRating, 4)
    }

    func testConversationDTODecoding() throws {
        let json = """
        {
          "id": 7,
          "uuid": "d6c1e5f0",
          "inbox_id": 3,
          "status": "open",
          "contact_last_seen_at": 1793170000,
          "agent_last_seen_at": 1793170500,
          "messages": [],
          "contact": { "id": 9, "identifier": "user-42", "custom_attributes": { "plan": "pro" } }
        }
        """
        let dto = try decoder.decode(ConversationDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id, 7)
        XCTAssertEqual(dto.status, "open")
        XCTAssertEqual(ConversationStatus(apiName: dto.status), .open)
        XCTAssertEqual(dto.contact?.identifier, "user-42")
        XCTAssertEqual(dto.contact?.customAttributes?["plan"]?.stringValue, "pro")
    }

    func testContactInboxDTODecoding() throws {
        let json = """
        {
          "source_id": "src-123",
          "pubsub_token": "tok-abc",
          "id": 9,
          "name": "Jane"
        }
        """
        let dto = try decoder.decode(ContactInboxDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.sourceID, "src-123")
        XCTAssertEqual(dto.pubsubToken, "tok-abc")
        XCTAssertEqual(dto.id, 9)
    }

    func testCSATBodyEncoding() throws {
        let body = UpdateMessageBody.csat(rating: 5, feedback: "ok")
        let data = try JSONEncoder().encode(body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let submitted = try XCTUnwrap(object["submitted_values"] as? [String: Any])
        let response = try XCTUnwrap(submitted["csat_survey_response"] as? [String: Any])
        XCTAssertEqual(response["rating"] as? Int, 5)
        XCTAssertEqual(response["feedback_message"] as? String, "ok")
    }

    func testCSATBodyOmitsNilFeedback() throws {
        let body = UpdateMessageBody.csat(rating: 3, feedback: nil)
        let data = try JSONEncoder().encode(body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let submitted = try XCTUnwrap(object["submitted_values"] as? [String: Any])
        let response = try XCTUnwrap(submitted["csat_survey_response"] as? [String: Any])
        XCTAssertNil(response["feedback_message"])
    }
}
