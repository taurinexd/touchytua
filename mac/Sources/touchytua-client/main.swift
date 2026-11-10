import CryptoKit
import Foundation
import TouchyKit

// touchytua-client — simulates the iPhone for end-to-end verification.
//   pair "<qr url>"                      first pairing (uses the one-time secret)
//   watch [seconds]                      print every message from the Mac
//   approve|deny <requestId>
//   answer <requestId> "<question>=<label>"
//   prompt <sessionId> "<text>"
// Global: --via lan|ts (endpoint choice), --key <file> (use another phone key).

// Line-buffered stdout so `watch` output reaches files/pipes immediately.
setvbuf(stdout, nil, _IOLBF, 0)

let stateDir = NSHomeDirectory() + "/.touchytua-client"

/// Splits `--via`/`--key` options from positional arguments.
func parseArguments(_ raw: [String]) -> (positional: [String], via: String?, key: String?) {
    var rest = raw, via: String?, key: String?
    for name in ["--via", "--key"] {
        guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { continue }
        if name == "--via" { via = rest[i + 1] } else { key = rest[i + 1] }
        rest.removeSubrange(i...(i + 1))
    }
    return (rest, via, key)
}

let parsed = parseArguments(Array(CommandLine.arguments.dropFirst()))
let args = parsed.positional
let via = parsed.via
let keyPath = parsed.key ?? stateDir + "/phone-key"

struct ClientState: Codable {
    var macKey: Data
    var endpoints: [String]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("touchytua-client: \(message)\n".utf8))
    exit(1)
}

func phoneKey() -> Curve25519.KeyAgreement.PrivateKey {
    if let raw = FileManager.default.contents(atPath: keyPath),
       let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) { return key }
    let key = Curve25519.KeyAgreement.PrivateKey()
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: keyPath, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600])
    return key
}

func url(for endpoints: [String]) -> URL {
    guard let pick = endpoints.first(where: { via == nil || $0.hasPrefix(via! + ":") }) else {
        fail("no endpoint for --via \(via ?? "")")
    }
    let parts = pick.split(separator: ":", maxSplits: 1)[1]
    return URL(string: "ws://\(parts)")!
}

final class Link {
    let task: URLSessionWebSocketTask
    var channel: SecureChannel

    init(state: ClientState, secret: Data?) async {
        task = URLSession.shared.webSocketTask(with: url(for: state.endpoints))
        task.resume()
        let me = phoneKey(), eph = Curve25519.KeyAgreement.PrivateKey()
        do {
            try await task.send(.data(Handshake.phoneHello(phoneStatic: me, ephemeral: eph, pairingSecret: secret)))
            guard case let .data(reply) = try await task.receive() else { fail("unexpected handshake reply") }
            let keys = try Handshake.phoneFinish(reply: reply, phoneStatic: me, ephemeral: eph,
                                                 macKey: state.macKey, pairingSecret: secret)
            channel = SecureChannel(keys: keys)
        } catch {
            fail("handshake failed: \(error)")
        }
    }

    func send(_ m: PhoneToMac) async throws {
        try await task.send(.data(channel.seal(JSONEncoder().encode(m))))
    }

    func next(timeout: TimeInterval) async -> MacToPhone? {
        let task = self.task
        let frame: Data? = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                guard case let .data(d) = try? await task.receive() else { return nil }
                return d
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let frame, let plain = try? channel.open(frame) else { return nil }
        return try? JSONDecoder().decode(MacToPhone.self, from: plain)
    }
}

func describe(_ m: MacToPhone) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    return String(decoding: (try? enc.encode(m)) ?? Data(), as: UTF8.self)
}

func loadState() -> ClientState {
    guard let data = FileManager.default.contents(atPath: stateDir + "/state.json"),
          let s = try? JSONDecoder().decode(ClientState.self, from: data) else { fail("not paired: run pair first") }
    return s
}

/// Connects, says hello, prints the snapshot, sends `message`, prints replies for `wait` seconds.
func session(_ message: PhoneToMac?, wait: TimeInterval) async {
    let link = await Link(state: loadState(), secret: nil)
    do { try await link.send(.hello(deviceName: "touchytua-client")) } catch { fail("send: \(error)") }
    if let snapshot = await link.next(timeout: 5) { print(describe(snapshot)) } else { fail("no snapshot") }
    if let message {
        do { try await link.send(message) } catch { fail("send: \(error)") }
    }
    let end = Date().addingTimeInterval(wait)
    while Date() < end, let m = await link.next(timeout: end.timeIntervalSinceNow) {
        print(describe(m))
        if case .error = m, message != nil { exit(3) }
    }
}

switch args.first {
case "pair":
    guard args.count >= 2, let payload = try? PairingPayload.parse(url: args[1]) else { fail("usage: pair <url>") }
    let state = ClientState(macKey: payload.macKey, endpoints: payload.endpoints)
    let link = await Link(state: state, secret: payload.secret)
    try? await link.send(.hello(deviceName: "touchytua-client"))
    guard let snapshot = await link.next(timeout: 5) else { fail("no snapshot after pairing") }
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: stateDir + "/state.json", contents: try JSONEncoder().encode(state),
                                   attributes: [.posixPermissions: 0o600])
    print("paired with \(payload.macName)")
    print(describe(snapshot))
case "watch":
    await session(nil, wait: args.count >= 2 ? Double(args[1]) ?? 30 : 30)
case "approve", "deny":
    guard args.count >= 2 else { fail("usage: \(args[0]) <requestId>") }
    await session(.decide(requestId: args[1], allow: args[0] == "approve", message: args[0] == "deny" ? "Negato dal telefono" : nil), wait: 2)
case "answer":
    guard args.count >= 3, let eq = args[2].lastIndex(of: "=") else { fail("usage: answer <id> \"<question>=<label>\"") }
    await session(.answer(requestId: args[1], answers: [String(args[2][..<eq]): String(args[2][args[2].index(after: eq)...])]), wait: 2)
case "prompt":
    guard args.count >= 3 else { fail("usage: prompt <sessionId> \"<text>\"") }
    await session(.prompt(sessionId: args[1], text: args[2]), wait: 2)
default:
    fail("usage: pair <url> | watch [s] | approve|deny <id> | answer <id> \"q=label\" | prompt <sid> \"text\"")
}
