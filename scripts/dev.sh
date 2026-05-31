#!/usr/bin/env bash
# Launch Buster Claw for development with a single command.
#
# Starts Phoenix (if it isn't already running), waits until it answers on
# :4000, and only THEN opens the Tauri desktop window. Starting in this order
# avoids `cargo tauri dev`'s 180s wait-for-dev-server timeout, which is what
# makes the window silently fail to appear when Phoenix is slow to boot.
#
# Ctrl-C (or closing the window) tears down whatever this script started.
# An already-running Phoenix is reused and left alone on exit.
#
# Usage:
#   ./scripts/dev.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

HEALTH="http://127.0.0.1:4000/_health"
LOG_DIR="$REPO_ROOT/_build/dev"
PHX_LOG="$LOG_DIR/phx.server.log"
PHX_PID=""

cleanup() {
  if [[ -n "$PHX_PID" ]]; then
    echo ""
    echo "==> Stopping Phoenix (pid $PHX_PID)"
    kill "$PHX_PID" 2>/dev/null || true
    wait "$PHX_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

is_healthy() { curl -fsS -o /dev/null --max-time 2 "$HEALTH" 2>/dev/null; }

if is_healthy; then
  echo "==> Phoenix already running on :4000 — reusing it"
else
  echo "==> Starting Phoenix (logs: $PHX_LOG)"
  mkdir -p "$LOG_DIR"
  mix phx.server >"$PHX_LOG" 2>&1 &
  PHX_PID=$!

  printf "==> Waiting for Phoenix to answer on :4000"
  for _ in $(seq 1 240); do
    if is_healthy; then printf " ready\n"; break; fi
    if ! kill -0 "$PHX_PID" 2>/dev/null; then
      printf "\nerror: Phoenix exited during startup. Last log lines:\n" >&2
      tail -20 "$PHX_LOG" >&2
      exit 1
    fi
    printf "."
    sleep 1
  done

  if ! is_healthy; then
    printf "\nerror: Phoenix did not become healthy in time. See %s\n" "$PHX_LOG" >&2
    exit 1
  fi
fi

echo "==> Opening desktop window (cargo tauri dev)"
cd desktop/tauri
exec cargo tauri dev
