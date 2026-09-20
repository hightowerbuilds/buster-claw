#!/usr/bin/env bash
# UPDATE_ROADMAP G-46 — make the updater trap loud.
#
# A minisign key in the environment turns on `createUpdaterArtifacts`
# (build_desktop.sh), and Tauri can only build those artifacts when
# tauri.conf.json carries a `plugins.updater` block. That block is G-19a, and
# until it lands the combination fails like this, several minutes into the
# build, after `mix release` and most of the Rust compile:
#
#     failed to get updater configuration: plugins > updater doesn't exist
#
# which reads as a Tauri bug rather than as a missing gate. It cost a release
# rehearsal on 08-22. This refuses the same combination in under a second, before
# anything is compiled and before anything Apple sees, and says which gate is
# missing.
#
# It stays useful after G-19a lands: it is the assertion that would have caught
# this on day one, and someone deleting the config block later gets a sentence
# instead of a riddle.
#
# The check is on the KEY, not on CI or on a tag. With no key this exits 0 and
# says nothing, because a keyless build does not ask for updater artifacts and
# does not need the block -- that is what keeps local builds and the keyless CI
# verification run unchanged.
#
# Usage:
#   scripts/check_updater_config.sh [path/to/tauri.conf.json]
#
# Separate from build_desktop.sh so it can be run, and tested, without a build:
# test/scripts/check_updater_config_test.exs drives all four combinations.
set -euo pipefail

cd "$(dirname "$0")/.."
CONF="${1:-desktop/tauri/tauri.conf.json}"

if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
  exit 0
fi

if [ ! -f "$CONF" ]; then
  echo "FAIL: $CONF does not exist, so the updater config cannot be checked." >&2
  exit 1
fi

# node rather than jq or python: it is already a hard requirement of this build
# (build_desktop.sh's preflight), so the guard adds no dependency of its own.
# An `updater` that is present but not an object -- `null`, `true`, a string --
# is absent for this purpose: Tauri needs the endpoint and the pubkey inside it.
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required to read $CONF (see .tool-versions)." >&2
  exit 1
fi

if node -e '
  const conf = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const updater = conf && conf.plugins && conf.plugins.updater;
  const ok = updater !== null && typeof updater === "object" && !Array.isArray(updater);
  process.exit(ok ? 0 : 1);
' "$CONF"; then
  exit 0
fi

cat >&2 <<EOF
FAIL: TAURI_SIGNING_PRIVATE_KEY is set, but $CONF has no plugins.updater block.

  The key turns on updater artifacts, and Tauri cannot build them without that
  block. Left alone this fails minutes from now, after the Elixir release and
  most of the Rust compile, as:

      failed to get updater configuration: plugins > updater doesn't exist

  That block is UPDATE_ROADMAP G-19a, and it has not landed. Two ways forward:

    * To build WITHOUT updater artifacts (a plain signed DMG, which is what
      every release so far has been): unset TAURI_SIGNING_PRIVATE_KEY.
    * To build WITH them: land G-19a first. It is a one-way door -- the public
      key compiles into every binary and cannot be revoked -- so confirm the
      keypair is backed up offline before writing the block.

  See daily-growth/roadmaps/platform/UPDATE_ROADMAP.md, Phase 2b.
EOF
exit 1
