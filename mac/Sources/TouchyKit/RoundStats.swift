import Foundation

/// Per-round numbers for the "This Round" detail, read from the transcript.
public enum RoundStats {
    /// Output tokens of the assistant messages written at or after `since`.
    /// Nil when the transcript cannot be read.
    public static func outputTokens(transcriptPath: String, since: Date) -> Int? {
        guard let data = FileManager.default.contents(atPath: transcriptPath) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var total = 0
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let stamp = object["timestamp"] as? String,
                  let date = iso.date(from: stamp), date >= since,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let tokens = usage["output_tokens"] as? Int else { continue }
            total += tokens
        }
        return total
    }
}
