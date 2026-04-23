#!/bin/bash
#
# play.sh - Launch an RE Engine game on macOS via CrossOver
#
# This script handles everything automatically:
#   1. Starts the video decode server in the background
#   2. Launches the game through Steam/CrossOver
#   3. Cleans up when the game exits
#
# Use this for manual launches when the launchd agent isn't working,
# or if you prefer to manage the decode server yourself.
#
# Usage: ./play.sh <game> [--bottle NAME] [--crossover PATH]
#   e.g. ./play.sh re3
#        ./play.sh re8 --bottle "My Bottle"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- Parse arguments ----------

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <game> [--bottle NAME] [--crossover PATH]"
    echo ""
    echo "Available games:"
    for conf in "$SCRIPT_DIR"/games/*.conf; do
        name=$(basename "$conf" .conf)
        # shellcheck disable=SC1090
        source "$conf"
        printf "  %-6s  %s (%s)\n" "$name" "$GAME_NAME" "$STATUS"
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
CX_APP="${CX_APP:-$HOME/Applications/CrossOver.app}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bottle)    BOTTLE="$2"; shift 2 ;;
        --crossover) CX_APP="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

CX_ROOT="$CX_APP/Contents/SharedSupport/CrossOver"
FFMPEG="$(command -v ffmpeg 2>/dev/null || echo /opt/homebrew/bin/ffmpeg)"
DRIVE_C="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE/drive_c"
GAME_DIR="$DRIVE_C/Program Files (x86)/Steam/steamapps/common/$GAME_DIR_NAME"

# ---------- Preflight checks ----------

fail() { echo "ERROR: $1" >&2; exit 1; }

[[ -d "$CX_ROOT" ]]              || fail "CrossOver not found at $CX_APP"
[[ -x "$CX_ROOT/bin/cxstart" ]]  || fail "cxstart not found in CrossOver"
[[ -d "$DRIVE_C" ]]              || fail "Bottle '$BOTTLE' not found"
[[ -f "$GAME_DIR/$GAME_EXE" ]]   || fail "$GAME_NAME not installed in bottle '$BOTTLE'"
[[ -f "$GAME_DIR/mfreadwrite.dll" ]] || fail "MF shim DLL not installed. Run ./install.sh $GAME first."
[[ -x "$FFMPEG" ]]               || fail "ffmpeg not found. Install via: brew install ffmpeg"

# ---------- Cleanup handler ----------

DECODE_PID=""
cleanup() {
    echo ""
    echo "Shutting down..."

    # Kill decode server and any ffmpeg children
    if [[ -n "$DECODE_PID" ]]; then
        kill "$DECODE_PID" 2>/dev/null || true
        # Kill child ffmpeg processes
        pkill -P "$DECODE_PID" 2>/dev/null || true
    fi

    # Clean up temporary video files
    rm -f "$DRIVE_C"/${GAME_PREFIX}_movie_*.bin
    rm -f "$DRIVE_C"/${GAME_PREFIX}_video_*.nv12
    rm -f "$DRIVE_C"/${GAME_PREFIX}_video_*.info

    echo "Done."
}
trap cleanup EXIT INT TERM

# ---------- Clean previous run artifacts ----------

rm -f "$DRIVE_C"/${GAME_PREFIX}_movie_*.bin
rm -f "$DRIVE_C"/${GAME_PREFIX}_video_*.nv12
rm -f "$DRIVE_C"/${GAME_PREFIX}_video_*.info

# ---------- Start decode server ----------

echo "Starting video decode server for $GAME_NAME..."
bash "$SCRIPT_DIR/scripts/decode_server.sh" \
    --prefix "$GAME_PREFIX" \
    --drive-c "$DRIVE_C" \
    --ffmpeg "$FFMPEG" &
DECODE_PID=$!
sleep 0.5

if ! kill -0 "$DECODE_PID" 2>/dev/null; then
    fail "Decode server failed to start"
fi
echo "Decode server running (PID $DECODE_PID)"

# ---------- Launch game ----------

echo "Launching $GAME_NAME..."
"$CX_ROOT/bin/cxstart" --bottle "$BOTTLE" --no-convert -- \
    "C:\\Program Files (x86)\\Steam\\steam.exe" -applaunch "$STEAM_APP_ID"

# cxstart returns after the game process exits — cleanup runs via trap
echo "Game exited."
