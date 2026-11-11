import CryptoKit
import dnssd
import Foundation
import TouchyKit

/// WebSocket server for the paired phone on a dual-stack BSD socket (all
/// interfaces: LAN and Tailscale), advertised over Bonjour. Not NWListener:
/// its connections never complete on the Tailscale interface (ledger, Task 11).
/// First binary message: handshake hello. Then SecureChannel frames of JSON.
final class PhoneServer: @unchecked Sendable {
    static let port: UInt16 = 47311
    static let bonjourType = "_touchytua._tcp"

    private let store: PairingStore
    private let router: PhoneRouter
    private let macName: String
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: PhoneConnection] = [:]
    private var bonjour: DNSServiceRef?

    init(store: PairingStore, router: PhoneRouter, macName: String) {
        self.store = store
        self.router = router
        self.macName = macName
    }

    func start(port: UInt16 = PhoneServer.port) throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var off: Int32 = 0, on: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "touchytua.phone-accept"
        thread.start()
        advertise(port: port)
        Log.info("phone server listening on port \(port)")
    }

    /// Sends to every authenticated phone connection.
    func push(_ message: MacToPhone) {
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        for c in all { c.send(message) }
    }

    private func advertise(port: UInt16) {
        var ref: DNSServiceRef?
        let status = DNSServiceRegister(&ref, 0, 0, macName, Self.bonjourType, nil, nil, port.bigEndian, 0, nil, nil, nil)
        guard status == kDNSServiceErr_NoError, let ref else { Log.info("bonjour: register failed (\(status))"); return }
        DNSServiceSetDispatchQueue(ref, DispatchQueue(label: "touchytua.bonjour"))
        bonjour = ref
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    /// One connection: HTTP upgrade, then a frame loop until close.
    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        func readMore() -> Bool {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return false }
            buffer.append(contentsOf: chunk[0..<n])
            return true
        }
        // Upgrade request (headers capped at 16 KiB).
        var key: String?
        while key == nil {
            guard buffer.count < 16 << 10, readMore() else { close(fd); return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
            key = WebSocket.upgradeKey(fromRequest: buffer[..<end.upperBound])
            buffer.removeSubrange(..<end.upperBound)
            if key == nil { close(fd); return }
        }
        let writer = SocketWriter(fd)
        guard writer.write(WebSocket.handshakeResponse(key: key!)) else { close(fd); return }

        let connection = PhoneConnection(store: store, router: router,
                                         sendFrame: { writer.write(WebSocket.encodeFrame(opcode: WebSocket.opBinary, payload: $0)) },
                                         close: { writer.shutdown() })
        lock.lock(); connections[ObjectIdentifier(connection)] = connection; lock.unlock()
        defer {
            lock.lock(); connections[ObjectIdentifier(connection)] = nil; lock.unlock()
            writer.shutdown()
            close(fd)
        }
        while true {
            do {
                while let frame = try WebSocket.decodeFrame(from: &buffer) {
                    switch frame.opcode {
                    case WebSocket.opBinary, WebSocket.opText: connection.receive(frame.payload)
                    case WebSocket.opPing: _ = writer.write(WebSocket.encodeFrame(opcode: WebSocket.opPong, payload: frame.payload))
                    case WebSocket.opClose:
                        _ = writer.write(WebSocket.encodeFrame(opcode: WebSocket.opClose, payload: Data()))
                        return
                    default: break
                    }
                }
            } catch {
                return
            }
            if writer.isClosed || !readMore() { return }
        }
    }
}

/// Serialized writes to one socket.
final class SocketWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private(set) var isClosed = false

    init(_ fd: Int32) { self.fd = fd }

    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return false }
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, data.count - sent) }
            if n <= 0 { isClosed = true; return false }
            sent += n
        }
        return true
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if !isClosed { isClosed = true; Darwin.shutdown(fd, SHUT_RDWR) }
    }
}

/// Protocol state for one phone connection, transport-agnostic.
final class PhoneConnection: @unchecked Sendable {
    private let store: PairingStore
    private let router: PhoneRouter
    private let sendFrame: @Sendable (Data) -> Bool
    private let closeTransport: @Sendable () -> Void
    private let queue = DispatchQueue(label: "touchytua.phone-connection")
    private var channel: SecureChannel?

    init(store: PairingStore, router: PhoneRouter,
         sendFrame: @escaping @Sendable (Data) -> Bool, close: @escaping @Sendable () -> Void) {
        self.store = store
        self.router = router
        self.sendFrame = sendFrame
        self.closeTransport = close
    }

    func receive(_ data: Data) {
        queue.async { self.handle(data) }
    }

    func send(_ message: MacToPhone) {
        queue.async {
            guard var channel = self.channel,
                  let json = try? JSONEncoder().encode(message),
                  let frame = try? channel.seal(json) else { return }
            self.channel = channel
            _ = self.sendFrame(frame)
        }
    }

    private func handle(_ data: Data) {
        guard var channel else { handshake(data); return }
        guard let plain = try? channel.open(data) else {
            Log.info("phone: dropped undecryptable frame; closing")
            closeTransport()
            return
        }
        self.channel = channel
        // An authenticated frame this build cannot read is a version gap,
        // not an attack: answer and keep the connection.
        guard let message = try? JSONDecoder().decode(PhoneToMac.self, from: plain) else {
            send(.error(code: "bad_message"))
            return
        }
        if case let .hello(name) = message {
            var state = store.load()
            state.deviceName = name
            store.save(state)
        }
        let router = self.router
        Task {
            for reply in await router.handle(message) { self.send(reply) }
        }
    }

    private func handshake(_ hello: Data) {
        do {
            let accepted = try Handshake.macAccept(
                hello: hello, macStatic: try store.macKey(), ephemeral: Curve25519.KeyAgreement.PrivateKey(),
                expectedSecret: store.activeSecret(now: Date()), knownPhoneKey: store.load().phoneKey)
            if accepted.isNewPairing { store.completePairing(phoneKey: accepted.phoneKey, deviceName: nil) }
            channel = SecureChannel(keys: accepted.keys)
            _ = sendFrame(accepted.reply)
            Log.info("phone: handshake accepted, protocol v\(Handshake.peerVersion(in: hello))\(accepted.isNewPairing ? " (new pairing)" : "")")
        } catch {
            Log.info("phone: handshake rejected (\(error)); closing")
            closeTransport()
        }
    }
}
