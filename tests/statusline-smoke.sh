#!/bin/sh
# Integration test for touchytua-statusline (plan Task 9).
set -u
BIN="$1"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
mkdir -p "$TMP/home/run"
printf '{"previous":{"type":"command","command":"printf abc; cat >/dev/null"}}' > "$TMP/home/statusline-previous.json"
IN='{"session_id":"s9","cost":{"total_cost_usd":1.25},"rate_limits":{"seven_day":{"used_percentage":9}}}'

printf '{}\n' | nc -lU "$TMP/home/run/hook.sock" > "$TMP/env.json" & NC=$!; sleep 0.3
out=$(printf '%s' "$IN" | TOUCHYTUA_HOME="$TMP/home" "$BIN")
sleep 0.3; kill $NC 2>/dev/null; wait $NC 2>/dev/null
[ "$out" = "abc" ] && echo "PASS output identical" || { echo "FAIL output: '$out'"; fail=1; }
/usr/bin/jq -e '.event.hook_event_name=="touchytua_usage" and .event.session_id=="s9" and .event.statusline.cost.total_cost_usd==1.25' "$TMP/env.json" >/dev/null \
  && echo "PASS envelope" || { echo "FAIL envelope: $(cat "$TMP/env.json")"; fail=1; }

# No daemon, no previous statusline: prints nothing, exits 0.
out=$(printf '%s' "$IN" | TOUCHYTUA_HOME="$TMP/empty" "$BIN"); code=$?
[ $code -eq 0 ] && [ -z "$out" ] && echo "PASS no daemon/no previous" || { echo "FAIL empty: code=$code out=$out"; fail=1; }
exit $fail
