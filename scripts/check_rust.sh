#!/usr/bin/env bash
# The Rust gate for the desktop shell — run locally (mix precommit) and in CI
# (.github/workflows/ci.yml `rust` job). One artifact so the three places that
# describe the gate (this script, CI, docs/QUALITY.md) can never disagree.
# Toolchain is pinned by desktop/tauri/rust-toolchain.toml; rustup auto-installs
# it (with rustfmt + clippy) on first use.
set -euo pipefail

cd "$(dirname "$0")/../desktop/tauri"

echo "==> cargo fmt --check"
cargo fmt --check

echo "==> cargo clippy --all-targets -- -D warnings"
cargo clippy --all-targets -- -D warnings

echo "==> cargo test"
cargo test
