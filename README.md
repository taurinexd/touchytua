# touchytua

Control your Claude Code sessions from your iPhone: live status of every session, approve or deny permission requests, answer questions, send the next prompt.

This repository holds the Mac side:
- `plugin/` — the Claude Code plugin (hooks, `/pair`, `/doctor`, prebuilt universal binaries);
- `mac/` — Swift package: `TouchyKit` (models, protocol, crypto, shared with the iOS app), `touchytuad` (daemon), `touchytua-hook`, `touchytua-statusline`, `touchytua` (CLI), `touchytua-client` (phone simulator for testing).

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
`make test` · `make hook-smoke` · `make statusline-smoke` · `Scripts/build-plugin.sh`

Some code is ported from [Meowtch](https://github.com/taurinexd/meowtch) (MIT, same author).

## License
MIT
