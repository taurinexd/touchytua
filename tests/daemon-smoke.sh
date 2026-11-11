#!/bin/sh
# Integration test for touchytuad in a private home: the daemon must stay
# up across reaper runs, and a session whose inbox socket is dead must be
# dropped from the registry while a live one is kept.
# Usage: tests/daemon-smoke.sh <touchytuad> <touchytua-hook>
set -u
D="$1"; H="$2"
HOME_T=$(mktemp -d /tmp/ttd.XXXXXX); trap 'kill $PID $NC 2>/dev/null; rm -rf "$HOME_T"' EXIT
fail=0
# Reaper every 2 s: it runs at start, then well after the first check below.
TOUCHYTUA_HOME="$HOME_T" TOUCHYTUA_PORT=47398 TOUCHYTUA_REAP_SECONDS=2 "$D" 2>"$HOME_T/log" &
PID=$!; sleep 0.7
nc -lkU "$HOME_T/live.sock" >/dev/null 2>&1 &
NC=$!; sleep 0.2
send() { echo "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$1\",\"cwd\":\"/p/$1\"}" |
  CLAUDE_CODE_MESSAGING_SOCKET="$2" CLAUDE_CODE_MESSAGING_TOKEN=tok TOUCHYTUA_HOOK_SOCKET="$HOME_T/run/hook.sock" "$H"; }
send live "$HOME_T/live.sock"; send dead "$HOME_T/dead.sock"
sleep 0.3
/usr/bin/jq -e 'map(.id)|sort==["dead","live"]' "$HOME_T/run/sessions.json" >/dev/null && echo "PASS registry saved" || { echo "FAIL registry: $(cat "$HOME_T/run/sessions.json" 2>&1)"; fail=1; }
sleep 3
kill -0 $PID 2>/dev/null && echo "PASS daemon alive after reaper runs" || { echo "FAIL daemon died: $(tail -2 "$HOME_T/log")"; fail=1; }
/usr/bin/jq -e 'map(.id)==["live"]' "$HOME_T/run/sessions.json" >/dev/null && echo "PASS dead session reaped, live kept" || { echo "FAIL reap: $(cat "$HOME_T/run/sessions.json" 2>&1)"; fail=1; }
# Restart: the registry comes back from disk.
kill $PID; wait $PID 2>/dev/null
TOUCHYTUA_HOME="$HOME_T" TOUCHYTUA_PORT=47398 TOUCHYTUA_REAP_SECONDS=30 "$D" 2>>"$HOME_T/log" &
PID=$!; sleep 0.7
send other "$HOME_T/live.sock"; sleep 0.3
/usr/bin/jq -e 'map(.id)|sort==["live","other"]' "$HOME_T/run/sessions.json" >/dev/null && echo "PASS registry restored after restart" || { echo "FAIL restore: $(cat "$HOME_T/run/sessions.json" 2>&1)"; fail=1; }
exit $fail
