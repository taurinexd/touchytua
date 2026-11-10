import Foundation
// Ported from Meowtch (VedettaKit/OrderedJSONDocument.swift, MIT, same author).

/// A JSON(-with-`//`-comments) document that remembers what the user's file
/// actually looked like: member order, comment lines, blank-line grouping and
/// the original literal text of every scalar. Merging a transformed
/// dictionary back in only rewrites what actually changed, so an additive
/// hook merge cannot destroy the surrounding config formatting.
public struct OrderedJSONDocument {
    indirect enum Node {
        case object(ObjectNode)
        case array(ArrayNode)
        /// Original literal text, verbatim (string with quotes, number as
        /// typed by the user, true/false/null).
        case scalar(String)
    }

    struct ObjectNode {
        var members: [Member] = []
        var trailingTrivia: [String] = []
    }

    struct Member {
        /// Comment lines (verbatim, `//…`) above the member; "" = blank line.
        var leadingTrivia: [String] = []
        var key: String
        var value: Node
        /// A `//…` comment on the same line, after the value/comma.
        var trailingComment: String?
    }

    struct ArrayNode {
        var elements: [Element] = []
        var trailingTrivia: [String] = []
    }

    struct Element {
        var leadingTrivia: [String] = []
        var value: Node
        var trailingComment: String?
    }

    var root: Node

    // MARK: - Parsing

    private struct Token {
        enum Kind {
            case punct(Character)
            case string(String)   // raw, including quotes
            case literal(String)  // number / true / false / null, raw
            case comment(String)  // "//…", verbatim
        }
        var kind: Kind
        var line: Int
    }

    public enum ParseError: Error { case malformed }

    public init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParseError.malformed
        }
        var tokens: [Token] = []
        var line = 1
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" {
                line += 1
                index = text.index(after: index)
            } else if character.isWhitespace {
                index = text.index(after: index)
            } else if character == "/", text.index(after: index) < text.endIndex,
                      text[text.index(after: index)] == "/" {
                var end = index
                while end < text.endIndex, text[end] != "\n" { end = text.index(after: end) }
                tokens.append(Token(kind: .comment(String(text[index..<end])), line: line))
                index = end
            } else if character == "\"" {
                var end = text.index(after: index)
                var escaped = false
                while end < text.endIndex {
                    let byte = text[end]
                    if escaped { escaped = false }
                    else if byte == "\\" { escaped = true }
                    else if byte == "\"" { break }
                    end = text.index(after: end)
                }
                guard end < text.endIndex else { throw ParseError.malformed }
                end = text.index(after: end)
                tokens.append(Token(kind: .string(String(text[index..<end])), line: line))
                index = end
            } else if "{}[]:,".contains(character) {
                tokens.append(Token(kind: .punct(character), line: line))
                index = text.index(after: index)
            } else {
                var end = index
                while end < text.endIndex, !"{}[]:,\"".contains(text[end]),
                      !text[end].isWhitespace, text[end] != "/" {
                    end = text.index(after: end)
                }
                guard end > index else { throw ParseError.malformed }
                tokens.append(Token(kind: .literal(String(text[index..<end])), line: line))
                index = end
            }
        }

        var parser = Parser(tokens: tokens)
        root = try parser.parseValue()
        try parser.expectEnd()
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0
        /// Line of the last structural token consumed, to rebuild blank-line
        /// grouping (a gap of 2+ lines re-emits one blank line).
        var lastLine = 0

        mutating func parseValue() throws -> Node {
            _ = collectTrivia()   // stray leading comments before the root
            guard let token = peekStructural() else { throw ParseError.malformed }
            switch token.kind {
            case .punct("{"): return try parseObject()
            case .punct("["): return try parseArray()
            case .string(let raw), .literal(let raw):
                advanceStructural()
                return .scalar(raw)
            default: throw ParseError.malformed
            }
        }

        mutating func parseObject() throws -> Node {
            advanceStructural() // {
            var node = ObjectNode()
            while true {
                let trivia = collectTrivia()
                guard let token = peekStructural() else { throw ParseError.malformed }
                if case .punct("}") = token.kind {
                    advanceStructural()
                    node.trailingTrivia = trivia.filter { !$0.isEmpty }
                    return .object(node)
                }
                guard case .string(let rawKey) = token.kind else { throw ParseError.malformed }
                advanceStructural()
                guard let colon = peekStructural(), case .punct(":") = colon.kind else {
                    throw ParseError.malformed
                }
                advanceStructural()
                let value = try parseInnerValue()
                var member = Member(
                    leadingTrivia: trivia,
                    key: Self.decodeString(rawKey),
                    value: value
                )
                consumeOptionalComma()
                member.trailingComment = takeSameLineComment()
                node.members.append(member)
            }
        }

        mutating func parseArray() throws -> Node {
            advanceStructural() // [
            var node = ArrayNode()
            while true {
                let trivia = collectTrivia()
                guard let token = peekStructural() else { throw ParseError.malformed }
                if case .punct("]") = token.kind {
                    advanceStructural()
                    node.trailingTrivia = trivia.filter { !$0.isEmpty }
                    return .array(node)
                }
                let value = try parseInnerValue()
                var element = Element(leadingTrivia: trivia, value: value)
                consumeOptionalComma()
                element.trailingComment = takeSameLineComment()
                node.elements.append(element)
            }
        }

        private mutating func parseInnerValue() throws -> Node {
            guard let token = peekStructural() else { throw ParseError.malformed }
            switch token.kind {
            case .punct("{"): return try parseObject()
            case .punct("["): return try parseArray()
            case .string(let raw), .literal(let raw):
                advanceStructural()
                return .scalar(raw)
            default: throw ParseError.malformed
            }
        }

        mutating func expectEnd() throws {
            _ = collectTrivia()
            guard position == tokens.count else { throw ParseError.malformed }
        }

        /// Comments (and blank-line markers) up to the next structural token.
        private mutating func collectTrivia() -> [String] {
            var trivia: [String] = []
            while position < tokens.count, case .comment(let text) = tokens[position].kind {
                if tokens[position].line > lastLine + 1, lastLine > 0 {
                    trivia.append("")
                }
                trivia.append(text)
                lastLine = tokens[position].line
                position += 1
            }
            if position < tokens.count, tokens[position].line > lastLine + 1, lastLine > 0 {
                trivia.append("")
            }
            return trivia
        }

        private mutating func consumeOptionalComma() {
            if let token = peekStructural(), case .punct(",") = token.kind {
                advanceStructural()
            }
        }

        /// A comment on the same line as the value just consumed.
        private mutating func takeSameLineComment() -> String? {
            guard position < tokens.count,
                  case .comment(let text) = tokens[position].kind,
                  tokens[position].line == lastLine else { return nil }
            position += 1
            return text
        }

        private mutating func peekStructural() -> Token? {
            var cursor = position
            while cursor < tokens.count {
                if case .comment = tokens[cursor].kind { cursor += 1 } else {
                    return tokens[cursor]
                }
            }
            return nil
        }

        private mutating func advanceStructural() {
            while position < tokens.count {
                if case .comment = tokens[position].kind { position += 1 } else {
                    lastLine = tokens[position].line
                    position += 1
                    return
                }
            }
        }

        static func decodeString(_ raw: String) -> String {
            (try? JSONSerialization.jsonObject(
                with: Data(raw.utf8), options: .fragmentsAllowed
            ) as? String) ?? String(raw.dropFirst().dropLast())
        }
    }

    // MARK: - Plain-value bridge (for equality checks)

    static func plainValue(of node: Node) -> Any {
        switch node {
        case .object(let object):
            var dictionary: [String: Any] = [:]
            for member in object.members {
                dictionary[member.key] = plainValue(of: member.value)
            }
            return dictionary
        case .array(let array):
            return array.elements.map { plainValue(of: $0.value) }
        case .scalar(let raw):
            return (try? JSONSerialization.jsonObject(
                with: Data(raw.utf8), options: .fragmentsAllowed
            )) ?? NSNull()
        }
    }

    private static func isEqual(_ node: Node, _ value: Any) -> Bool {
        let mine = plainValue(of: node) as AnyObject
        return mine.isEqual(value as AnyObject)
    }

    // MARK: - Merge

    /// Applies a transformed dictionary while touching as little of the
    /// original document as possible: unchanged values keep their literal
    /// text and comments, removed keys disappear, new keys append at the end
    /// of their object (sorted, for determinism).
    public func merged(with value: [String: Any]) -> OrderedJSONDocument {
        OrderedJSONDocument(root: Self.mergedNode(root, with: value))
    }

    init(root: Node) { self.root = root }

    private static func mergedNode(_ node: Node, with value: Any) -> Node {
        if isEqual(node, value) { return node }
        switch (node, value) {
        case (.object(var object), let dictionary as [String: Any]):
            var seen = Set<String>()
            object.members = object.members.compactMap { member in
                guard let updated = dictionary[member.key] else { return nil }
                seen.insert(member.key)
                var kept = member
                kept.value = mergedNode(member.value, with: updated)
                return kept
            }
            for key in dictionary.keys.sorted() where !seen.contains(key) {
                object.members.append(Member(
                    key: key,
                    value: freshNode(dictionary[key] as Any)
                ))
            }
            return .object(object)
        default:
            // Arrays and scalars the transform rebuilt are rewritten whole:
            // there is no per-element identity to diff against.
            return freshNode(value)
        }
    }

    private static func freshNode(_ value: Any) -> Node {
        switch value {
        case let dictionary as [String: Any]:
            var object = ObjectNode()
            for key in dictionary.keys.sorted() {
                object.members.append(Member(
                    key: key,
                    value: freshNode(dictionary[key] as Any)
                ))
            }
            return .object(object)
        case let array as [Any]:
            var node = ArrayNode()
            node.elements = array.map { Element(value: freshNode($0)) }
            return .array(node)
        default:
            let data = (try? JSONSerialization.data(
                withJSONObject: value, options: .fragmentsAllowed
            )) ?? Data("null".utf8)
            return .scalar(String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Serialization

    public func serialized() -> String {
        Self.render(root, indent: 0) + "\n"
    }

    private static func render(_ node: Node, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch node {
        case .scalar(let raw):
            return raw
        case .object(let object):
            guard !object.members.isEmpty || !object.trailingTrivia.isEmpty else { return "{}" }
            var lines: [String] = ["{"]
            for (offset, member) in object.members.enumerated() {
                lines.append(contentsOf: triviaLines(member.leadingTrivia, pad: inner))
                let comma = offset == object.members.count - 1 ? "" : ","
                let trailer = member.trailingComment.map { " \($0)" } ?? ""
                let rendered = render(member.value, indent: indent + 1)
                lines.append("\(inner)\(encodeKey(member.key)): \(rendered)\(comma)\(trailer)")
            }
            lines.append(contentsOf: triviaLines(object.trailingTrivia, pad: inner))
            lines.append("\(pad)}")
            return lines.joined(separator: "\n")
        case .array(let array):
            guard !array.elements.isEmpty || !array.trailingTrivia.isEmpty else { return "[]" }
            var lines: [String] = ["["]
            for (offset, element) in array.elements.enumerated() {
                lines.append(contentsOf: triviaLines(element.leadingTrivia, pad: inner))
                let comma = offset == array.elements.count - 1 ? "" : ","
                let trailer = element.trailingComment.map { " \($0)" } ?? ""
                let rendered = render(element.value, indent: indent + 1)
                lines.append("\(inner)\(rendered)\(comma)\(trailer)")
            }
            lines.append(contentsOf: triviaLines(array.trailingTrivia, pad: inner))
            lines.append("\(pad)]")
            return lines.joined(separator: "\n")
        }
    }

    private static func triviaLines(_ trivia: [String], pad: String) -> [String] {
        trivia.map { $0.isEmpty ? "" : "\(pad)\($0)" }
    }

    private static func encodeKey(_ key: String) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: key, options: .fragmentsAllowed
        )) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
