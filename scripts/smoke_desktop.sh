#!/usr/bin/env bash
# Packaged-app smoke test — the dynamic half of July-17 prevention.
#
# tests/acl_lockstep.rs proves command registration statically; this proves it
# in the shipped artifact: with the real .app running (real Keychain, real data
# dir, bundled release), drive the Phoenix HTTP API from outside and force one
# full agent round-trip through the native bridge (Phoenix -> PubSub ->
# LiveView -> ScreenshotBridge JS -> Tauri invoke -> POST back). A command
# that is ACL-dead in the packaged build fails here and nowhere else.
#
# Run manually before a release:
#   ./scripts/smoke_desktop.sh [path/to/Buster Claw.app]
#
# If the app is already running, the smoke ATTACHES to the live instance
# (read-only checks, no quit). Otherwise it launches the bundle and quits it
# afterwards. The API token comes from $BUSTER_CLAW_API_TOKEN or the macOS
# Keychain (`security` may prompt — click Allow). The live render against
# https://example.com is the definitive check; SMOKE_OFFLINE=1 skips it (and
# with it most of the ACL verification) when there is no network.
set -euo pipefail

APP_NAME="Buster Claw"
LAUNCHED=0

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }

cleanup() {
  if [ "$LAUNCHED" = 1 ]; then
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
    sleep 2
    pgrep -f "$APP_NAME.app/Contents/MacOS" >/dev/null 2>&1 \
      && pkill -f "$APP_NAME.app/Contents/MacOS" || true
  fi
}
trap cleanup EXIT

fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*"; exit 1; }

# Match the Tauri shell binary itself — NOT epmd or other bundle leftovers
# that outlive the app (a stale epmd from a previous run is normal).
RUNNING_PATTERN="$APP_NAME.app/Contents/MacOS"
if pgrep -f "$RUNNING_PATTERN" >/dev/null 2>&1; then
  say "$APP_NAME is already running — attaching to the live instance (no quit on exit)"
else
  APP="${1:-$(ls -d desktop/tauri/target/release/bundle/macos/"$APP_NAME".app 2>/dev/null || true)}"
  [ -n "$APP" ] && [ -d "$APP" ] || fail "no .app found — pass a path or run scripts/build_desktop.sh first"
  say "launching $APP"
  open "$APP"
  LAUNCHED=1
fi

say "resolving API token"
TOKEN="${BUSTER_CLAW_API_TOKEN:-$(security find-generic-password -s BusterClaw -a api_token -w 2>/dev/null || true)}"
[ -n "$TOKEN" ] || fail "no API token: set BUSTER_CLAW_API_TOKEN or allow Keychain access"

say "waiting for the release BEAM to listen"
PORT=""
for _ in $(seq 1 90); do
  # The listener is the bundled release BEAM (spawned from Resources/release).
  # A stale epmd from the same bundle also matches the pattern — its :4369
  # listener is excluded below so it can't masquerade as Phoenix.
  for pid in $(pgrep -f "$APP_NAME.app/Contents/Resources/release" 2>/dev/null || true); do
    PORT=$(lsof -a -p "$pid" -iTCP -sTCP:LISTEN -P -n 2>/dev/null |
      awk '/127\.0\.0\.1:[0-9]+/ {sub(/.*:/, "", $9); if ($9 != 4369) {print $9; exit}}') || true
    [ -n "$PORT" ] && break
  done
  [ -n "$PORT" ] && break
  sleep 1
done
[ -n "$PORT" ] || fail "no loopback listener appeared within 90s"
BASE="http://127.0.0.1:$PORT"

say "waiting for /_health at $BASE"
HEALTHY=0
for _ in $(seq 1 60); do
  curl -fsS --max-time 2 "$BASE/_health" >/dev/null 2>&1 && HEALTHY=1 && break
  sleep 1
done
[ "$HEALTHY" = 1 ] || fail "/_health never returned 200"

say "catalog: GET /api/commands"
COUNT=$(curl -fsS "$BASE/api/commands" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("commands", d if isinstance(d, list) else [])))')
[ "$COUNT" -ge 100 ] || fail "catalog returned only $COUNT commands"
say "  $COUNT commands listed"

say "auth: a bad token must 401"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/run" \
  -H "authorization: Bearer not-the-token" -H "content-type: application/json" \
  -d '{"command":"browser_current"}')
[ "$STATUS" = 401 ] || fail "bad token got $STATUS, expected 401"

say "waiting for the ScreenshotBridge to connect (app webview LiveView)"
# The API launders unknown error strings to "unexpected error" (by design —
# ErrorFormatter never echoes raw internals), so this probe can only
# distinguish bridge-down ("browser_unavailable"), bridge-timeout ("timeout"),
# and bridge-up (ok or a laundered desktop-side error). The definitive ACL
# check is the positive render below.
BRIDGE=0
for _ in $(seq 1 30); do
  BODY=$(curl -sS --max-time 15 -X POST "$BASE/api/run" \
    -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
    -d '{"command":"browser_current"}' || true)
  case "$BODY" in
    *browser_unavailable*) sleep 1 ;;
    *'"error":"timeout"'*) fail "bridge subscriber present but the round-trip timed out: $BODY" ;;
    *'"ok":true'*|*"unexpected error"*) BRIDGE=1; break ;;
    *) sleep 1 ;;
  esac
done
[ "$BRIDGE" = 1 ] || fail "ScreenshotBridge never connected: $BODY"
say "  bridge round-trip completed: $(echo "$BODY" | head -c 100)"

if [ "${SMOKE_OFFLINE:-0}" = 1 ]; then
  say "OFFLINE MODE: skipping the live render — ACL verification is reduced to the bridge probe"
else
  say "live render (the ACL-dead detector): browser_fetch render=live against example.com"
  # browser_render_page needs no open browser surface; real page text coming
  # back proves the packaged ACL, the hidden-webview creation, the injected
  # read script, and the full JS<->Rust<->Phoenix loop — nothing can fake it.
  BODY=$(curl -sS --max-time 90 -X POST "$BASE/api/run" \
    -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
    -d '{"command":"browser_fetch","args":{"url":"https://example.com","render":"live"}}')
  echo "$BODY" | grep -q "Example Domain" \
    || fail "live render returned no page text (ACL-dead command or broken bridge?): $(echo "$BODY" | head -c 200)"
  say "  hidden-webview render returned real page text"
fi

say "BrowserControl engine probe (BROWSER_ENGINE_ROADMAP Phase 0)"
# Launches an installed Chromium-family browser headless over the CDP pipe from
# INSIDE the packaged release, navigates, reads a title back, exits cleanly.
# This is the anti-Browserbase gate: the engine must work in the shipped
# artifact, not just in dev. Absence of any Chromium is a loud, named failure —
# SMOKE_NO_ENGINE=1 downgrades exactly that one case for engine-less machines.
BODY=$(curl -sS --max-time 90 -X POST "$BASE/api/run" \
  -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d '{"command":"browser_control_probe"}')
if echo "$BODY" | grep -q '"ok":true'; then
  echo "$BODY" | grep -q '"title":"bc-probe"' \
    || fail "engine probe ok but wrong title read back: $(echo "$BODY" | head -c 200)"
  say "  engine launched, navigated, read back, exited: $(echo "$BODY" | head -c 120)"
elif echo "$BODY" | grep -q 'no_browser'; then
  if [ "${SMOKE_NO_ENGINE:-0}" = 1 ]; then
    say "  NO ENGINE on this machine (accepted via SMOKE_NO_ENGINE=1) — probe not exercised"
  else
    fail "no Chromium-family browser installed (set SMOKE_NO_ENGINE=1 to accept): $BODY"
  fi
else
  fail "engine probe failed in the packaged app: $(echo "$BODY" | head -c 300)"
fi

say "PASS — packaged app boots, authenticates, and completes a native bridge round-trip"
