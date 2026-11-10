import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

private func tempHome() -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tt-home-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u.appendingPathComponent(".claude/plugins"), withIntermediateDirectories: true)
    return u
}

private func write(_ s: String, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(s.utf8).write(to: url)
}

@Suite struct InboundSettingTests {
    /// With `hold` or `refuse`, Claude Code silently keeps or drops the
    /// prompts sent from the phone: doctor must be able to say so.
    @Test func readsCrossSessionInboundFromUserSettings() {
        let home = tempHome()
        #expect(ConflictScan.crossSessionInbound(home: home) == nil)
        write(#"{"crossSessionInbound":"refuse"}"#, home.appendingPathComponent(".claude/settings.json"))
        #expect(ConflictScan.crossSessionInbound(home: home) == "refuse")
    }
}

@Suite struct ConflictScanTests {
    @Test func scanFindsForeignPermissionHook() {
        let home = tempHome()
        write(#"{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"$HOME/.vedetta/bin/vedetta-bridge --source claude"}]}]}}"#,
              home.appendingPathComponent(".claude/settings.json"))
        let found = ConflictScan.scan(home: home, projectDir: nil)
        #expect(found == [Conflict(event: "PermissionRequest", matcher: "*", command: "$HOME/.vedetta/bin/vedetta-bridge --source claude", source: "user")])
    }

    @Test func scanIgnoresOwnHooks() {
        let home = tempHome()
        write(#"{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"/x/touchytua-hook"}]}]}}"#,
              home.appendingPathComponent(".claude/settings.json"))
        #expect(ConflictScan.scan(home: home, projectDir: nil).isEmpty)
    }

    @Test func scanFindsAskUserQuestionPreToolUseInProjectAndPlugin() {
        let home = tempHome(), proj = tempHome()
        write(#"{"hooks":{"PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"ask.sh"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"bash-guard.sh"}]}]}}"#,
              proj.appendingPathComponent(".claude/settings.local.json"))
        let pluginDir = home.appendingPathComponent("plugcache/other/1.0")
        write(#"{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"other-approve"}]}]}}"#,
              pluginDir.appendingPathComponent("hooks/hooks.json"))
        write(#"{"enabledPlugins":{"other@mkt":true,"off@mkt":false}}"#, home.appendingPathComponent(".claude/settings.json"))
        write(#"{"version":2,"plugins":{"other@mkt":[{"scope":"user","installPath":"\#(pluginDir.path)"}]}}"#,
              home.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        let found = ConflictScan.scan(home: home, projectDir: proj)
        #expect(found.contains(Conflict(event: "PreToolUse", matcher: "AskUserQuestion", command: "ask.sh", source: "local")))
        #expect(found.contains(Conflict(event: "PermissionRequest", matcher: "*", command: "other-approve", source: "plugin:other@mkt")))
        #expect(!found.contains { $0.command == "bash-guard.sh" })
    }
}

@Suite struct StatusLineChainTests {
    let original = """
    {
      "model": "opus",
      "statusLine": { "type": "command", "command": "/x/prev" },
      "hooks": {}
    }
    """

    @Test func installBacksUpAndChains() throws {
        let home = tempHome(), state = home.appendingPathComponent(".touchytua")
        let settings = home.appendingPathComponent(".claude/settings.json")
        write(original, settings)
        let backup = try StatusLineChain.install(settingsURL: settings, wrapperPath: "/w/touchytua-statusline", stateDirectory: state.path)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        let now = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect((now["statusLine"] as? [String: Any])?["command"] as? String == "/w/touchytua-statusline")
        #expect(now["model"] as? String == "opus")
        #expect(StatusLineChain.previousCommand(stateDirectory: state.path) == "/x/prev")
    }

    @Test func installIsIdempotent() throws {
        let home = tempHome(), state = home.appendingPathComponent(".touchytua")
        let settings = home.appendingPathComponent(".claude/settings.json")
        write(original, settings)
        _ = try StatusLineChain.install(settingsURL: settings, wrapperPath: "/w/touchytua-statusline", stateDirectory: state.path)
        _ = try StatusLineChain.install(settingsURL: settings, wrapperPath: "/w/touchytua-statusline", stateDirectory: state.path)
        #expect(StatusLineChain.previousCommand(stateDirectory: state.path) == "/x/prev")
    }

    @Test func uninstallRestores() throws {
        let home = tempHome(), state = home.appendingPathComponent(".touchytua")
        let settings = home.appendingPathComponent(".claude/settings.json")
        write(original, settings)
        _ = try StatusLineChain.install(settingsURL: settings, wrapperPath: "/w/touchytua-statusline", stateDirectory: state.path)
        try StatusLineChain.uninstall(settingsURL: settings, stateDirectory: state.path)
        let now = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! NSDictionary
        let before = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary
        #expect(now == before)
    }

    @Test func installWithoutPreviousStatusLine() throws {
        let home = tempHome(), state = home.appendingPathComponent(".touchytua")
        let settings = home.appendingPathComponent(".claude/settings.json")
        write(#"{"model":"opus"}"#, settings)
        _ = try StatusLineChain.install(settingsURL: settings, wrapperPath: "/w/t", stateDirectory: state.path)
        #expect(StatusLineChain.previousCommand(stateDirectory: state.path) == nil)
        try StatusLineChain.uninstall(settingsURL: settings, stateDirectory: state.path)
        let now = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect(now["statusLine"] == nil)
    }

    @Test func usageParsedFromStatusLineInput() {
        let input = #"{"cost":{"total_cost_usd":1.25},"rate_limits":{"seven_day":{"used_percentage":9}}}"#
        #expect(StatusLineChain.usage(fromStatusLineInput: Data(input.utf8)) == Usage(totalCostUSD: 1.25, fiveHourPct: nil, sevenDayPct: 9))
    }
}
