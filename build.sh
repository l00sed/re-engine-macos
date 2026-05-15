#!/bin/bash
#
# build.sh - Build the MF shim DLL for a specific RE Engine game
#
# Compiles shim/mfreadwrite_shim.c with -DGAME_PREFIX="<prefix>" and outputs
# the DLL to shim/out/<game>/mfreadwrite.dll.
#
# Prerequisites:
#   - x86_64-w64-mingw32-gcc (brew install mingw-w64)
#
# Usage: ./build.sh <game>
#   e.g. ./build.sh re3
#        ./build.sh re7
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <game>"
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

GAME="$1"
CONF="$SCRIPT_DIR/games/${GAME}.conf"

if [[ ! -f "$CONF" ]]; then
    echo "ERROR: No config found for '$GAME' (expected $CONF)" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONF"

# Check for compiler
CC="x86_64-w64-mingw32-gcc"
if ! command -v "$CC" &>/dev/null; then
    echo "ERROR: $CC not found. Install via: brew install mingw-w64" >&2
    exit 1
fi

SRC="$SCRIPT_DIR/shim/mfreadwrite_shim.c"
DEF="$SCRIPT_DIR/shim/mfreadwrite.def"
OUT_DIR="$SCRIPT_DIR/shim/out/${GAME}"
OUT_DLL="$OUT_DIR/mfreadwrite.dll"

mkdir -p "$OUT_DIR"

echo "Building MF shim DLL for $GAME_NAME ($GAME)..."
echo "  GAME_PREFIX=$GAME_PREFIX"
echo "  Output: $OUT_DLL"

"$CC" -shared \
    -DGAME_PREFIX=\""$GAME_PREFIX"\" \
    -o "$OUT_DLL" \
    "$SRC" "$DEF" \
    -Wl,--enable-stdcall-fixup \
    -lole32

echo "  Done: $(ls -lh "$OUT_DLL" | awk '{print $5}') $OUT_DLL"
