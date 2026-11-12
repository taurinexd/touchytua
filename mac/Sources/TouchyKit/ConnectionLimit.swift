import Foundation

/// Caps how many connections are served at once. The phone port is open to
/// the local network and every connection holds a thread: without a cap,
/// anyone there could exhaust them.
public final class ConnectionLimit: @unchecked Sendable {
    private let max: Int
    private let lock = NSLock()
    private var open = 0

    public init(max: Int) {
        self.max = max
    }

    /// True when there is room; the caller then owes one `release()`.
    public func admit() -> Bool {
        lock.withLock {
            guard open < max else { return false }
            open += 1
            return true
        }
    }

    public func release() {
        lock.withLock { open = Swift.max(0, open - 1) }
    }
}
