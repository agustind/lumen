import Foundation

/// An arbitrary JSON value. Used to round-trip payloads we only partially model
/// (addon manifests, behavior hints) without dropping unknown fields.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    /// Re-decodes this value as a concrete `Decodable` type.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSON.decoder.decode(type, from: data)
    }
}

/// Decodes an array while silently skipping elements that fail to decode.
/// Addons are third-party code; one malformed item must not hide a whole catalog.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(JSONValue.self)
            }
        }
        elements = result
    }
}

extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        lossy(LossyArray<T>.self, key)?.elements ?? []
    }

    /// Accepts strings or numbers (addons are inconsistent about e.g. `imdbRating`).
    func lossyString(_ key: Key) -> String? {
        if let value = lossy(String.self, key) { return value }
        if let value = lossy(Double.self, key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        return nil
    }

    func lossyInt(_ key: Key) -> Int? {
        if let value = lossy(Int.self, key) { return value }
        if let value = lossy(Double.self, key) { return Int(value) }
        if let value = lossy(String.self, key) { return Int(value) }
        return nil
    }

    func lossyURL(_ key: Key) -> URL? {
        guard let string = lossy(String.self, key)?.trimmingCharacters(in: .whitespaces),
              !string.isEmpty else { return nil }
        return URL(string: string) ?? URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
    }

    func lossyDate(_ key: Key) -> Date? {
        guard let string = lossy(String.self, key) else { return nil }
        return JSON.parseDate(string)
    }
}

enum JSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let millis = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: millis / 1000)
            }
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(string)")
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    private static let lock = NSLock()

    static func parseDate(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractionalFormatter.date(from: string)
            ?? plainFormatter.date(from: string)
            ?? dateOnlyFormatter.date(from: string)
    }

    /// Stremio's API uses millisecond-precision ISO-8601 timestamps.
    static func formatDate(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractionalFormatter.string(from: date)
    }
}
