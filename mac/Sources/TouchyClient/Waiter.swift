import Foundation

/// Turns one callback into an `await`, resolved by whoever comes first: the
/// callback or the task's cancellation, including a cancellation that lands
/// before the wait has begun. Network.framework does not call back on an
/// object cancelled before it was started, so a wait that relied on its
/// callback alone could last forever.
final class Waiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    /// The first call wins; later ones are ignored.
    func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    /// The resolved value. Throws `CancellationError` if the task is
    /// cancelled first, at any point.
    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }
}
