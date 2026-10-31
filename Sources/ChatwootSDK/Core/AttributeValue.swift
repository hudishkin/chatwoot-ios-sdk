import Foundation

/// Calendar date without a time zone; sent to the server as `yyyy-MM-dd`.
public struct AttributeDate: Equatable, Codable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        guard day >= 1 && day <= AttributeDate.daysIn(year: year, month: month) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `yyyy-MM-dd`; `nil` on a malformed or nonexistent date.
    public init?(parsing text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = AttributeDate(year: y, month: m, day: d) else { return nil }
        self = date
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = AttributeDate(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected yyyy-MM-dd date")
        }
        self = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    private static func daysIn(year: Int, month: Int) -> Int {
        let days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return month == 2 && isLeap(year) ? 29 : days[month - 1]
    }
}

extension AttributeDate: CustomStringConvertible {
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

/// Value of a custom contact or conversation attribute. A date is sent as `yyyy-MM-dd`.
public enum AttributeValue: Equatable, Sendable {
    case text(String)
    case integer(Int64)
    case decimal(Double)
    case bool(Bool)
    case date(AttributeDate)
}

extension AttributeValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .decimal(value)
        } else if let text = try? container.decode(String.self) {
            if let date = AttributeDate(parsing: text) {
                self = .date(date)
            } else {
                self = .text(text)
            }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported attribute value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .date(let value): try container.encode(value)
        }
    }
}
