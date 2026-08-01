#!/usr/bin/env bash
# Assert the macOS floor we ADVERTISE is one the bundle can actually meet.
#
# ## The bug this exists to prevent
#
# Measured 2026-08-01 against a real build: the Tauri shell carries `minos 11.0`
# and all 24 Mach-O objects of the bundled Erlang VM carry `minos 14.0`, while
# tauri.conf.json advertised `minimumSystemVersion: 11.0`.
#
# macOS refuses to load a Mach-O whose minimum-OS load command is newer than the
# running system. So on macOS 11, 12, or 13 that bundle installs, passes
# Gatekeeper, launches the shell — and then dyld rejects beam.smp and Phoenix
# never starts. The user gets a window that never becomes an app, and nothing in
# our pipeline notices, because the machine that built it is always new enough.
#
# ## Why it is not a one-time fix
#
# The VM's floor is inherited from whichever Erlang built the release, not chosen
# by us. A different build machine, a new asdf install, or a bumped CI runner
# image silently moves it. Correcting the number once fixes today's build and
# nothing else — so this asserts the invariant on every build instead.
#
# ## Contract
#
#   check_macos_floor.sh [path/to/Buster Claw.app]
#
# Exits non-zero if any bundled Mach-O requires a newer macOS than the bundle
# advertises. Prints the measured floor either way, so raising the declared floor
# is a deliberate, informed edit rather than a guess.
set -euo pipefail

APP_NAME="Buster Claw"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")/.."

APP="${1:-desktop/tauri/target/release/bundle/macos/$APP_NAME.app}"
[ -d "$APP" ] || fail "no .app at $APP — run scripts/build_desktop.sh first"

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || fail "no Info.plist in $APP"

# Read what SHIPS, not what the source config says. They are normally the same,
# but the plist inside the bundle is the one Gatekeeper and the installer read.
DECLARED="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST" 2>/dev/null || true)"
[ -n "$DECLARED" ] || fail "the bundle declares no LSMinimumSystemVersion"

say "bundle advertises macOS $DECLARED"

# vtool reports the LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX load command. A
# binary with no such command (rare, mostly older static objects) is skipped
# rather than assumed safe — it is reported at the end so it cannot hide.
MEASURED="0.0"
WORST_OBJECT=""
UNKNOWN=0
COUNT=0

while IFS= read -r -d '' object; do
  file -b "$object" | grep -q 'Mach-O' || continue
  COUNT=$((COUNT + 1))
  minos="$(vtool -show-build "$object" 2>/dev/null | awk '/minos/{print $2; exit}')"
  if [ -z "$minos" ]; then
    UNKNOWN=$((UNKNOWN + 1))
    continue
  fi
  # Highest wins: the bundle can only run where its most demanding binary runs.
  if [ "$(printf '%s\n%s\n' "$MEASURED" "$minos" | sort -V | tail -1)" = "$minos" ] &&
     [ "$minos" != "$MEASURED" ]; then
    MEASURED="$minos"
    WORST_OBJECT="${object##*/}"
  fi
done < <(find "$APP" -type f -print0)

[ "$COUNT" -gt 0 ] || fail "found no Mach-O objects in $APP — is this a real bundle?"

say "scanned $COUNT Mach-O objects; highest requirement is macOS $MEASURED ($WORST_OBJECT)"
[ "$UNKNOWN" -eq 0 ] || say "  note: $UNKNOWN object(s) carried no build-version command and were skipped"

# The comparison that matters: advertising a floor BELOW what the binaries need
# ships a bundle that cannot run on the systems we invited.
if [ "$(printf '%s\n%s\n' "$DECLARED" "$MEASURED" | sort -V | tail -1)" != "$DECLARED" ]; then
  echo "" >&2
  fail "the bundle advertises macOS $DECLARED but $WORST_OBJECT requires macOS $MEASURED.
       On macOS between those versions this app installs, passes Gatekeeper,
       launches the shell, and then dyld refuses the VM — Phoenix never starts.
       Fix by raising minimumSystemVersion in desktop/tauri/tauri.conf.json to
       $MEASURED, or by building the OTP release against an older deployment
       target (MACOSX_DEPLOYMENT_TARGET) if that floor is too high to accept."
fi

if [ "$DECLARED" != "$MEASURED" ]; then
  say "PASS — advertised floor ($DECLARED) is at or above the measured floor ($MEASURED)"
  say "  the gap is safe but wasteful: it excludes macOS $MEASURED users for no technical reason"
else
  say "PASS — advertised floor matches the measured floor exactly"
fi
