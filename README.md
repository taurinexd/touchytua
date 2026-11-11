# touchytua

Control your Claude Code sessions from your iPhone: live status of every session, approve or deny permission requests, answer questions, send the next prompt.

This repository holds both sides:
- `plugin/` — the Claude Code plugin (hooks, `/pair`, `/doctor`, prebuilt universal binaries);
- `mac/` — Swift package: `TouchyProtocol` (messages and crypto, shared with the phone), `TouchyKit` (Mac side: sessions, requests, pairing), `TouchyClient` (phone side: connection, state, presentation), `touchytuad` (daemon), `touchytua-hook`, `touchytua-statusline`, `touchytua` (CLI), `touchytua-client` (phone simulator for testing);
- `ios/` — the iPhone app (SwiftUI), built on `TouchyClient`.

## Install

```
/plugin marketplace add taurinexd/claude-marketplace
/plugin install touchytua@taurinexd
/pair
```

Scan the QR code with the touchytua iOS app (coming soon on TestFlight). To use it away from home, install Tailscale on the Mac and the iPhone.

## How it works
- Plugin hooks forward session events to a local daemon (`~/.touchytua/`), which holds permission requests until the phone or the terminal answers. The first answer wins, so touchytua coexists with other approval tools.
- The phone connects over Wi-Fi or Tailscale. Traffic is end-to-end encrypted with keys exchanged through the QR code: see [`docs/protocol.md`](docs/protocol.md).
- If the daemon is not running, Claude Code behaves exactly as without touchytua.

## Develop
`make test` · `make hook-smoke` · `make statusline-smoke` · `make daemon-smoke` · `Scripts/build-plugin.sh`

The iPhone app needs Xcode and XcodeGen: `make ios` generates the project. To run it on a device, copy `ios/Local.xcconfig.example` to `ios/Local.xcconfig` and set your team.

Some code is ported from [Meowtch](https://github.com/taurinexd/meowtch) (MIT, same author).

## License
MIT
