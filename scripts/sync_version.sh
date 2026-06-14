#!/usr/bin/env bash
# Propagate the single source of truth (repo-root VERSION) into the Tauri config
# (JSON) and the Rust crate (Cargo.toml). mix.exs reads VERSION directly, so a
# release only ever requires editing VERSION. Idempotent; safe to run anytime.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
if [[ -z "$VERSION" ]]; then
  echo "sync_version: VERSION file is empty or missing" >&2
  exit 1
fi

echo "==> Syncing version $VERSION into tauri.conf.json + Cargo.toml"

# tauri.conf.json has exactly one "version" key.
V="$VERSION" perl -i -pe 's/"version":\s*"[^"]*"/"version": "$ENV{V}"/' \
  "$REPO_ROOT/desktop/tauri/tauri.conf.json"

# Cargo.toml: the [package] version is the only `version = "..."` anchored at
# column 0 (dependency versions are inline tables). Replace just the first one.
V="$VERSION" perl -i -pe 'if (!$seen && /^version\s*=/) { s/^version\s*=\s*"[^"]*"/version = "$ENV{V}"/; $seen=1 }' \
  "$REPO_ROOT/desktop/tauri/Cargo.toml"
