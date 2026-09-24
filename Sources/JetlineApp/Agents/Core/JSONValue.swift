import Foundation

/// A loosely-typed JSON value. Both agent protocols are large, versioned
/// independently of Jetline and grow fields constantly, so the mappers read
/// the handful of fields they care about from this instead of decoding into
/// rigid `Codable` structs that would throw on the first renamed field.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Accessors

    subscript(key: String) -> JSONValue? {
        if case let .object(dict) = self { return dict[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case let .array(items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var bool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var int: Int? {
        switch self {
        case let .int(i): return Int(i)
        case let .double(d) where d.rounded() == d: return Int(d)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case let .int(i): return Double(i)
        case let .double(d): return d
        default: return nil
        }
    }

    var array: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var object: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: Serialization

    /// Parse one JSON document. `JSONSerialization` rather than
    /// `JSONDecoder`: it's several times faster on the multi-kilobyte lines
    /// these CLIs emit (init messages, tool results), and both run on every
    /// streamed token.
    static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: object)
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let dict as [String: Any]:
            self = .object(dict.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .int(i): return i
        case let .double(d): return d
        case let .string(s): return s
        case let .array(a): return a.map(\.foundationObject)
        case let .object(o): return o.mapValues(\.foundationObject)
        }
    }

    /// Compact single-line encoding, suitable for NDJSON framing: newlines
    /// inside strings are escaped by the serializer, so the output never
    /// contains a raw `\n`.
    func serialized(sortedKeys: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if sortedKeys { options.insert(.sortedKeys) }
        return (try? JSONSerialization.data(withJSONObject: foundationObject, options: options)) ?? Data("null".utf8)
    }

    func serializedString(sortedKeys: Bool = false) -> String {
        String(decoding: serialized(sortedKeys: sortedKeys), as: UTF8.self)
    }

    /// Multi-line rendering for display (tool inputs in the chat timeline).
    func prettyPrinted() -> String {
        let options: JSONSerialization.WritingOptions = [
            .fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: foundationObject, options: options) else {
            return serializedString()
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(b): try container.encode(b)
        case let .int(i): try container.encode(i)
        case let .double(d): try container.encode(d)
        case let .string(s): try container.encode(s)
        case let .array(a): try container.encode(a)
        case let .object(o): try container.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new }))
    }
    init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    /// `.string` for non-nil strings, `.null` otherwise — for optional
    /// request parameters.
    static func optional(_ s: String?) -> JSONValue {
        s.map(JSONValue.string) ?? .null
    }
}
