import Foundation

/// The plugin release this code belongs to. The Mac says it to the phone;
/// the phone compares it with the one it was built with, and so knows a
/// Mac left behind.
public enum Release {
    /// The same as in the plugin's manifest.
    public static let plugin = "0.3.13"

    /// True when `version` comes before `wanted`. A Mac that says no
    /// version, or one that cannot be read, is older than any that does.
    public static func isOlder(_ version: String?, than wanted: String) -> Bool {
        guard let mine = version.flatMap(numbers), let theirs = numbers(wanted) else { return true }
        for index in 0..<max(mine.count, theirs.count) {
            let a = index < mine.count ? mine[index] : 0, b = index < theirs.count ? theirs[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int]? {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map { Int($0) }
        return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
    }
}
