#!/usr/bin/env bash
# Launch Buster Claw for development with a single command.
#
# Starts Phoenix on :4000 (or reuses a healthy one), waits until it answers, and
# only THEN opens the Tauri desktop window. Starting in this order avoids
# `cargo tauri dev`'s 180s wait-for-dev-server timeout, which is what makes the
# window silently fail to appear when Phoenix is slow to boot.
#
# ## The Phoenix this script starts stops with it
#
# Closing the window, Ctrl-C, closing the terminal, and killing this script all
# stop the Phoenix it started. Until 09-13 none of them did. The last line was
# `exec cargo tauri dev`, and `exec` replaces this shell with cargo, which
# discards the EXIT trap — so every launch that started a server left it running
# when the window closed. One ran from 09-06 to 09-13, kept pulling phone events
# into the dev database all week, and broke the next launch when a config change
# made it answer every request with a 500. cargo now runs as a child, and a
# watchdog stops Phoenix even if this script dies without running its traps.
#
# ## What it does with a server already on :4000
#
# - Nothing there: start Phoenix.
# - This repo's server, healthy, still run by something, and started with every
#   variable .env sets: reuse it, and leave it running on exit. It belongs to
#   whoever started it.
# - This repo's server that is orphaned (its parent is gone), unhealthy, or
#   missing a .env variable: stop it and start fresh. config/runtime.exs reads
#   env only at boot, and a server whose config changed answers everything with
#   a 500.
# - Any other process: say what it is and exit. It is never stopped.
#
# "This repo's server" means the process listening on :4000 has this repo as its
# working directory, and it is the only thing this script will ever stop. The
# old stale-server path ran `pkill -f phx.server`, which matches every Phoenix
# app on the machine, Tractor Beam's own server included.
#
# ## The port is always 4000
#
# The health check and Tauri's devUrl are both :4000, so a PORT inherited from the
# environment can only break the launch. A terminal inside Tractor Beam exports
# PORT=4400, its own server's port, which is how the 09-13 launch died with
# :eaddrinuse. PORT is pinned after .env loads.
#
# Usage:
#   ./scripts/dev.sh
set -euo pipefail

cd "$(dirname "$0")/.."
# Physical path: lsof reports a process's working directory with symlinks
# resolved, and that comparison is what identifies this repo's server.
REPO_ROOT="$(pwd -P)"

# Load local secrets/env (gitignored) so the dev server inherits them — e.g.
# FINNHUB_API_KEY for the finance_* commands. Optional; absent .env is fine.
if [[ -f "$REPO_ROOT/.env" ]]; then
  echo "==> Loading $REPO_ROOT/.env"
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

DEV_PORT=4000
if [[ -n "${PORT:-}" && "$PORT" != "$DEV_PORT" ]]; then
  echo "==> Ignoring PORT=$PORT from the environment — the desktop window only talks to :$DEV_PORT"
fi
export PORT="$DEV_PORT"

HEALTH="http://127.0.0.1:$DEV_PORT/_health"
LOG_DIR="$REPO_ROOT/_build/dev"
PHX_LOG="$LOG_DIR/phx.server.log"
PHX_PID=""
WATCHDOG_PID=""
REUSING=0

# --- processes ---------------------------------------------------------------

# Running, and not a zombie. `kill -0` succeeds on a zombie, and a Phoenix that
# exits during startup is a zombie child of this shell until it is reaped.
alive() {
  local stat
  stat="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ' || true)"
  [[ -n "$stat" && "$stat" != Z* ]]
}

# TERM, then up to 15s for the BEAM to run its supervision tree down, then KILL.
stop_pid() {
  local pid=$1 i
  alive "$pid" || return 0
  kill "$pid" 2>/dev/null || true
  for i in $(seq 1 30); do
    alive "$pid" || return 0
    sleep 0.5
  done
  echo "    pid $pid ignored SIGTERM for 15s — sending SIGKILL" >&2
  kill -9 "$pid" 2>/dev/null || true
}

describe_pid() { ps -o pid= -o lstart= -o command= -p "$1" 2>/dev/null | cut -c1-160 || true; }
parent_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ' || true; }
cwd_of() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true; }
listener_pid() { lsof -nP -t -iTCP:"$DEV_PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true; }
is_healthy() { curl -fsS -o /dev/null --max-time 2 "$HEALTH" 2>/dev/null; }

# The traps below cover every ending the shell is allowed to see. This covers
# the rest (SIGKILL, a terminal that kills its processes outright) by polling for
# this script and stopping Phoenix once the script is gone. It ignores HUP so a
# closing terminal cannot take it down before it has done that.
watchdog() {
  trap - EXIT TERM
  trap '' HUP
  local parent=$1 child=$2
  while alive "$parent" && alive "$child"; do
    sleep 2
  done
  if alive "$child" && ! alive "$parent"; then
    stop_pid "$child"
  fi
}

cleanup() {
  # No errexit in here: a write to a terminal that has already closed fails, and
  # stopping half-way through is how a server gets left behind.
  set +e
  if [[ -n "$PHX_PID" ]]; then
    echo ""
    echo "==> Stopping Phoenix (pid $PHX_PID)"
    stop_pid "$PHX_PID"
    wait "$PHX_PID" 2>/dev/null
    PHX_PID=""
  fi
  # After Phoenix, not before: the watchdog is the backstop until Phoenix is
  # actually down.
  if [[ -n "$WATCHDOG_PID" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null
    WATCHDOG_PID=""
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- .env drift ----------------------------------------------------------------

# Names of the variables .env defines, so a running server can be checked for
# them.
env_var_names() {
  [[ -f "$REPO_ROOT/.env" ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/.env" \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/'
}

# Prints the first .env variable the given process was started without, and
# succeeds. Fails when it has them all.
missing_env_var() {
  local pid=$1 env_dump name
  env_dump="$(ps eww "$pid" 2>/dev/null || true)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! grep -q "${name}=" <<<"$env_dump"; then
      echo "$name"
      return 0
    fi
  done < <(env_var_names)
  return 1
}

# --- the port ------------------------------------------------------------------

# Decide what to do about whatever already holds :4000. See the header.
prepare_port() {
  local pid cwd missing reason
  pid="$(listener_pid)"
  [[ -n "$pid" ]] || return 0

  cwd="$(cwd_of "$pid")"
  if [[ "$cwd" != "$REPO_ROOT" ]]; then
    echo "error: :$DEV_PORT is held by a process that is not this repo's dev server:" >&2
    echo "    $(describe_pid "$pid")" >&2
    echo "    working directory: ${cwd:-unknown}" >&2
    echo "  This script will not stop it. Free the port, then run this again." >&2
    exit 1
  fi

  if [[ "$(parent_of "$pid")" == "1" ]]; then
    reason="it was left behind, and nothing is running it any more"
  elif ! is_healthy; then
    reason="it is not answering its health check"
  elif missing="$(missing_env_var "$pid")"; then
    reason="it was started without $missing from .env"
  else
    echo "==> Phoenix already running on :$DEV_PORT (pid $pid) — reusing it; it stays up when this exits"
    REUSING=1
    return 0
  fi

  echo "==> Replacing the Phoenix on :$DEV_PORT: $reason"
  echo "    $(describe_pid "$pid")"
  stop_pid "$pid"
  if [[ -n "$(listener_pid)" ]]; then
    echo "error: couldn't free :$DEV_PORT" >&2
    exit 1
  fi
}

start_phoenix() {
  # Apply pending migrations before booting. In dev the Ecto.Migrator child is
  # started with skip: true (migrations only auto-run in releases), so Phoenix's
  # pending-migration guard would otherwise halt startup.
  echo "==> Applying database migrations (mix ecto.migrate)"
  if ! mix ecto.migrate; then
    echo "error: mix ecto.migrate failed — fix the migration before starting" >&2
    exit 1
  fi

  echo "==> Starting Phoenix on :$DEV_PORT (logs: $PHX_LOG)"
  mkdir -p "$LOG_DIR"
  mix phx.server >"$PHX_LOG" 2>&1 &
  PHX_PID=$!
  watchdog "$$" "$PHX_PID" >/dev/null 2>&1 &
  WATCHDOG_PID=$!

  printf "==> Waiting for Phoenix to answer on :%s" "$DEV_PORT"
  for _ in $(seq 1 240); do
    if is_healthy; then printf " ready\n"; return 0; fi
    if ! alive "$PHX_PID"; then
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

prepare_port
if [[ "$REUSING" != 1 ]]; then
  start_phoenix
fi

echo "==> Opening desktop window (cargo tauri dev)"
cd desktop/tauri

# Dev runs against the live Phoenix on :4000 and does NOT use the bundled release.
# A prior `build_desktop.sh` stages the full ERTS release into resources/release/,
# which `tauri-build` then chokes on while scanning it (Permission denied). Clear
# it back to the tracked .gitkeep so dev always builds; the bundle re-stages it.
if [ -d resources/release ]; then
  find resources/release -mindepth 1 -not -name .gitkeep -delete 2>/dev/null || true
fi

# A child, not `exec` (see the header): the EXIT trap stops Phoenix when the
# window closes, and it can only do that if this shell is still here.
cargo tauri dev
