import XCTest
@testable import ChatwootSDK

final class CableCodecTests: XCTestCase {
    func testDecodeWelcome() {
        XCTAssertEqual(CableCodec.decode(#"{"type":"welcome"}"#), .welcome)
    }

    func testDecodePing() {
        XCTAssertEqual(CableCodec.decode(#"{"type":"ping","message":1793170512}"#), .ping)
    }

    func testDecodeConfirm() throws {
        let identifier = CableCodec.identifier(pubsubToken: "tok")
        let data = try JSONSerialization.data(withJSONObject: ["type": "confirm_subscription", "identifier": identifier])
        let frame = try XCTUnwrap(String(data: data, encoding: .utf8))
        guard case .confirm(let id) = CableCodec.decode(frame) else {
            return XCTFail("expected confirm")
        }
        XCTAssertEqual(id, identifier)
    }

    func testDecodeDisconnectDefaultReconnect() {
        guard case .disconnect(let reason, let reconnect) = CableCodec.decode(#"{"type":"disconnect","reason":"unauthorized"}"#) else {
            return XCTFail("expected disconnect")
        }
        XCTAssertEqual(reason, "unauthorized")
        XCTAssertTrue(reconnect)
    }

    func testDecodeEvent() throws {
        let frame = """
        {
          "identifier": "{\\"channel\\":\\"RoomChannel\\",\\"pubsub_token\\":\\"tok\\"}",
          "message": {
            "event": "message.created",
            "data": {
              "id": 101,
              "content": "Ответ агента",
              "message_type": 1,
              "echo_id": "echo-9",
              "conversation_id": 7,
              "sender": { "type": "user" }
            }
          }
        }
        """
        guard case .event(let name, let data, _) = CableCodec.decode(frame) else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(name, "message.created")
        let event = RealtimeEvent.fromCableEvent(name: name, data: data)
        guard case .messageCreated(let dto, let echoID)? = event else {
            return XCTFail("expected messageCreated")
        }
        XCTAssertEqual(dto.id, 101)
        XCTAssertEqual(dto.content, "Ответ агента")
        XCTAssertEqual(echoID, "echo-9")
    }

    func testTypingEvent() throws {
        let frame = """
        {
          "message": {
            "event": "conversation.typing_on",
            "data": { "is_private": false, "conversation": { "id": 7, "inbox_id": 3 } }
          }
        }
        """
        guard case .event(let name, let data, _) = CableCodec.decode(frame) else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(RealtimeEvent.fromCableEvent(name: name, data: data), .typing(conversationID: 7, on: true, inboxID: 3))
    }

    func testPrivateTypingDropped() {
        let data: [String: JSONValue] = [
            "is_private": .bool(true),
            "conversation": .object(["id": .int(7)]),
        ]
        XCTAssertNil(RealtimeEvent.fromCableEvent(name: "conversation.typing_on", data: data))
    }

    func testSubscribeFrameIsDeterministic() throws {
        let frame = CableCodec.subscribeFrame(pubsubToken: "tok")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: String])
        XCTAssertEqual(object["command"], "subscribe")
        XCTAssertEqual(object["identifier"], #"{"channel":"RoomChannel","pubsub_token":"tok"}"#)
        XCTAssertEqual(CableCodec.identifier(pubsubToken: "tok"), #"{"channel":"RoomChannel","pubsub_token":"tok"}"#)
    }

    func testPresenceFrame() throws {
        let frame = CableCodec.presenceFrame(pubsubToken: "tok")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: String])
        XCTAssertEqual(object["command"], "message")
        let data = try XCTUnwrap(object["data"])
        XCTAssertTrue(data.contains(#""action":"update_presence"#))
    }

    func testGarbageDropped() {
        XCTAssertNil(CableCodec.decode("not json"))
        XCTAssertNil(CableCodec.decode(#"{"type":"unknown_type"}"#))
        XCTAssertNil(CableCodec.decode(#"{"message":{}}"#))
    }
}
