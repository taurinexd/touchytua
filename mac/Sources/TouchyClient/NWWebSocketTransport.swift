import Foundation
import Network

/// WebSocket over Network.framework. App Transport Security does not apply
/// to this framework, so plain `ws://` to a Tailscale name needs no
/// exception; confidentiality comes from the channel on top.
public final class NWWebSocketTransport: FrameTransport, @unchecked Sendable {
    private let connection: NWConnection

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// What `ConnectionManager` dials with: an address as text, in.
    public static let dial: ConnectionManager.Dial = { text in
        guard let endpoint = Endpoint(text) else { throw LinkError.closed }
        return try await connect(to: endpoint)
    }

    /// Connects and completes the WebSocket upgrade. Fails as soon as the
    /// system reports the host unreachable instead of waiting for the
    /// network to change, and gives up when the calling task is cancelled.
    public static func connect(to endpoint: Endpoint) async throws -> NWWebSocketTransport {
        switch endpoint {
        case let .bonjour(id):
            return try await connect(to: try await BonjourBrowser.find(id: id))
        case let .lan(host, port), let .tailscale(host, port):
            let literal = host.contains(":") ? "[\(host)]" : host
            guard let url = URL(string: "ws://\(literal):\(port)/") else { throw LinkError.closed }
            return try await connect(to: .url(url))
        }
    }

    static func connect(to endpoint: NWEndpoint) async throws -> NWWebSocketTransport {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(to: endpoint, using: parameters)
        let once = Once()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { continuation.resume() }
                    case let .failed(error), let .waiting(error):
                        if once.claim() {
                            connection.cancel()
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        if once.claim() { continuation.resume(throwing: LinkError.closed) }
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "touchytua.transport"))
            }
        } onCancel: {
            connection.cancel()
        }
        connection.stateUpdateHandler = nil
        return NWWebSocketTransport(connection)
    }

    public func send(_ frame: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        // NWConnection sends in call order; a failure surfaces in `receive`.
        connection.send(content: frame, contentContext: context, isComplete: true, completion: .idempotent)
    }

    public func receive() async throws -> Data {
        let connection = self.connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.nextDataFrame(on: connection, continuation)
            }
        } onCancel: {
            // Network.framework has no way to withdraw one receive.
            connection.cancel()
        }
    }

    private static func nextDataFrame(on connection: NWConnection, _ continuation: CheckedContinuation<Data, any Error>) {
        connection.receiveMessage { data, context, _, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .binary, .text:
                continuation.resume(returning: data ?? Data())
            case .ping, .pong, .cont:
                nextDataFrame(on: connection, continuation)
            default:
                // A close frame, or the stream ended without one.
                continuation.resume(throwing: LinkError.closed)
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}
