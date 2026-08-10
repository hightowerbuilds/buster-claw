#!/usr/bin/env bash
# Prove the PACKAGED release actually boots — headless, no GUI, no network.
#
# ## Why this exists
#
# Every gate we had tested source. None tested the artifact. Commit 2886f96
# truncated the release-staging lines in build_desktop.sh to `rm -rf deskt`, and
# for six days every DMG — including the ones CI uploaded — shipped an empty
# Resources/release and could not boot Phoenix. Five CI jobs stayed green the
# whole time, because the only thing CI asserted about the DMG was that the file
# existed. See roadmaps/platform/APPLE_ROADMAP.md G-5.
#
# ## Why it drives the release binary rather than the .app
#
# scripts/smoke_desktop.sh launches the real bundle and exercises the native
# bridge, the hidden webview, and a real Chromium. That is the better test and it
# needs a window server, an installed browser, a Keychain, and the network — four
# things a build runner may not have and none of which BLOCKER-1 involved.
#
# This script takes the narrow, robust half: spawn the bundled Phoenix release
# exactly the way desktop/tauri/src/main.rs spawns it (same env, same flags) and
# assert it serves. No window server, no Keychain, no Chromium, no internet. It
# catches an empty or broken Resources/release — which is the failure that
# actually shipped — and it can run anywhere.
#
# The two are complements, not alternatives: this one gates CI, smoke_desktop.sh
# gates a release.
#
# ## Contract
#
#   smoke_release_boot.sh [path/to/Buster Claw.app]
#
# Exits 0 only if the bundled release boots, serves /_health, lists a plausible
# command catalog, and rejects a bad token.
set -euo pipefail

APP_NAME="Buster Claw"
# A catalog far below the real surface means commands failed to register — the
# packaged-ACL failure class. 100 is a floor, not a target: the surface measured
# 157 on 2026-08-01, and this is meant to catch collapse, not drift.
MIN_COMMANDS="${MIN_COMMANDS:-100}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-90}"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")/.."

APP="${1:-desktop/tauri/target/release/bundle/macos/$APP_NAME.app}"
[ -d "$APP" ] || fail "no .app at $APP — run scripts/build_desktop.sh first"

RELEASE_BIN="$APP/Contents/Resources/release/bin/buster_claw"
RELEASE_DIR="$APP/Contents/Resources/release"

# The BLOCKER-1 assertion, made against the BUNDLE rather than the staging dir.
# build_desktop.sh already checks the staged tree; this checks what Tauri
# actually copied, which is a different question and the one that shipped broken.
say "checking the bundle carries a release"
[ -x "$RELEASE_BIN" ] || fail "no executable release at $RELEASE_BIN — the bundle has no Erlang VM"
compgen -G "$RELEASE_DIR"/erts-* >/dev/null || fail "no erts-* in $RELEASE_DIR — the bundle has no ERTS"
BEAM="$(find "$RELEASE_DIR" -name beam.smp -print -quit)"
[ -n "$BEAM" ] || fail "no beam.smp under $RELEASE_DIR"
say "  $(basename "$(echo "$RELEASE_DIR"/erts-*)") · beam.smp is $(lipo -archs "$BEAM")"

# Everything the release writes goes in a temp dir so this never touches the
# operator's real database, workspace, or Application Support state.
TMP="$(mktemp -d)"
PID=""

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    # The `start` script execs erlexec, which becomes beam.smp. Killing the
    # script's pid does not always reap the VM, and an orphaned beam.smp holding
    # the SQLite file is exactly the confusing failure III.I warns about — so
    # match on this run's unique temp path rather than on the binary name, which
    # would also match the operator's real app.
    sleep 1
    pkill -f "$TMP" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# Ask the kernel for a free port instead of guessing one: a hardcoded port turns
# a busy runner into a mystery failure.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
TOKEN="smoke-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
# Phoenix rejects a short secret outright; 64 bytes is the documented minimum.
SECRET="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 64)"

say "booting the bundled release on 127.0.0.1:$PORT"

# Spawned exactly as desktop/tauri/src/main.rs spawns it (ReleaseLauncher::
# spawn_release). RELEASE_DISTRIBUTION=none keeps epmd out of it, which is both
# what the shell does and what makes this safe to run on a shared runner.
PHX_SERVER=true \
PORT="$PORT" \
DATABASE_PATH="$TMP/smoke.db" \
BUSTER_CLAW_WORKSPACE_ROOT="$TMP/workspace" \
SECRET_KEY_BASE="$SECRET" \
BUSTER_CLAW_API_TOKEN="$TOKEN" \
BUSTER_CLAW_MCP_API_TOKEN="$TOKEN-mcp" \
RELEASE_DISTRIBUTION=none \
  "$RELEASE_BIN" start >"$TMP/stdout.log" 2>"$TMP/stderr.log" &
PID=$!

BASE="http://127.0.0.1:$PORT"
say "waiting for /_health (up to ${BOOT_TIMEOUT}s)"
HEALTHY=0
for _ in $(seq 1 "$BOOT_TIMEOUT"); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "--- stderr ---" >&2; tail -40 "$TMP/stderr.log" >&2
    echo "--- stdout ---" >&2; tail -40 "$TMP/stdout.log" >&2
    fail "the release exited before serving /_health"
  fi
  if curl -fsS --max-time 2 "$BASE/_health" >/dev/null 2>&1; then HEALTHY=1; break; fi
  sleep 1
done
if [ "$HEALTHY" != 1 ]; then
  echo "--- stderr ---" >&2; tail -40 "$TMP/stderr.log" >&2
  fail "/_health never returned 200 within ${BOOT_TIMEOUT}s"
fi
say "  Phoenix is serving"

say "catalog: GET /api/commands"
COUNT="$(curl -fsS "$BASE/api/commands" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("commands", d if isinstance(d, list) else [])))')"
[ "$COUNT" -ge "$MIN_COMMANDS" ] || fail "catalog returned $COUNT commands, expected >= $MIN_COMMANDS"
say "  $COUNT commands listed"

# Not an authorization test — that is smoke_desktop.sh's and the ACL suite's job.
# This only proves the token wall is actually mounted in the packaged build, so a
# release that boots wide open cannot pass.
say "auth: a bad token must 401"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/run" \
  -H "authorization: Bearer not-the-token" -H "content-type: application/json" \
  -d '{"command":"runtime_status"}')"
[ "$STATUS" = 401 ] || fail "bad token got $STATUS, expected 401"

say "PASS — the bundled release boots, serves, and rejects a bad token"
