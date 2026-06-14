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

echo "==> Building Tauri bundle"
# tauri-build's copy_resources overwrites with fs::copy without removing first;
# the staged erts binaries are mode 0555, so a prior copy left read-only files
# that fail to overwrite (EACCES). Clear the previous staging dir first.
rm -rf desktop/tauri/target/release/release
cd desktop/tauri
cargo tauri build

BUNDLE_DIR="$REPO_ROOT/desktop/tauri/target/release/bundle/macos"

# Restore the dev-mode placeholder so `cargo tauri dev` keeps working without the
# full bundled release present.
touch "$REPO_ROOT/desktop/tauri/resources/release/.gitkeep"

echo ""
echo "==> Done."
echo "    App bundle: $BUNDLE_DIR/Buster Claw.app"
echo "    Launch:     open \"$BUNDLE_DIR/Buster Claw.app\""
