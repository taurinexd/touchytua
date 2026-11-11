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
        let found = Waiter<NWEndpoint>()
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .bonjour(txt) = result.metadata, txt["id"] == id else { continue }
                found.resolve(.success(result.endpoint))
                return
            }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case let .failed(error), let .waiting(error): found.resolve(.failure(error))
            case .cancelled: found.resolve(.failure(LinkError.closed))
            default: break
            }
        }
        browser.start(queue: DispatchQueue(label: "touchytua.bonjour-browser"))
        defer { browser.cancel() }
        return try await found.value()
    }
}
