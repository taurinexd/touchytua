#!/bin/sh
# Manual check (touches the installed LaunchAgent): after the daemon binary
# changes, `touchytua daemon --ensure` must have it listening again within
# 3 seconds. Regression test for the kickstart/OS_REASON_CODESIGNING delay.
# Usage: tests/daemon-update-smoke.sh plugin/bin
set -u
BIN="$1"; DST="$HOME/.touchytua/bin/touchytuad"
[ -f "$HOME/Library/LaunchAgents/com.taurinexd.touchytua.plist" ] || { echo "SKIP: LaunchAgent not installed (run /pair)"; exit 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# A copy with a different signature stands in for "the previous version".
cp "$BIN/touchytuad" "$TMP/old" && codesign --force --sign - -i "smoke.$$" "$TMP/old" 2>/dev/null
rm -f "$DST"; cp "$TMP/old" "$DST"
launchctl bootout "gui/$(id -u)/com.taurinexd.touchytua" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.taurinexd.touchytua.plist"; sleep 2
start=$(perl -MTime::HiRes=time -e 'print time')
"$BIN/touchytua" daemon --ensure
i=0; while [ $i -lt 60 ]; do
  if cmp -s "$BIN/touchytuad" "$DST" && [ -n "$(pgrep -f "$DST")" ] && lsof -nP -iTCP:47311 -sTCP:LISTEN >/dev/null 2>&1; then break; fi
  sleep 0.25; i=$((i+1)); done
ms=$(perl -MTime::HiRes=time -e "printf '%d', (time-$start)*1000")
[ "$ms" -lt 3000 ] && echo "PASS daemon back after ${ms} ms" || { echo "FAIL daemon back after ${ms} ms"; exit 1; }
