import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

@Suite struct SetupTests {
    @Test func tailscaleDNSNameStripsTrailingDot() {
        let json = #"{"BackendState":"Running","Self":{"DNSName":"my-mac.tail1234.ts.net.","Online":true}}"#
        #expect(Setup.tailscaleDNSName(fromStatusJSON: Data(json.utf8)) == "my-mac.tail1234.ts.net")
    }

    @Test func tailscaleStoppedGivesNil() {
        let json = #"{"BackendState":"Stopped","Self":{"DNSName":"x.ts.net."}}"#
        #expect(Setup.tailscaleDNSName(fromStatusJSON: Data(json.utf8)) == nil)
    }

    @Test func endpointsListLanThenTailscale() {
        #expect(Setup.endpoints(lanIP: "192.168.1.10", tailscaleName: "m.ts.net", port: 47311)
                == ["lan:192.168.1.10:47311", "ts:m.ts.net:47311"])
        #expect(Setup.endpoints(lanIP: nil, tailscaleName: nil, port: 47311).isEmpty)
    }

    @Test func qrHalfBlocksPairRows() {
        // 2 rows → 1 text line (+ quiet zone handled by caller).
        let text = Setup.halfBlocks([[true, false, true], [true, true, false]])
        #expect(text == "█▄▀")  // col0 both, col1 bottom only, col2 top only
    }

    @Test func qrMatrixHasModules() throws {
        let m = try #require(Setup.qrMatrix("touchytua://pair?d=abc"))
        #expect(m.count >= 21 && m.count == m[0].count)
    }

    @Test func launchAgentPlist() throws {
        let data = Setup.launchAgentPlist(daemonPath: "/Users/u/.touchytua/bin/touchytuad", logPath: "/Users/u/.touchytua/run/daemon.log")
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "com.taurinexd.touchytua")
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/u/.touchytua/bin/touchytuad"])
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["StandardErrorPath"] as? String == "/Users/u/.touchytua/run/daemon.log")
    }

    @Test func theVersionIsTheOneOfThePluginManifest() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugin/.claude-plugin/plugin.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        #expect(json?["version"] as? String == Setup.version)
    }

    @Test func aNewerCopyReplacesTheInstalledOne() {
        #expect(Setup.mayInstall(shipped: "0.3.2", over: "0.3.1"))
        #expect(Setup.mayInstall(shipped: "0.10.0", over: "0.9.9"))
        #expect(Setup.mayInstall(shipped: "1.0.0", over: "0.99.99"))
    }

    @Test func theSameVersionMayBeInstalledAgain() {
        #expect(Setup.mayInstall(shipped: "0.3.2", over: "0.3.2\n"))
    }

    @Test func anOlderCopyNeverReplacesANewerOne() {
        #expect(!Setup.mayInstall(shipped: "0.3.1", over: "0.3.2"))
        #expect(!Setup.mayInstall(shipped: "0.9.9", over: "0.10.0"))
    }

    @Test func withNothingReadableInstalledAnyCopyGoesIn() {
        #expect(Setup.mayInstall(shipped: "0.3.2", over: nil))
        #expect(Setup.mayInstall(shipped: "0.3.2", over: "garbage"))
    }
}
