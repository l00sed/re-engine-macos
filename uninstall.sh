#!/bin/bash
#
# uninstall.sh - Remove the RE Engine video fix
#
# Removes the launchd agent, shim DLL, and cleans up temp files.
# DLL overrides and environment variables are left in the bottle
# configuration (remove manually via CrossOver if needed).
#
# Usage: ./uninstall.sh <game> [--bottle NAME]
#   e.g. ./uninstall.sh re3
#        ./uninstall.sh re7 --bottle "My Bottle"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <game> [--bottle NAME]"
    echo ""
    echo "Available games:"
    for conf in "$SCRIPT_DIR"/games/*.conf; do
        name=$(basename "$conf" .conf)
        # shellcheck disable=SC1090
        source "$conf"
        printf "  %-6s  %s\n" "$name" "$GAME_NAME"
    done
    exit 1
fi

GAME="$1"; shift
CONF="$SCRIPT_DIR/games/${GAME}.conf"

if [[ ! -f "$CONF" ]]; then
    echo "ERROR: No config found for '$GAME' (expected $CONF)" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONF"

BOTTLE="${BOTTLE:-Steam}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bottle) BOTTLE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
DRIVE_C="$BOTTLE_DIR/drive_c"
GAME_DIR="$DRIVE_C/Program Files (x86)/Steam/steamapps/common/$GAME_DIR_NAME"

PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

echo "Uninstalling $GAME_NAME video fix..."

# ---------- Remove launchd agent ----------

if [[ -f "$PLIST_PATH" ]]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "  Removed launchd agent"
else
    echo "  No launchd agent found"
fi

# ---------- Remove flag file ----------

rm -f "$DRIVE_C/${GAME_PREFIX}_video_fix.active"

# ---------- Remove shim DLL ----------

if [[ -f "$GAME_DIR/mfreadwrite.dll.original" ]]; then
    mv "$GAME_DIR/mfreadwrite.dll.original" "$GAME_DIR/mfreadwrite.dll"
    echo "  Restored original mfreadwrite.dll"
elif [[ -f "$GAME_DIR/mfreadwrite.dll" ]]; then
    rm -f "$GAME_DIR/mfreadwrite.dll"
    echo "  Removed shim mfreadwrite.dll"
fi

# ---------- Restore crash reporter (if applicable) ----------

if [[ "$DISABLE_CRASH_REPORTER" == "true" ]]; then
    if [[ -f "$GAME_DIR/CrashReport.exe.bak" ]]; then
        mv "$GAME_DIR/CrashReport.exe.bak" "$GAME_DIR/CrashReport.exe"
        echo "  Restored CrashReport.exe"
    fi
fi

# ---------- Clean up temp files ----------

rm -f "$DRIVE_C"/${GAME_PREFIX}_movie_*.bin
rm -f "$DRIVE_C"/${GAME_PREFIX}_video_*.nv12
rm -f "$DRIVE_C"/${GAME_PREFIX}_video_*.info
rm -f "$DRIVE_C"/mf_shim_${GAME_PREFIX}_debug.log
rm -f "$DRIVE_C"/.${GAME_PREFIX}_decoded_movie_*

echo ""
echo "Uninstall complete."
echo ""
echo "NOTE: DLL overrides (mfplat, mfreadwrite) were left in the bottle"
echo "configuration. Remove them manually via CrossOver's Wine Configuration"
echo "if needed."
if [[ ${#BOTTLE_ENV_VARS[@]} -gt 0 ]]; then
    echo ""
    echo "Environment variables were also left in the bottle:"
    for entry in "${BOTTLE_ENV_VARS[@]}"; do
        key="${entry%%:*}"
        echo "  - $key"
    done
    echo "Remove them manually from cxbottle.conf if needed."
fi
