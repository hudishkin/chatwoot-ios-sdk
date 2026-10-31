import Foundation

/// Arbitrary JSON value for the contract's free-form fields (`content_attributes`,
/// `custom_attributes`, realtime event payloads).
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Int64.self) { self = .int(value); return }
            if let value = try? container.decode(Double.self) { self = .double(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
            if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    /// Bridge from a `JSONSerialization` result (`[String: Any]`, `NSNumber`, …).
    public init?(bridging any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = JSONValue.number(value)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.compactMap(JSONValue.init(bridging:)))
        case let value as [String: Any]:
            var object: [String: JSONValue] = [:]
            object.reserveCapacity(value.count)
            for (key, element) in value { object[key] = JSONValue(bridging: element) }
            self = .object(object)
        default:
            return nil
        }
    }

    /// The value in a form suitable for `JSONSerialization`.
    public var bridgedObject: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return NSNumber(value: value)
        case .double(let value): return NSNumber(value: value)
        case .bool(let value): return NSNumber(value: value)
        case .array(let value): return value.map(\.bridgedObject)
        case .object(let value): return value.mapValues(\.bridgedObject)
        case .null: return NSNull()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    private static func number(_ value: NSNumber) -> JSONValue {
        switch CFNumberGetType(value) {
        case .floatType, .float32Type, .float64Type, .cgFloatType:
            return .double(value.doubleValue)
        default:
            return .int(value.int64Value)
        }
    }

    /// Decodes the value into a concrete `Decodable` type (e.g. event data into `MessageDTO`).
    public func decoded<T: Decodable>(as type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: bridgedObject)
        return try decoder.decode(T.self, from: data)
    }
}
