import Foundation
import Network
import Testing
@testable import TouchyClient

/// A WebSocket server on the loopback interface that echoes every frame.
final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "echo-server")
    private var connections: [NWConnection] = []

    static let bonjourType = "_touchytua-test._tcp"

    /// With `bonjourID`, announces itself the way the daemon does.
    init(bonjourID: String? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        // A service announced from a loopback-only listener is found but
        // never connects, so the announced server listens everywhere.
        if bonjourID == nil { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        listener = try NWListener(using: parameters)
        if let bonjourID {
            listener.service = NWListener.Service(
                name: "test-\(bonjourID)", type: Self.bonjourType, txtRecord: NWTXTRecord(["id": bonjourID]))
        }
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

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

struct TookTooLong: Error {}

/// Runs `work`, cancelling it and failing if it takes longer than `limit`.
func giveUp<T: Sendable>(after limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: limit)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else { throw TookTooLong() }
        return value
    }
}

@Suite struct NWWebSocketTransportTests {
    private func randomID() -> String {
        (0..<16).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
    }

    @Test func findsItsMacAmongSeveralOnTheLocalNetwork() async throws {
        let (mine, other) = (randomID(), randomID())
        let stranger = try EchoServer(bonjourID: other)
        let server = try EchoServer(bonjourID: mine)
        defer { stranger.stop(); server.stop() }
        _ = try await stranger.start()
        _ = try await server.start()
        let echoed = try await giveUp(after: .seconds(10)) {
            let found = try await BonjourBrowser.find(id: mine, type: EchoServer.bonjourType)
            #expect("\(found)".contains("test-\(mine)"))
            let transport = try await NWWebSocketTransport.connect(to: found)
            defer { transport.close() }
            transport.send(Data("over bonjour".utf8))
            return try await transport.receive()
        }
        #expect(echoed == Data("over bonjour".utf8))
    }

    @Test func lookingForAMacThatIsNotThereEndsWhenCancelled() async throws {
        let id = randomID()
        let looking = Task { try await BonjourBrowser.find(id: id, type: EchoServer.bonjourType) }
        try await Task.sleep(for: .milliseconds(100))
        looking.cancel()
        let result = await looking.result
        #expect(throws: (any Error).self) { try result.get() }
    }

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

    // The next three: cancellation that lands before the wait has begun.
    // Network.framework never calls back on something cancelled before it
    // started, so each of these used to wait forever. It happens for real
    // when one route wins the race while another is still setting up.

    @Test func aConnectCancelledBeforeItStartsStillEnds() async throws {
        let server = try EchoServer()
        defer { server.stop() }
        let endpoint = try #require(Endpoint("lan:127.0.0.1:\(try await server.start())"))
        let finished = Flag()
        let connecting = Task {
            _ = try? await NWWebSocketTransport.connect(to: endpoint)
            finished.set()
        }
        connecting.cancel()
        try await Task.sleep(for: .milliseconds(500))
        #expect(finished.isSet)
    }

    @Test func aSearchCancelledBeforeItStartsStillEnds() async throws {
        let finished = Flag()
        let looking = Task {
            _ = try? await BonjourBrowser.find(id: "0000000000000000", type: EchoServer.bonjourType)
            finished.set()
        }
        looking.cancel()
        try await Task.sleep(for: .milliseconds(500))
        #expect(finished.isSet)
    }

    @Test func aReceiveCancelledBeforeItStartsStillEnds() async throws {
        let server = try EchoServer()
        defer { server.stop() }
        let port = try await server.start()
        let transport = try await NWWebSocketTransport.connect(to: try #require(Endpoint("lan:127.0.0.1:\(port)")))
        let finished = Flag()
        let waiting = Task {
            _ = try? await transport.receive()
            finished.set()
        }
        waiting.cancel()
        try await Task.sleep(for: .milliseconds(500))
        #expect(finished.isSet)
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
