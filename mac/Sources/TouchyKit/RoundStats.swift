import Foundation

/// Per-round numbers for the "This Round" detail, read from the transcript.
public enum RoundStats {
    /// Output tokens of the assistant messages written at or after `since`.
    /// Nil when the transcript cannot be read.
    ///
    /// Transcripts reach hundreds of MB, so only the end of the file is
    /// read: `window` bytes first, four times more each time the window
    /// still starts inside the round. `onRead` reports how many reads it took.
    public static func outputTokens(
        transcriptPath: String, since: Date, window: Int = 1 << 20, onRead: (Int) -> Void = { _ in }
    ) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var window = max(window, 1), reads = 0
        while true {
            let start = max(size - window, 0)
            try? handle.seek(toOffset: UInt64(start))
            var data = ((try? handle.read(upToCount: size - start)) ?? nil) ?? Data()
            reads += 1
            if start > 0 {
                // The window opens mid-line: drop that truncated line.
                data = data.firstIndex(of: 0x0A).map { data.suffix(from: $0 + 1) } ?? Data()
            }
            var total = 0, reachedBeforeRound = false
            for line in data.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let stamp = object["timestamp"] as? String, let date = iso.date(from: stamp) else { continue }
                guard date >= since else { reachedBeforeRound = true; continue }
                guard object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let tokens = usage["output_tokens"] as? Int else { continue }
                total += tokens
            }
            if reachedBeforeRound || start == 0 {
                onRead(reads)
                return total
            }
            window = window > size / 4 ? size : window * 4
        }
    }
}
