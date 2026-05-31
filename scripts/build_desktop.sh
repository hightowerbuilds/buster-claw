#!/usr/bin/env bash
# Build the Buster Claw desktop bundle: Phoenix release + Tauri shell.
# Output: desktop/tauri/target/release/bundle/macos/Buster Claw.app
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

echo "==> Fetching prod dependencies"
MIX_ENV=prod mix deps.get --only prod

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
