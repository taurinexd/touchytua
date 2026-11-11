import CryptoKit
import Foundation
import TouchyClient
import TouchyProtocol

// touchytua-client — simulates the iPhone for end-to-end verification, on
// the same client core the iOS app uses.
//   pair "<qr url>"                      first pairing (uses the one-time secret)
//   watch [seconds]                      print every message from the Mac
//   approve|deny <requestId>
//   answer <requestId> "<question>=<label>"
//   prompt <sessionId> "<text>"
//   raw <type>                           send a message type the Mac does not know
// Global: --via lan|ts|bonjour (endpoint choice; bonjour finds the Mac on the
// local network by its key), --key <file> (use another phone key).

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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("touchytua-client: \(message)\n".utf8))
    exit(1)
}

/// The phone's key and pairings as files, where the app uses the Keychain.
struct FileSecretStore: SecretStore {
    let keyPath: String
    let statePath: String

    /// What `state.json` held before pairings became a list.
    private struct Legacy: Codable {
        var macKey: Data
        var endpoints: [String]
    }

    func phoneKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let raw = FileManager.default.contents(atPath: keyPath),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.KeyAgreement.PrivateKey()
        write(key.rawRepresentation, to: keyPath)
        return key
    }

    func pairings() -> [PairingRecord] {
        guard let data = FileManager.default.contents(atPath: statePath) else { return [] }
        if let records = try? JSONDecoder().decode([PairingRecord].self, from: data) { return records }
        if let old = try? JSONDecoder().decode(Legacy.self, from: data) {
            return [PairingRecord(macName: "Mac", macKey: old.macKey, endpoints: old.endpoints)]
        }
        return []
    }

    func save(_ record: PairingRecord) {
        let records = [record] + pairings().filter { $0.macKey != record.macKey }
        write((try? JSONEncoder().encode(records)) ?? Data(), to: statePath)
    }

    func remove(macKey: Data) {
        write((try? JSONEncoder().encode(pairings().filter { $0.macKey != macKey })) ?? Data(), to: statePath)
    }

    private func write(_ data: Data, to path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

let store = FileSecretStore(keyPath: parsed.key ?? stateDir + "/phone-key", statePath: stateDir + "/state.json")

/// The addresses to try: all of them in QR order, or only the `--via` kind.
func candidates(_ record: PairingRecord) -> [String] {
    if via == "bonjour" { return [Endpoint.bonjour(forMacKey: record.macKey).text] }
    let picked = record.endpoints.filter { via == nil || $0.hasPrefix(via! + ":") }
    if picked.isEmpty { fail("no endpoint for --via \(via ?? "")") }
    return picked
}

/// Connects to the first address that completes the handshake.
func connect(_ record: PairingRecord, secret: Data?) async -> PhoneLink {
    guard let key = try? store.phoneKey() else { fail("cannot read or create the phone key") }
    var problems: [String] = []
    for text in candidates(record) {
        guard let endpoint = Endpoint(text) else {
            problems.append("\(text): unreadable address")
            continue
        }
        do {
            let link = try await within(seconds: 5) {
                let transport = try await NWWebSocketTransport.connect(to: endpoint)
                let link = PhoneLink(transport: transport, phoneKey: key, macKey: record.macKey, pairingSecret: secret)
                do {
                    _ = try await link.open()
                } catch {
                    await link.close()
                    throw error
                }
                return link
            }
            return link
        } catch LinkError.rejected {
            fail("handshake failed: the Mac refused this phone (\(secret == nil ? "not paired" : "QR expired or used"))")
        } catch {
            problems.append("\(text): \(error)")
        }
    }
    fail("handshake failed: \(problems.joined(separator: "; "))")
}

struct TimedOut: Error {}

/// Runs `work`, giving up (and cancelling it) after `seconds`.
func within<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else { throw TimedOut() }
        return value
    }
}

func describe(_ m: MacToPhone) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    return String(decoding: (try? enc.encode(m)) ?? Data(), as: UTF8.self)
}

func paired() -> PairingRecord {
    guard let record = store.pairings().first else { fail("not paired: run pair first") }
    return record
}

/// The next message, or nil if none arrives in `seconds` (the link is then closed).
func next(_ link: PhoneLink, within seconds: Double) async -> MacToPhone? {
    try? await within(seconds: seconds) { try await link.next() }
}

/// Connects, says hello, prints the snapshot, sends `message`, prints replies for `wait` seconds.
func session(_ message: PhoneToMac?, wait: TimeInterval) async {
    let link = await connect(paired(), secret: nil)
    await link.send(.hello(deviceName: "touchytua-client"))
    if let snapshot = await next(link, within: 5) { print(describe(snapshot)) } else { fail("no snapshot") }
    if let message { await link.send(message) }
    // Leave at the deadline even on a quiet link.
    DispatchQueue.global().asyncAfter(deadline: .now() + wait) { exit(0) }
    while let m = try? await link.next() {
        print(describe(m))
        if case .error = m, message != nil { exit(3) }
    }
}

switch args.first {
case "pair":
    guard args.count >= 2, let payload = try? PairingPayload.parse(url: args[1]) else { fail("usage: pair <url>") }
    let record = PairingRecord(macName: payload.macName, macKey: payload.macKey, endpoints: payload.endpoints)
    let link = await connect(record, secret: payload.secret)
    // The Mac has accepted: from here on this phone is the paired one.
    store.save(record)
    await link.send(.hello(deviceName: "touchytua-client"))
    guard let snapshot = await next(link, within: 5) else { fail("no snapshot after pairing") }
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
case "raw":
    guard args.count >= 2 else { fail("usage: raw <type>") }
    // Not `session`: that exits on the first error, and here the error is
    // the expected answer; the snapshot after it proves the link survived.
    let link = await connect(paired(), secret: nil)
    await link.send(.unknown(args[1]))
    if let reply = await next(link, within: 3) { print(describe(reply)) }
    await link.send(.hello(deviceName: "touchytua-client"))
    if let snapshot = await next(link, within: 3), case .snapshot = snapshot { print("still connected: snapshot received") }
default:
    fail("usage: pair <url> | watch [s] | approve|deny <id> | answer <id> \"q=label\" | prompt <sid> \"text\"")
}
