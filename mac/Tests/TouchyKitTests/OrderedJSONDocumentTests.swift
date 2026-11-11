import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

struct OrderedJSONDocumentTests {
    private let source = """
    {
      // model comes first on purpose
      "model": "opus",
      "hooks": {
        "Stop": [
          { "hooks": [{ "command": "afplay done.wav", "type": "command" }] }
        ]
      },

      "statusLine": { "command": "/usr/local/bin/mystatus", "type": "command" }, // mine
      "timeout": 86400
    }
    """

    private func plain(_ document: OrderedJSONDocument) -> [String: Any] {
        OrderedJSONDocument.plainValue(of: document.root) as? [String: Any] ?? [:]
    }

    @Test func roundTripPreservesOrderCommentsAndLiterals() throws {
        let document = try OrderedJSONDocument(data: Data(source.utf8))
        let output = document.serialized()
        #expect(output.contains("// model comes first on purpose"))
        #expect(output.contains("// mine"))
        #expect(output.contains("\"timeout\": 86400"))
        // Member order survives: model before hooks before statusLine.
        let model = try #require(output.range(of: "\"model\""))
        let hooks = try #require(output.range(of: "\"hooks\""))
        let status = try #require(output.range(of: "\"statusLine\""))
        #expect(model.lowerBound < hooks.lowerBound)
        #expect(hooks.lowerBound < status.lowerBound)
        // The blank line between sections is grouped back.
        #expect(output.contains("\n\n"))
    }

    @Test func mergeTouchesOnlyChangedValues() throws {
        let document = try OrderedJSONDocument(data: Data(source.utf8))
        var updated = plain(document)
        var hooks = updated["hooks"] as? [String: Any] ?? [:]
        hooks["SessionStart"] = [["hooks": [["command": "vedetta", "type": "command"]]]]
        updated["hooks"] = hooks

        let output = document.merged(with: updated).serialized()
        // Untouched parts keep their comments, order and literals…
        #expect(output.contains("// model comes first on purpose"))
        #expect(output.contains("// mine"))
        #expect(output.contains("afplay done.wav"))
        #expect(output.contains("\"timeout\": 86400"))
        // …and the addition landed inside hooks.
        #expect(output.contains("\"SessionStart\""))
        let reparsed = try OrderedJSONDocument(data: Data(output.utf8))
        let value = plain(reparsed)
        #expect((value["hooks"] as? [String: Any])?.count == 2)
    }

    @Test func mergeDropsRemovedKeys() throws {
        let document = try OrderedJSONDocument(data: Data(source.utf8))
        var updated = plain(document)
        updated.removeValue(forKey: "statusLine")

        let output = document.merged(with: updated).serialized()
        #expect(!output.contains("statusLine"))
        #expect(output.contains("// model comes first on purpose"))
    }

    @Test func mergeIsSemanticallyIdenticalToTheTransformResult() throws {
        let document = try OrderedJSONDocument(data: Data(source.utf8))
        var updated = plain(document)
        updated["timeout"] = 5
        updated["extra"] = ["a": 1]

        let output = document.merged(with: updated).serialized()
        let reparsed = plain(try OrderedJSONDocument(data: Data(output.utf8)))
        #expect((reparsed as NSDictionary).isEqual(to: updated))
    }
}
