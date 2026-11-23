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
# A restart in progress leaves a marker that makes hooks wait: the daemon
# clears it once it listens.
mkdir -p "$HOME_T/run"; : > "$HOME_T/run/restarting"
TOUCHYTUA_HOME="$HOME_T" TOUCHYTUA_PORT=47398 TOUCHYTUA_REAP_SECONDS=2 TOUCHYTUA_GREETING_SECONDS=1 "$D" 2>"$HOME_T/log" &
PID=$!; sleep 0.7
[ ! -e "$HOME_T/run/restarting" ] && [ -S "$HOME_T/run/hook.sock" ] && echo "PASS restart marker cleared once listening" || { echo "FAIL restart marker still there"; fail=1; }
nc -lkU "$HOME_T/live.sock" >/dev/null 2>&1 &
NC=$!; sleep 0.2
send() { echo "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$1\",\"cwd\":\"/p/$1\"}" |
  CLAUDE_CODE_MESSAGING_SOCKET="$2" CLAUDE_CODE_MESSAGING_TOKEN=tok TOUCHYTUA_HOOK_SOCKET="$HOME_T/run/hook.sock" "$H"; }
send live "$HOME_T/live.sock"; send dead "$HOME_T/dead.sock"
sleep 0.3
/usr/bin/jq -e 'map(.session.id)|sort==["dead","live"]' "$HOME_T/run/sessions.json" >/dev/null && echo "PASS registry saved" || { echo "FAIL registry: $(cat "$HOME_T/run/sessions.json" 2>&1)"; fail=1; }
sleep 3
kill -0 $PID 2>/dev/null && echo "PASS daemon alive after reaper runs" || { echo "FAIL daemon died: $(tail -2 "$HOME_T/log")"; fail=1; }
/usr/bin/jq -e 'map(.session.id)==["live"]' "$HOME_T/run/sessions.json" >/dev/null && echo "PASS dead session reaped, live kept" || { echo "FAIL reap: $(cat "$HOME_T/run/sessions.json" 2>&1)"; fail=1; }
# A connection that never says hello is dropped: anyone on the network can
# open one, and each holds a thread.
took=$(perl -MIO::Socket::INET -MTime::HiRes=time -e '
  $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:47398", Timeout => 2) or do { print "none"; exit };
  $s->sockopt(SO_RCVTIMEO, pack("l!l!", 6, 0)); $t = time; $n = sysread($s, $b, 1);
  print defined($n) && $n == 0 ? int((time - $t) * 1000) : "kept"')
case "$took" in
  none|kept) echo "FAIL silent connection: $took"; fail=1 ;;
  *) [ "$took" -le 3000 ] && echo "PASS silent connection dropped (${took} ms)" || { echo "FAIL silent connection dropped late (${took} ms)"; fail=1; } ;;
esac
# A hook that is gone before its answer arrives must not take the daemon
# down: Claude Code kills the hook when the request is answered in the
# terminal, and the daemon then writes to a closed socket.
echo '{"hook_event_name":"PermissionRequest","session_id":"live","cwd":"/p/live","tool_name":"Bash","tool_input":{"command":"ls"}}' |
  CLAUDE_CODE_MESSAGING_SOCKET="$HOME_T/live.sock" CLAUDE_CODE_MESSAGING_TOKEN=tok TOUCHYTUA_HOOK_SOCKET="$HOME_T/run/hook.sock" "$H" >/dev/null 2>&1 &
GONE=$!; sleep 0.5; kill -9 $GONE 2>/dev/null; sleep 0.2
echo '{"hook_event_name":"PostToolUse","session_id":"live","cwd":"/p/live","tool_name":"Bash","tool_input":{"command":"ls"}}' |
  CLAUDE_CODE_MESSAGING_SOCKET="$HOME_T/live.sock" CLAUDE_CODE_MESSAGING_TOKEN=tok TOUCHYTUA_HOOK_SOCKET="$HOME_T/run/hook.sock" "$H" >/dev/null 2>&1
sleep 0.5
kill -0 $PID 2>/dev/null && echo "PASS daemon alive after answering a hook that left" || { echo "FAIL daemon died answering a hook that left: $(tail -2 "$HOME_T/log")"; fail=1; }
# A hook that is gone before the daemon has even accepted it: the option
# that silences SIGPIPE cannot be set on a socket whose peer already left,
# so it has to be there from the start. The daemon is held still while the
# hook comes and goes.
kill -STOP $PID
perl -MIO::Socket::UNIX -e '$s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or exit 1; print $s $ARGV[1]; close $s' \
  "$HOME_T/run/hook.sock" '{"v":1,"capturedAt":0,"event":{"hook_event_name":"PostToolUse","session_id":"live","cwd":"/p/live","tool_name":"Bash","tool_input":{"command":"ls"}}}'
kill -CONT $PID; sleep 0.5
kill -0 $PID 2>/dev/null && echo "PASS daemon alive after answering a hook that left before being accepted" || { echo "FAIL daemon died answering a hook that left before being accepted: $(tail -2 "$HOME_T/log")"; fail=1; }
# Restart: the registry comes back from disk.
kill $PID; wait $PID 2>/dev/null
rm -f "$HOME_T/folders.json"
TOUCHYTUA_HOME="$HOME_T" TOUCHYTUA_PORT=47398 TOUCHYTUA_REAP_SECONDS=30 "$D" 2>>"$HOME_T/log" &
PID=$!; sleep 0.7
# A restored session sends no event: its folder is offered to the phone all the same.
/usr/bin/jq -e '.seen|index("/p/live")!=null' "$HOME_T/folders.json" >/dev/null 2>&1 && echo "PASS restored session's folder is offered" || { echo "FAIL folders: $(cat "$HOME_T/folders.json" 2>&1)"; fail=1; }
send other "$HOME_T/live.sock"; sleep 0.3
/usr/bin/jq -e 'map(.session.id)|sort==["live","other"]' "$HOME_T/run/sessions.json" >/dev/null && echo "PASS registry restored after restart" || { echo "FAIL restore: $(cat "$HOME_T/run/sessions.json" 2>&1)"; fail=1; }
exit $fail
