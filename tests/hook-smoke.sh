#!/bin/sh
# Integration test for touchytua-hook (plan Task 4).
set -u
BIN="$1"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

# (a) no daemon socket: exit 0, empty stdout, under 100 ms once warm.
#     The first exec after a build pays macOS's scan of the new binary
#     (~340 ms, ledger ruling Task 4), so warm it up first.
echo '{}' | TOUCHYTUA_HOOK_SOCKET="$TMP/missing.sock" "$BIN" >/dev/null
start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
out=$(echo '{"hook_event_name":"Stop","session_id":"x"}' | TOUCHYTUA_HOOK_SOCKET="$TMP/missing.sock" "$BIN"); code=$?
end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
[ $code -eq 0 ] && [ -z "$out" ] && [ $((end-start)) -lt 100 ] && echo "PASS a (no socket, $((end-start)) ms)" || { echo "FAIL a: code=$code out=$out ms=$((end-start))"; fail=1; }

# (b) fake daemon answers {"a":1}: stdout relays it; envelope carries inbox creds on SessionStart.
printf '{"a":1}\n' | nc -lU "$TMP/d.sock" > "$TMP/req.json" &
NC=$!; sleep 0.3
out=$(echo '{"hook_event_name":"SessionStart","session_id":"x"}' | CLAUDE_CODE_MESSAGING_SOCKET=/tmp/s.sock CLAUDE_CODE_MESSAGING_TOKEN=tok TOUCHYTUA_HOOK_SOCKET="$TMP/d.sock" "$BIN")
sleep 0.3; kill $NC 2>/dev/null; wait $NC 2>/dev/null
[ "$out" = '{"a":1}' ] && echo "PASS b (relay)" || { echo "FAIL b: out=$out"; fail=1; }
/usr/bin/jq -e '.v==1 and .event.hook_event_name=="SessionStart" and .messagingSocket=="/tmp/s.sock" and .messagingToken=="tok" and (.capturedAt|type=="number")' "$TMP/req.json" >/dev/null && echo "PASS b (envelope)" || { echo "FAIL b envelope: $(cat "$TMP/req.json")"; fail=1; }

# (c) non-SessionStart events never carry inbox credentials.
printf '{}\n' | nc -lU "$TMP/e.sock" > "$TMP/req2.json" &
NC=$!; sleep 0.3
out=$(echo '{"hook_event_name":"Stop","session_id":"x"}' | CLAUDE_CODE_MESSAGING_TOKEN=tok TOUCHYTUA_HOOK_SOCKET="$TMP/e.sock" "$BIN")
sleep 0.3; kill $NC 2>/dev/null; wait $NC 2>/dev/null
[ -z "$out" ] && /usr/bin/jq -e '.messagingToken==null' "$TMP/req2.json" >/dev/null && echo "PASS c (no creds, {} suppressed)" || { echo "FAIL c: out=$out req=$(cat "$TMP/req2.json")"; fail=1; }
exit $fail
