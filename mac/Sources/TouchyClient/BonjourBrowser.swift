import Foundation
import Network
import TouchyProtocol

public enum BonjourBrowser {
    /// Waits for a Mac announcing `id` on the local network and returns
    /// where to connect. Has no deadline of its own: it ends when found,
    /// when browsing fails (for instance, permission denied), or when the
    /// calling task is cancelled.
    public static func find(id: String, type: String = Discovery.serviceType) async throws -> NWEndpoint {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        guard case let .bonjour(txt) = result.metadata, txt["id"] == id else { continue }
                        if once.claim() {
                            browser.cancel()
                            continuation.resume(returning: result.endpoint)
                        }
                        return
                    }
                }
                browser.stateUpdateHandler = { state in
                    switch state {
                    case let .failed(error), let .waiting(error):
                        if once.claim() {
                            browser.cancel()
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        if once.claim() { continuation.resume(throwing: LinkError.closed) }
                    default:
                        break
                    }
                }
                browser.start(queue: DispatchQueue(label: "touchytua.bonjour-browser"))
            }
        } onCancel: {
            browser.cancel()
        }
    }
}

/// Lets exactly one of several callbacks resume a continuation.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
