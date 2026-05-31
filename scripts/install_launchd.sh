#!/usr/bin/env bash
#
# install_launchd.sh — install the Buster Claw KeepAlive LaunchAgent (macOS).
#
# Renders desktop/tauri/launchd/com.hightowerbuilds.busterclaw.plist (substituting
# the __APP_PATH__ placeholder), drops it in ~/Library/LaunchAgents, and loads it
# so launchd keeps the packaged `.app` running (RunAtLoad + KeepAlive) across
# crashes, force-quits, and reboots — the outermost watchdog for an unattended
# 12-hour shift.
#
# Usage:
#   scripts/install_launchd.sh
#   BUSTER_CLAW_APP="/path/to/Buster Claw.app" scripts/install_launchd.sh
#
# Uninstall (run manually):
#   launchctl unload "$HOME/Library/LaunchAgents/com.hightowerbuilds.busterclaw.plist"
#   rm "$HOME/Library/LaunchAgents/com.hightowerbuilds.busterclaw.plist"
#
set -euo pipefail

LABEL="com.hightowerbuilds.busterclaw"

# Repo-relative locations (resolve regardless of where the script is invoked from).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../desktop/tauri/launchd/${LABEL}.plist"

# App bundle to keep alive. Override with $BUSTER_CLAW_APP.
APP_PATH="${BUSTER_CLAW_APP:-/Applications/Buster Claw.app}"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DEST="$LAUNCH_AGENTS_DIR/${LABEL}.plist"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "error: plist template not found at $TEMPLATE" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "warning: app bundle not found at '$APP_PATH'" >&2
    echo "         set BUSTER_CLAW_APP to the installed .app if this is wrong." >&2
fi

mkdir -p "$LAUNCH_AGENTS_DIR"

# If a previous agent is loaded, unload it first so the reload picks up changes.
if launchctl list "$LABEL" >/dev/null 2>&1; then
    echo "unloading existing LaunchAgent $LABEL"
    launchctl unload "$DEST" 2>/dev/null || true
fi

# Render the template: substitute __APP_PATH__ with the resolved app path.
# Use a non-`/` delimiter for sed since the path contains slashes.
echo "rendering $DEST (app: $APP_PATH)"
sed "s|__APP_PATH__|${APP_PATH}|g" "$TEMPLATE" > "$DEST"

echo "loading LaunchAgent $LABEL"
launchctl load "$DEST"

echo "done. $LABEL is installed and loaded."
echo "logs: /tmp/${LABEL}.out.log  /tmp/${LABEL}.err.log"
