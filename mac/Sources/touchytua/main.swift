import CoreImage
import Foundation
import TouchyKit

// touchytua — user-facing CLI shipped in the plugin's bin/ (on Claude's
// PATH while the plugin is enabled).
//   touchytua pair [--no-open] [--terminal]
//                                     pair a phone (QR), install the LaunchAgent
//   touchytua doctor                  conflicts, daemon and pairing status
//   touchytua daemon --ensure         start the daemon if it is not running
//   touchytua statusline install|uninstall

let env = ProcessInfo.processInfo.environment
let home = env["TOUCHYTUA_HOME"] ?? (NSHomeDirectory() + "/.touchytua")
let binDir = home + "/bin"
let runDir = home + "/run"
let logPath = runDir + "/daemon.log"
let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(Setup.launchAgentLabel).plist"
let shippedDir = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent().path
let binaries = ["touchytuad", "touchytua-hook", "touchytua-statusline"]
let args = Array(CommandLine.arguments.dropFirst())

func say(_ s: String) { print(s) }

@discardableResult
func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (-1, Data()) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

/// Copies the plugin's binaries to ~/.touchytua/bin (stable path for the
/// LaunchAgent). Returns true when anything changed.
@discardableResult
func installBinaries() -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.createDirectory(atPath: runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // A session started before an update still runs the old plugin copy.
    let versionPath = binDir + "/version"
    let installed = fm.contents(atPath: versionPath).map { String(decoding: $0, as: UTF8.self) }
    guard Setup.mayInstall(shipped: Setup.version, over: installed) else { return false }
    fm.createFile(atPath: versionPath, contents: Data(Setup.version.utf8))
    var changed = false
    for name in binaries {
        let src = shippedDir + "/" + name, dst = binDir + "/" + name
        guard let new = fm.contents(atPath: src), fm.contents(atPath: dst) != new else { continue }
        try? fm.removeItem(atPath: dst)
        if (try? fm.copyItem(atPath: src, toPath: dst)) != nil { changed = true }
    }
    return changed
}

/// Pid of the running daemon, nil if none (the daemon holds an exclusive lock).
func daemonPid() -> pid_t? {
    let path = runDir + "/daemon.lock"
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func startDetachedDaemon() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binDir + "/touchytuad")
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let log = FileHandle(forWritingAtPath: logPath)
    log?.seekToEndOfFile()
    p.standardOutput = log
    p.standardError = log
    p.standardInput = FileHandle.nullDevice
    try? p.run()
}

func launchAgentDomain() -> String { "gui/\(getuid())" }

/// Unloads and loads the LaunchAgent. Needed whenever the daemon binary
/// changed: `kickstart -k` on a loaded job whose executable was replaced
/// gets the first spawn killed (OS_REASON_CODESIGNING) and launchd only
/// retries about ten seconds later.
func reloadLaunchAgent() {
    announceRestart()
    run("/bin/launchctl", ["bootout", "\(launchAgentDomain())/\(Setup.launchAgentLabel)"])
    run("/bin/launchctl", ["bootstrap", launchAgentDomain(), plistPath])
}

/// Tells the hooks the daemon is about to be replaced, so they wait for
/// the new one instead of dropping what they carry.
func announceRestart() {
    FileManager.default.createFile(atPath: runDir + "/" + Setup.restartMarkerName, contents: nil)
}

func ensureDaemon() {
    let changed = installBinaries()
    if FileManager.default.fileExists(atPath: plistPath) {
        if changed {
            reloadLaunchAgent()
        } else if daemonPid() == nil {
            run("/bin/launchctl", ["kickstart", "\(launchAgentDomain())/\(Setup.launchAgentLabel)"])
        }
    } else if daemonPid() == nil {
        startDetachedDaemon()
    }
}

func printConflicts() {
    let found = ConflictScan.scan(home: URL(fileURLWithPath: NSHomeDirectory()),
                                  projectDir: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    if found.isEmpty {
        say("No other tool handles approvals or questions.")
        return
    }
    say("Other tools that can answer approvals or questions (touchytua works alongside them: the first answer wins):")
    for c in found { say("  • [\(c.source)] \(c.event) \(c.matcher == "*" ? "" : "(\(c.matcher)) ")→ \(c.command)") }
}

func pair(openPNG: Bool, printQR: Bool) throws {
    installBinaries()
    let store = PairingStore(directory: home)
    let tsName: String? = {
        for path in ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                     "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let r = run(path, ["status", "--json"])
            if r.status == 0 { return Setup.tailscaleDNSName(fromStatusJSON: r.output) }
        }
        return nil
    }()
    let endpoints = Setup.endpoints(lanIP: Setup.lanIPv4(), tailscaleName: tsName, port: 47311)
    let payload = try store.beginPairing(endpoints: endpoints, macName: Host.current().localizedName ?? "Mac")
    let url = payload.url()

    // LaunchAgent: (re)start the daemon under launchd so it survives logout of sessions.
    if let pid = daemonPid() {
        announceRestart()
        kill(pid, SIGTERM)
        usleep(300_000)
    }
    try Setup.launchAgentPlist(daemonPath: binDir + "/touchytuad", logPath: logPath)
        .write(to: URL(fileURLWithPath: plistPath))
    reloadLaunchAgent()

    // The QR carries a pairing secret. It goes to an image, not to stdout:
    // whatever a command prints inside Claude Code lands in the transcript.
    let minutes = Int(PairingStore.secretLifetime / 60)
    if let png = qrPNG(url) {
        let path = store.qrImagePath
        FileManager.default.createFile(atPath: path, contents: png, attributes: [.posixPermissions: 0o600])
        say("QR code ready: \(path)")
        say("Scan it with the touchytua app within \(minutes) minutes. It works once; the file is deleted after use.")
        if openPNG { run("/usr/bin/open", [path]) }
    }
    if printQR {
        say("\n" + (Setup.terminalQR(url) ?? "(QR code not available)"))
    }
    say("Addresses: \(endpoints.joined(separator: ", "))")
    if tsName == nil {
        say("To use touchytua away from your Wi-Fi, install Tailscale on the Mac and the iPhone, then run /pair again.")
    }
    say("")
    printConflicts()
}

func qrPNG(_ text: String) -> Data? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
    return CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
}

func doctor() {
    if let pid = daemonPid() { say("Daemon: running (pid \(pid))") } else { say("Daemon: not running") }
    say("Start at login: \(FileManager.default.fileExists(atPath: plistPath) ? "LaunchAgent installed" : "not installed (run /pair)")")
    let store = PairingStore(directory: home)
    let state = store.load()
    let waiting = store.activeSecret(now: Date()) != nil ? " (a QR code is waiting to be scanned)" : ""
    if state.phoneKey != nil {
        say("Phone: paired\(state.deviceName.map { " (\($0))" } ?? "")\(waiting)")
    } else {
        say("Phone: not paired\(waiting)")
    }
    if let inbound = ConflictScan.crossSessionInbound(home: URL(fileURLWithPath: NSHomeDirectory())),
       inbound != "accept" {
        say("Warning: crossSessionInbound=\(inbound) in Claude Code's settings. Prompts sent from the phone are \(inbound == "refuse" ? "discarded" : "held back").")
    }
    let previous = StatusLineChain.previousCommand(stateDirectory: home)
    say("Chained status line: \(FileManager.default.fileExists(atPath: home + "/statusline-previous.json") ? "installed\(previous.map { " (previous: \($0))" } ?? "")" : "not installed")")
    printConflicts()
}

func statusLine(_ action: String) throws {
    let settings = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
    switch action {
    case "install":
        installBinaries()
        let backup = try StatusLineChain.install(settingsURL: settings, wrapperPath: binDir + "/touchytua-statusline",
                                                 stateDirectory: home)
        say("Chained status line installed. Backup: \(backup.path)")
    case "uninstall":
        try StatusLineChain.uninstall(settingsURL: settings, stateDirectory: home)
        say("Status line restored.")
    default:
        say("usage: touchytua statusline install|uninstall"); exit(2)
    }
}

do {
    switch args.first {
    case "pair": try pair(openPNG: !args.contains("--no-open"), printQR: args.contains("--terminal"))
    case "doctor": doctor()
    case "daemon" where args.contains("--ensure"): ensureDaemon()
    case "statusline": try statusLine(args.dropFirst().first ?? "")
    default:
        say("usage: touchytua pair [--no-open] [--terminal] | doctor | daemon --ensure | statusline install|uninstall")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("touchytua: \(error)\n".utf8))
    exit(1)
}
