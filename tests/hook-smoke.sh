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

# (c) every event carries the inbox credentials (a restarted daemon never
#     sees SessionStart again); a session without an inbox sends none.
printf '{}\n' | nc -lU "$TMP/e.sock" > "$TMP/req2.json" &
NC=$!; sleep 0.3
out=$(echo '{"hook_event_name":"Stop","session_id":"x"}' | CLAUDE_CODE_MESSAGING_SOCKET=/tmp/s.sock CLAUDE_CODE_MESSAGING_TOKEN=tok TOUCHYTUA_HOOK_SOCKET="$TMP/e.sock" "$BIN")
sleep 0.3; kill $NC 2>/dev/null; wait $NC 2>/dev/null
[ -z "$out" ] && /usr/bin/jq -e '.messagingSocket=="/tmp/s.sock" and .messagingToken=="tok"' "$TMP/req2.json" >/dev/null && echo "PASS c (creds on every event, {} suppressed)" || { echo "FAIL c: out=$out req=$(cat "$TMP/req2.json")"; fail=1; }

printf '{}\n' | nc -lU "$TMP/f.sock" > "$TMP/req3.json" &
NC=$!; sleep 0.3
echo '{"hook_event_name":"Stop","session_id":"x"}' | env -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN TOUCHYTUA_HOOK_SOCKET="$TMP/f.sock" "$BIN" >/dev/null
sleep 0.3; kill $NC 2>/dev/null; wait $NC 2>/dev/null
/usr/bin/jq -e '.messagingSocket==null and .messagingToken==null' "$TMP/req3.json" >/dev/null && echo "PASS d (no inbox, no creds)" || { echo "FAIL d: req=$(cat "$TMP/req3.json")"; fail=1; }
# (e) the daemon is being restarted (fresh marker next to the socket): the
#     hook waits for the socket instead of dropping the event.
mkdir -p "$TMP/run1"; : > "$TMP/run1/restarting"
( sleep 1; printf '{}\n' | nc -lU "$TMP/run1/hook.sock" > "$TMP/req5.json" ) &
NC=$!
echo '{"hook_event_name":"UserPromptSubmit","session_id":"x","prompt":"first"}' | TOUCHYTUA_HOOK_SOCKET="$TMP/run1/hook.sock" "$BIN" >/dev/null
sleep 0.3; kill $NC 2>/dev/null; wait $NC 2>/dev/null
/usr/bin/jq -e '.event.prompt=="first"' "$TMP/req5.json" >/dev/null 2>&1 && echo "PASS e (waits for a restarting daemon)" || { echo "FAIL e: req=$(cat "$TMP/req5.json" 2>&1)"; fail=1; }

# (f) a marker left behind long ago does not make the hook wait.
mkdir -p "$TMP/run2"; : > "$TMP/run2/restarting"; touch -t 202001010000 "$TMP/run2/restarting"
start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
echo '{"hook_event_name":"Stop","session_id":"x"}' | TOUCHYTUA_HOOK_SOCKET="$TMP/run2/hook.sock" "$BIN" >/dev/null
end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
[ $((end-start)) -lt 200 ] && echo "PASS f (stale marker ignored, $((end-start)) ms)" || { echo "FAIL f: ms=$((end-start))"; fail=1; }

# (g) the daemon dies while holding a request: the hook sends it again to
#     the daemon that comes back, and relays that one's answer.
mkdir -p "$TMP/run3"
nc -lU "$TMP/run3/hook.sock" </dev/null > "$TMP/req6a.json" &
NC1=$!; sleep 0.3
( sleep 1; rm -f "$TMP/run3/hook.sock"; printf '{"decision":"allow"}\n' | nc -lU "$TMP/run3/hook.sock" > "$TMP/req6b.json" ) &
NC2=$!
out=$(echo '{"hook_event_name":"PermissionRequest","session_id":"x","tool_name":"Bash"}' | TOUCHYTUA_HOOK_SOCKET="$TMP/run3/hook.sock" "$BIN")
sleep 0.3; kill $NC1 $NC2 2>/dev/null; wait $NC1 $NC2 2>/dev/null
[ "$out" = '{"decision":"allow"}' ] && /usr/bin/jq -e '.event.tool_name=="Bash"' "$TMP/req6b.json" >/dev/null 2>&1 && echo "PASS g (request survives a daemon restart)" || { echo "FAIL g: out=$out second=$(cat "$TMP/req6b.json" 2>&1)"; fail=1; }

# (h) the daemon dies and never comes back: the hook gives up quietly.
mkdir -p "$TMP/run4"
nc -lU "$TMP/run4/hook.sock" </dev/null >/dev/null &
NC=$!; sleep 0.3
start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
out=$(echo '{"hook_event_name":"PermissionRequest","session_id":"x"}' | TOUCHYTUA_HOOK_PATIENCE=1 TOUCHYTUA_HOOK_SOCKET="$TMP/run4/hook.sock" "$BIN"); code=$?
end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
kill $NC 2>/dev/null; wait $NC 2>/dev/null
[ $code -eq 0 ] && [ -z "$out" ] && [ $((end-start)) -lt 2500 ] && echo "PASS h (gives up after its patience, $((end-start)) ms)" || { echo "FAIL h: code=$code out=$out ms=$((end-start))"; fail=1; }
exit $fail
