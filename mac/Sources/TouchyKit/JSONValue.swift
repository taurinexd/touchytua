import Foundation

/// A JSON value that survives a Codable round trip without losing shape.
/// Hook payloads are open-ended, so they travel as this instead of a schema.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        case .null: try c.encodeNil()
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }
}
