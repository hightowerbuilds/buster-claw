#!/usr/bin/env bash
# Launch Buster Claw for development with a single command.
#
# Starts Phoenix (if it isn't already running), waits until it answers on
# :4000, and only THEN opens the Tauri desktop window. Starting in this order
# avoids `cargo tauri dev`'s 180s wait-for-dev-server timeout, which is what
# makes the window silently fail to appear when Phoenix is slow to boot.
#
# Ctrl-C (or closing the window) tears down whatever this script started.
# An already-running Phoenix is reused — UNLESS it's missing env that .env now
# provides (a process started before .env changed). config/runtime.exs only reads
# env at boot, so a stale server is restarted rather than silently reused.
#
# Usage:
#   ./scripts/dev.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# Load local secrets/env (gitignored) so the dev server inherits them — e.g.
# FINNHUB_API_KEY for the finance_* commands. Optional; absent .env is fine.
if [[ -f "$REPO_ROOT/.env" ]]; then
  echo "==> Loading $REPO_ROOT/.env"
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

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

start_phoenix() {
  # Apply pending migrations before booting. In dev the Ecto.Migrator child is
  # started with skip: true (migrations only auto-run in releases), so Phoenix's
  # pending-migration guard would otherwise halt startup.
  echo "==> Applying database migrations (mix ecto.migrate)"
  if ! mix ecto.migrate; then
    echo "error: mix ecto.migrate failed — fix the migration before starting" >&2
    exit 1
  fi

  echo "==> Starting Phoenix (logs: $PHX_LOG)"
  mkdir -p "$LOG_DIR"
  mix phx.server >"$PHX_LOG" 2>&1 &
  PHX_PID=$!

  printf "==> Waiting for Phoenix to answer on :4000"
  for _ in $(seq 1 240); do
    if is_healthy; then printf " ready\n"; return 0; fi
    if ! kill -0 "$PHX_PID" 2>/dev/null; then
      printf "\nerror: Phoenix exited during startup. Last log lines:\n" >&2
      tail -20 "$PHX_LOG" >&2
      exit 1
    fi
    printf "."
    sleep 1
  done

  printf "\nerror: Phoenix did not become healthy in time. See %s\n" "$PHX_LOG" >&2
  exit 1
}

# Names of the variables defined in .env (so we can tell whether a server that's
# already running actually has them).
env_var_names() {
  [[ -f "$REPO_ROOT/.env" ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/.env" \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/'
}

# True if a phx.server is running but missing a var that .env would provide —
# meaning it booted before the current .env, so reusing it would silently run
# with stale config.
running_server_missing_env() {
  local pid env_dump name
  pid="$(pgrep -f 'phx.server' 2>/dev/null | head -1 || true)"
  [[ -n "$pid" ]] || return 1
  env_dump="$(ps eww "$pid" 2>/dev/null || true)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! grep -q "${name}=" <<<"$env_dump"; then
      echo "    running server (pid $pid) is missing $name"
      return 0
    fi
  done < <(env_var_names)
  return 1
}

restart_stale_server() {
  echo "==> Phoenix on :4000 is stale (missing env from .env) — restarting it"
  pkill -f "phx.server" 2>/dev/null || true
  for _ in $(seq 1 20); do is_healthy || return 0; sleep 0.5; done
  echo "error: couldn't free :4000 — a phx.server is still listening" >&2
  exit 1
}

if is_healthy; then
  if running_server_missing_env; then
    restart_stale_server
    start_phoenix
  else
    echo "==> Phoenix already running on :4000 — reusing it"
  fi
else
  start_phoenix
fi

echo "==> Opening desktop window (cargo tauri dev)"
cd desktop/tauri
exec cargo tauri dev
