#!/usr/bin/env bash
# Build the Buster Claw desktop bundle: Phoenix release + Tauri shell.
# Output: desktop/tauri/target/release/bundle/macos/Buster Claw.app
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# Belt-and-suspenders: the bundle must never be compiled with dev/test config
# (which carries publicly-known API tokens). Every mix call below also prefixes
# this, and the release refuses to boot with dev tokens (BusterClaw.Application),
# but pin it for the whole script too.
export MIX_ENV=prod

# The DMG window-styling step (bundle_dmg.sh) drives Finder via AppleScript,
# which only works in an interactive GUI session. In a headless / CI / agent
# context (no controlling terminal) set CI=true so the bundler skips the
# cosmetic step and still produces a functional .dmg instead of erroring.
if [ ! -t 1 ] && [ -z "${CI:-}" ]; then
  export CI=true
  echo "==> Headless build detected — CI=true (DMG window styling skipped)"
fi

# --- Preflight: verify the toolchain a clean clone needs, with actionable
# messages instead of a deep mid-build error. Versions are pinned in
# .tool-versions; see BUILD.md. ---
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "  MISSING: $1 — $2" >&2
    return 1
  fi
}

preflight() {
  echo "==> Preflight: checking build toolchain"
  local missing=0
  require_cmd elixir "install Erlang/OTP + Elixir (see .tool-versions: \`asdf install\`)" || missing=1
  require_cmd mix "ships with Elixir" || missing=1
  require_cmd erl "install Erlang/OTP (see .tool-versions)" || missing=1
  require_cmd cargo "install Rust via https://rustup.rs" || missing=1
  require_cmd rustc "install Rust via https://rustup.rs" || missing=1
  require_cmd node "install Node.js (see .tool-versions)" || missing=1
  require_cmd npm "ships with Node.js" || missing=1
  if ! cargo tauri --version >/dev/null 2>&1; then
    echo "  MISSING: cargo-tauri — run \`cargo install tauri-cli\`" >&2
    missing=1
  fi
  if [[ "$missing" -ne 0 ]]; then
    echo "" >&2
    echo "Preflight failed: install the tools above, then re-run. See BUILD.md." >&2
    exit 1
  fi
  echo "    ok: $(elixir --version | tail -1), $(rustc --version), tauri-cli $(cargo tauri --version 2>/dev/null | awk '{print $NF}'), node $(node --version)"
}

preflight

echo "==> Syncing version from VERSION file"
"$REPO_ROOT/scripts/sync_version.sh"

echo "==> Fetching prod dependencies"
MIX_ENV=prod mix deps.get --only prod

echo "==> Installing JS dependencies (assets/node_modules via npm ci)"
# esbuild bundles assets/js/app.js, which imports @xterm/* from node_modules.
# node_modules is gitignored, so a clean clone must install it before deploy.
( cd assets && npm ci )

echo "==> Building production assets (tailwind, esbuild, phx.digest)"
MIX_ENV=prod mix assets.deploy

echo "==> Assembling Elixir release"
MIX_ENV=prod mix release --overwrite

echo "==> Staging release into Tauri resources"
rm -rf desktop/tauri/resources/release
mkdir -p desktop/tauri/resources
cp -R "$REPO_ROOT/_build/prod/rel/buster_claw" desktop/tauri/resources/release

# ERTS ships 65 binaries mode 555 (r-xr-xr-x), and `cp -R` preserves that.
# tauri-build's copy_resources copies them into target/<profile>/release with
# the mode intact, so the NEXT build-script rerun (any edit to build.rs,
# tauri.conf.json, capabilities/, or permissions/) fails overwriting a
# read-only destination: "failed to run tauri-build: Permission denied
# (os error 13)". The build script's fingerprint rarely invalidates, so this
# stays hidden until it isn't — then it looks like a broken toolchain.
# Owner-writable staging costs nothing; signing and bundling ignore the bit.
chmod -R u+w desktop/tauri/resources/release

# Assert the artifact, not the exit code. `cp` into an empty destination is not
# an error and cargo tauri will happily bundle an empty resources dir, so a
# broken staging step produces a .dmg that installs, launches, and never starts
# Phoenix — while every command in this script exits 0. That is not theoretical:
# a truncated edit in 2886f96 reduced the three lines above to `rm -rf deskt`,
# and every DMG built between 07-22 and 07-28 (including the ones CI uploaded)
# shipped an empty Resources/release. Nothing failed. Nobody noticed for six days.
STAGED_REL="desktop/tauri/resources/release"
if [ ! -x "$STAGED_REL/bin/buster_claw" ] || ! compgen -G "$STAGED_REL/erts-*" >/dev/null; then
  echo "" >&2
  echo "FATAL: release staging did not produce a runnable release." >&2
  echo "       expected: $STAGED_REL/bin/buster_claw (executable) + $STAGED_REL/erts-*" >&2
  echo "       found:    $(ls -A "$STAGED_REL" 2>/dev/null | tr '\n' ' ' || echo '<missing>')" >&2
  echo "" >&2
  echo "The bundle would ship an empty Resources/release and could not boot Phoenix." >&2
  echo "Check the staging block above and that \`mix release\` wrote _build/prod/rel/buster_claw." >&2
  exit 1
fi
echo "    staged $(du -sh "$STAGED_REL" | cut -f1) release + $(basename "$(echo "$STAGED_REL"/erts-*)")"

# Sign the OTP tree BEFORE Tauri bundles it. Tauri signs the shell, frameworks,
# and sidecars, but it only *copies* resources — its signer never descends into
# Resources/, where the entire Erlang VM lives. Doing it here, on the staged
# tree, is the last moment the binaries are ours to touch: anything signed after
# bundling invalidates the enclosing signature instead.
#
# No-op when APPLE_SIGNING_IDENTITY is unset, so unsigned local builds are
# unchanged. See scripts/codesign_release.sh and roadmaps/platform/APPLE_ROADMAP.md III.F.
"$REPO_ROOT/scripts/codesign_release.sh" "$STAGED_REL"

echo "==> Building Tauri bundle"
# tauri-build's copy_resources overwrites with fs::copy without removing first;
# the staged erts binaries are mode 0555, so a prior copy left read-only files
# that fail to overwrite (EACCES). Clear the previous staging dirs first — BOTH
# profiles: the debug one is populated by check_rust.sh (clippy/test builds),
# and a stale debug copy makes `mix precommit` fail the same way after the
# resources are restaged here.
rm -rf desktop/tauri/target/release/release desktop/tauri/target/debug/release
cd desktop/tauri

# UPDATE_ROADMAP G-18 — the updater tarball and its minisign signature.
#
# Secret-gated, exactly like the codesign pass above is gated on
# APPLE_SIGNING_IDENTITY: with no key the path is skipped and this script still
# produces a working unsigned bundle, which is what keeps local builds and
# keyless CI verification runs unchanged.
#
# It is a --config override rather than a committed `createUpdaterArtifacts: true`
# because Tauri FAILS the build outright when the flag is set and no signing key
# is available. Committing `true` would turn every keyless build into a hard
# error — the opposite of gating, and it would break the one CI job whose whole
# job is to verify the tree without secrets.
#
# The two signatures remain unrelated (APPLE_ROADMAP III.I): this produces the
# minisign one, which proves the update is ours. Apple's, applied above and by
# the bundler, is what Gatekeeper checks. Neither substitutes for the other.
if [ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
  echo "    updater artifacts: ON (TAURI_SIGNING_PRIVATE_KEY present)"
  cargo tauri build --config '{"bundle":{"createUpdaterArtifacts":true}}'
else
  echo "    updater artifacts: off (no TAURI_SIGNING_PRIVATE_KEY)"
  cargo tauri build
fi

BUNDLE_DIR="$REPO_ROOT/desktop/tauri/target/release/bundle/macos"

# Assert the BUNDLE carries the release, not just that staging did. The staging
# check above passes and then the staging dir stays live for the whole cargo
# build — and scripts/dev.sh deliberately empties it (down to .gitkeep) whenever
# a dev shell starts, because dev doesn't use the bundled release. Start dev.sh
# during this script's bundling window and Tauri bundles a hollowed-out dir:
# exactly that happened on 08-01 — the staging assert passed, the .app shipped
# with lib/tzdata-1.1.4 and nothing else, and only smoke_release_boot.sh
# caught it. Same rule as above: assert the artifact, at the last artifact.
BUNDLED_REL="$BUNDLE_DIR/Buster Claw.app/Contents/Resources/release"
if [ ! -x "$BUNDLED_REL/bin/buster_claw" ] || ! compgen -G "$BUNDLED_REL/erts-*" >/dev/null; then
  echo "" >&2
  echo "FATAL: the bundled .app does not carry a runnable release." >&2
  echo "       expected: .../Resources/release/bin/buster_claw (executable) + erts-*" >&2
  echo "       found:    $(ls -A "$BUNDLED_REL" 2>/dev/null | tr '\n' ' ' || echo '<missing>')" >&2
  echo "" >&2
  echo "Most likely a dev shell (scripts/dev.sh) started mid-build and emptied" >&2
  echo "desktop/tauri/resources/release while cargo was bundling. Close it (or" >&2
  echo "let it run — it only cleans at startup) and re-run this script." >&2
  exit 1
fi

# Restore the dev-mode placeholder so `cargo tauri dev` keeps working without the
# full bundled release present.
touch "$REPO_ROOT/desktop/tauri/resources/release/.gitkeep"

echo ""
echo "==> Done."
echo "    App bundle: $BUNDLE_DIR/Buster Claw.app"
echo "    Launch:     open \"$BUNDLE_DIR/Buster Claw.app\""
