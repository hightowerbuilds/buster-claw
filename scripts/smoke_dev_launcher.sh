#!/usr/bin/env bash
# Behavioural smoke for scripts/dev.sh, with mix, cargo and Phoenix faked.
#
# Proves the launcher never leaves a Phoenix behind. Until 09-13 it did every
# time: it ended in `exec cargo tauri dev`, `exec` discards the EXIT trap, and a
# dev server started on 09-06 was still running — and serving 500s — a week later.
#
# Runs a COPY of dev.sh inside temp repo-shaped folders with fake `mix`, `cargo`
# (a `sleep` standing in for the window) and Phoenix (a tiny Python server that
# ignores SIGHUP, like a BEAM). Never touches this repo, its database, or
# anything on :4000 it did not start itself, and refuses to run if :4000 is busy.
# Needs python3, perl and lsof. Opt-in; never in CI (it binds a real port).
#
# Scenarios: closing the window, Ctrl-C and closing the terminal with the window
# open, SIGKILL of the script, an unhealthy / orphaned / healthy server of this
# repo already on :4000, a foreign process on :4000, and a startup crash.
#
# Break the guard — point it at an older copy and watch it fail:
#   git show <rev>:scripts/dev.sh > /tmp/dev.sh.old
#   PORT=4000 DEVSH_T1_PORT=4000 DEVSH_SRC=/tmp/dev.sh.old scripts/smoke_dev_launcher.sh
# (PORT/DEVSH_T1_PORT get a pre-09-13 copy past its port bug, so its orphan bug
# is what fails.) On 09-13 the pre-fix script failed 12 checks here.
#
# Usage:
#   scripts/smoke_dev_launcher.sh
set -uo pipefail

SRC="${DEVSH_SRC:-$(cd "$(dirname "$0")" && pwd -P)/dev.sh}"
T1_PORT="${DEVSH_T1_PORT:-4400}"
FAILS=0

for tool in python3 perl lsof; do
  command -v "$tool" >/dev/null 2>&1 || { echo "abort: needs $tool"; exit 2; }
done

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
pause() { perl -e "select(undef,undef,undef,$1)"; }
listener() { lsof -nP -t -iTCP:4000 -sTCP:LISTEN 2>/dev/null | head -1; }
alive_pid() { [ -n "$1" ] || return 1; local s; s="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"; [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
wait_gone() { local i; for i in $(seq 1 "$2"); do alive_pid "$1" || return 0; pause 0.25; done; return 1; }
wait_listener() { local i; for i in $(seq 1 "$1"); do [ -n "$(listener)" ] && return 0; pause 0.25; done; return 1; }
wait_no_listener() { local i; for i in $(seq 1 "$1"); do [ -z "$(listener)" ] && return 0; pause 0.25; done; return 1; }
# The fake window is `sleep 60` in the script's process group: a child of the
# script for the fixed version, the script itself (after `exec`) for the old one.
# Signalling before it exists only tests the health-wait phase — the first draft
# of this smoke did that, and the pre-fix script passed.
wait_window() { local i; for i in $(seq 1 "$2"); do pgrep -g "$1" -f 'sleep 60' >/dev/null 2>&1 && return 0; pause 0.25; done; return 1; }
# Everything on :4000 during a run was started by this smoke.
reset_port() { local p; p="$(listener)"; [ -n "$p" ] && kill -9 "$p" 2>/dev/null; wait_no_listener 20; }

if [ -n "$(listener)" ]; then echo "abort: :4000 is already in use — stop your dev server first"; exit 2; fi
echo "testing: $SRC"

BASE="$(mktemp -d)"
BASE="$(cd "$BASE" && pwd -P)"
trap 'rm -rf "$BASE"' EXIT

mkdir -p "$BASE/bin" "$BASE/elsewhere"
cat >"$BASE/bin/fake_phx.py" <<'PY'
import http.server, os, signal
# Ignore HUP like a BEAM does, so a stopped server proves dev.sh stopped it.
signal.signal(signal.SIGHUP, signal.SIG_IGN)
status = int(os.environ.get("FAKE_STATUS", "200"))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(status); self.end_headers(); self.wfile.write(b"x")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY
cat >"$BASE/bin/mix" <<'SH'
#!/bin/bash
case "$1" in
  ecto.migrate) exit 0 ;;
  phx.server)
    if [ -n "${FAKE_PHX_CRASH:-}" ]; then echo "boom: fake startup crash"; exit 1; fi
    exec python3 "$(dirname "$0")/fake_phx.py" ;;
esac
exit 2
SH
cat >"$BASE/bin/cargo" <<'SH'
#!/bin/bash
exec sleep "${FAKE_WINDOW_SECONDS:-3}"
SH
chmod +x "$BASE/bin/mix" "$BASE/bin/cargo"
FAKE_PATH="$BASE/bin:$PATH"

mkrepo() {
  local r="$BASE/$1"
  mkdir -p "$r/scripts" "$r/desktop/tauri"
  cp "$SRC" "$r/scripts/dev.sh"
  echo "$r"
}

# dev.sh in its own process group with SIGINT restored to default — the way a
# terminal runs a foreground command. The subshell's own output goes to the log
# so this command substitution returns at once (the first draft held the pipe
# and three scenarios "passed" without running); `exec` all the way down makes
# the echoed pid the script itself, which is also its process group id.
launch_group() {
  local repo=$1 log=$2
  shift 2
  (cd /tmp && exec env PATH="$FAKE_PATH" "$@" perl -e '$SIG{INT}="DEFAULT"; setpgrp(0,0); exec @ARGV' \
    bash "$repo/scripts/dev.sh") >"$log" 2>&1 &
  echo $!
}

run_sync() { (cd /tmp && env PATH="$FAKE_PATH" "$@" bash "$R/scripts/dev.sh" 2>&1); }

echo "== T1: closing the window stops Phoenix; an inherited PORT is ignored"
R="$(mkrepo t1)"
out="$(run_sync PORT="$T1_PORT" FAKE_WINDOW_SECONDS=2)"; code=$?
if [ "$T1_PORT" != 4000 ]; then
  echo "$out" | grep -q "Ignoring PORT=$T1_PORT" && pass "T1 says it ignored PORT=$T1_PORT" || fail "T1 no PORT note"
fi
if echo "$out" | grep -q " ready"; then
  pass "T1 Phoenix answered on :4000"
  wait_no_listener 8 && pass "T1 window closed -> Phoenix stopped" || fail "T1 Phoenix still listening after the window closed"
else
  fail "T1 never ready: $out"
fi
[ "$code" -eq 0 ] && pass "T1 exit 0" || fail "T1 exit $code"
reset_port

for sig in INT HUP; do
  case $sig in INT) name="T2 Ctrl-C (SIGINT to the process group)" ;; HUP) name="T3 terminal closed (SIGHUP to the process group)" ;; esac
  echo "== $name, with the window open, stops Phoenix"
  R="$(mkrepo "t-$sig")"
  SPID="$(launch_group "$R" "$BASE/t-$sig.log" FAKE_WINDOW_SECONDS=60)"
  if wait_window "$SPID" 80 && [ -n "$(listener)" ]; then
    PHX="$(listener)"
    kill -"$sig" -- "-$SPID" 2>/dev/null
    wait_gone "$SPID" 40 && pass "$name: script exited" || fail "$name: script still running"
    wait_gone "$PHX" 40 && pass "$name: Phoenix stopped (it ignores SIG$sig itself)" || fail "$name: Phoenix $PHX survived"
  else
    fail "$name: window never opened: $(cat "$BASE/t-$sig.log")"
  fi
  kill -9 -- "-$SPID" 2>/dev/null
  reset_port
done

echo "== T4: SIGKILL of the script alone, with the window open -> Phoenix still stops"
R="$(mkrepo t4)"
SPID="$(launch_group "$R" "$BASE/t4.log" FAKE_WINDOW_SECONDS=60)"
if wait_window "$SPID" 80 && [ -n "$(listener)" ]; then
  PHX="$(listener)"
  kill -9 "$SPID"
  wait_gone "$PHX" 40 && pass "T4 Phoenix stopped within 10s of the script being killed" || fail "T4 Phoenix $PHX orphaned"
else
  fail "T4 window never opened: $(cat "$BASE/t4.log")"
fi
kill -9 -- "-$SPID" 2>/dev/null
reset_port

echo "== T5: this repo's server, unhealthy, still parented -> replaced"
R="$(mkrepo t5)"
(cd "$R" && exec env PORT=4000 FAKE_STATUS=500 python3 "$BASE/bin/fake_phx.py") >/dev/null 2>&1 &
OLD=$!
wait_listener 20
out="$(run_sync FAKE_WINDOW_SECONDS=2)"
echo "$out" | grep -q "not answering its health check" && pass "T5 said why it replaced it" || fail "T5 wrong reason: $out"
wait_gone "$OLD" 4 && pass "T5 old server stopped" || fail "T5 old server $OLD still alive"
wait_no_listener 8 && pass "T5 no server left on exit" || fail "T5 a server was left running"
kill -9 "$OLD" 2>/dev/null
reset_port

echo "== T6: this repo's server, healthy but orphaned (parent is launchd) -> replaced"
R="$(mkrepo t6)"
( (cd "$R" && exec env PORT=4000 python3 "$BASE/bin/fake_phx.py") >/dev/null 2>&1 & )
wait_listener 20
OLD="$(listener)"
if [ "$(ps -o ppid= -p "$OLD" | tr -d ' ')" = "1" ]; then
  out="$(run_sync FAKE_WINDOW_SECONDS=2)"
  echo "$out" | grep -q "left behind" && pass "T6 replaced the orphan instead of reusing it" || fail "T6 did not replace: $out"
  wait_gone "$OLD" 4 && pass "T6 orphan stopped" || fail "T6 orphan $OLD still alive"
  wait_no_listener 8 && pass "T6 no server left on exit" || fail "T6 a server was left running"
else
  fail "T6 precondition: orphan's ppid is $(ps -o ppid= -p "$OLD" | tr -d ' '), not 1"
fi
reset_port

echo "== T7: this repo's server, healthy, still parented -> reused and left running"
R="$(mkrepo t7)"
(cd "$R" && exec env PORT=4000 python3 "$BASE/bin/fake_phx.py") >/dev/null 2>&1 &
KEEP=$!
wait_listener 20
out="$(run_sync FAKE_WINDOW_SECONDS=2)"
echo "$out" | grep -q "reusing it" && pass "T7 reused the running server" || fail "T7 did not reuse: $out"
alive_pid "$KEEP" && pass "T7 reused server still running after exit" || fail "T7 reused server was stopped"
kill "$KEEP" 2>/dev/null
reset_port

echo "== T8: a foreign process on :4000 -> named, exit 1, never stopped"
R="$(mkrepo t8)"
(cd "$BASE/elsewhere" && exec env PORT=4000 python3 "$BASE/bin/fake_phx.py") >/dev/null 2>&1 &
FOREIGN=$!
wait_listener 20
out="$(run_sync FAKE_WINDOW_SECONDS=2)"; code=$?
[ "$code" -eq 1 ] && pass "T8 exit 1" || fail "T8 exit $code"
echo "$out" | grep -q "not this repo's dev server" && pass "T8 named the process" || fail "T8 message: $out"
alive_pid "$FOREIGN" && pass "T8 foreign process untouched" || fail "T8 foreign process was stopped"
kill "$FOREIGN" 2>/dev/null
reset_port

echo "== T9: Phoenix crashing during startup is reported, not waited on"
R="$(mkrepo t9)"
start=$(date +%s)
out="$(run_sync FAKE_PHX_CRASH=1 FAKE_WINDOW_SECONDS=2)"; code=$?
took=$(($(date +%s) - start))
[ "$code" -eq 1 ] && pass "T9 exit 1" || fail "T9 exit $code"
echo "$out" | grep -q "exited during startup" && echo "$out" | grep -q "boom" && pass "T9 showed the crash" || fail "T9 output: $out"
[ "$took" -lt 10 ] && pass "T9 took ${took}s" || fail "T9 took ${took}s"
reset_port

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; fi
exit "$FAILS"
