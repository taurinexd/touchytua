import Foundation
import Network
import Testing
@testable import TouchyClient

/// A WebSocket server on the loopback interface that echoes every frame.
final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "echo-server")
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening; returns the port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.echo(on: connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func echo(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard error == nil, let data, let context else { return }
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
            self?.echo(on: connection)
        }
    }

    /// Hangs up on everyone.
    func dropClients() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections = []
        }
    }

    func stop() {
        dropClients()
        listener.cancel()
    }
}

@Suite struct NWWebSocketTransportTests {
    @Test func framesGoOutAndComeBackInOrder() async throws {
        let server = try EchoServer()
        defer { server.stop() }
        let port = try await server.start()
        let transport = try await NWWebSocketTransport.connect(to: try #require(Endpoint("lan:127.0.0.1:\(port)")))
        defer { transport.close() }
        let frames = (0..<20).map { Data("frame \($0)".utf8) }
        frames.forEach(transport.send)
        for frame in frames {
            #expect(try await transport.receive() == frame)
        }
    }

    @Test func aLargeFrameSurvives() async throws {
        let server = try EchoServer()
        defer { server.stop() }
        let port = try await server.start()
        let transport = try await NWWebSocketTransport.connect(to: try #require(Endpoint("lan:127.0.0.1:\(port)")))
        defer { transport.close() }
        let big = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        transport.send(big)
        #expect(try await transport.receive() == big)
    }

    @Test func receiveThrowsWhenTheServerHangsUp() async throws {
        let server = try EchoServer()
        defer { server.stop() }
        let port = try await server.start()
        let transport = try await NWWebSocketTransport.connect(to: try #require(Endpoint("lan:127.0.0.1:\(port)")))
        transport.send(Data("hi".utf8))
        _ = try await transport.receive()
        server.dropClients()
        await #expect(throws: (any Error).self) { _ = try await transport.receive() }
    }

    @Test func nobodyListeningFailsFast() async throws {
        let server = try EchoServer()
        let port = try await server.start()
        server.stop()  // the port is now closed
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await NWWebSocketTransport.connect(to: try #require(Endpoint("lan:127.0.0.1:\(port)")))
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    /// The connection manager's per-address timeout relies on this.
    @Test func cancellingTheTaskEndsAPendingReceive() async throws {
        let server = try EchoServer()
        defer { server.stop() }
        let port = try await server.start()
        let transport = try await NWWebSocketTransport.connect(to: try #require(Endpoint("lan:127.0.0.1:\(port)")))
        let waiting = Task { try await transport.receive() }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        let result = await waiting.result
        #expect(throws: (any Error).self) { try result.get() }
    }

    @Test func cancellingTheTaskEndsAPendingConnect() async throws {
        // 192.0.2.0/24 is reserved for documentation: nothing answers there.
        let endpoint = try #require(Endpoint("lan:192.0.2.1:47311"))
        let connecting = Task { try await NWWebSocketTransport.connect(to: endpoint) }
        try await Task.sleep(for: .milliseconds(100))
        connecting.cancel()
        let started = ContinuousClock.now
        let result = await connecting.result
        #expect(throws: (any Error).self) { try result.get() }
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
