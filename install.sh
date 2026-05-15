#!/bin/bash
#
# install.sh - Install the RE Engine video/cutscene fix for CrossOver on macOS
#
# This sets up:
#   1. The MF shim DLL in the game directory
#   2. Required DLL overrides (mfplat, mfreadwrite)
#   3. Game-specific environment variables (if any)
#   4. Game-specific crash reporter disable (if needed)
#   5. A launchd agent that auto-starts the decode server when the game runs
#
# Prerequisites:
#   - CrossOver (tested with 26.x)
#   - Game installed via Steam inside a CrossOver bottle
#   - ffmpeg (brew install ffmpeg)
#   - x86_64-w64-mingw32-gcc (only if building from source)
#
# Usage: ./install.sh <game> [--bottle NAME] [--crossover PATH]
#   e.g. ./install.sh re3
#        ./install.sh re7 --bottle "My Bottle"
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

# Allow override via env or flags
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
BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
DRIVE_C="$BOTTLE_DIR/drive_c"
GAME_DIR="$DRIVE_C/Program Files (x86)/Steam/steamapps/common/$GAME_DIR_NAME"
USER_REG="$BOTTLE_DIR/user.reg"
CXBOTTLE="$BOTTLE_DIR/cxbottle.conf"

PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
FLAG_FILE="$DRIVE_C/${GAME_PREFIX}_video_fix.active"

fail() { echo "ERROR: $1" >&2; exit 1; }
ok()   { echo "  OK: $1"; }
skip() { echo "  SKIP: $1 (already set)"; }

echo "============================================"
echo " $GAME_NAME - Video Fix Installer"
echo "============================================"
echo ""
echo "Game:      $GAME_NAME ($GAME_ID)"
echo "Bottle:    $BOTTLE"
echo "CrossOver: $CX_APP"
echo ""

# ---------- Warn on untested games ----------

if [[ "$STATUS" == "untested" ]]; then
    echo "WARNING: This game has not been tested with the video fix."
    echo "It may not work correctly, or the game directory name may differ."
    echo ""
    read -rp "Proceed? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# ---------- Preflight ----------

echo "Checking prerequisites..."

[[ -d "$CX_ROOT" ]]    || fail "CrossOver not found at $CX_APP"
[[ -d "$BOTTLE_DIR" ]] || fail "Bottle '$BOTTLE' not found at $BOTTLE_DIR"

if [[ ! -f "$GAME_DIR/$GAME_EXE" ]]; then
    fail "$GAME_NAME not installed. Expected $GAME_EXE in:\n  $GAME_DIR\n\nInstall via Steam in the '$BOTTLE' bottle first."
fi

FFMPEG="$(command -v ffmpeg 2>/dev/null || echo "")"
if [[ -z "$FFMPEG" ]]; then
    for p in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
        [[ -x "$p" ]] && FFMPEG="$p" && break
    done
fi
[[ -n "$FFMPEG" ]] || fail "ffmpeg not found. Install via: brew install ffmpeg"
ok "ffmpeg found at $FFMPEG"

ok "$GAME_NAME found at $GAME_DIR"

# ---------- Step 1: Install shim DLL ----------

echo ""
echo "Step 1: Installing MF shim DLL..."

SHIM_DLL="$SCRIPT_DIR/shim/out/${GAME}/mfreadwrite.dll"
if [[ ! -f "$SHIM_DLL" ]]; then
    fail "Pre-built DLL not found at $SHIM_DLL.\nBuild it first: ./build.sh $GAME"
fi

if [[ -f "$GAME_DIR/mfreadwrite.dll" ]]; then
    existing_size=$(/usr/bin/stat -f%z "$GAME_DIR/mfreadwrite.dll")
    shim_size=$(/usr/bin/stat -f%z "$SHIM_DLL")
    if [[ "$existing_size" != "$shim_size" ]]; then
        cp "$GAME_DIR/mfreadwrite.dll" "$GAME_DIR/mfreadwrite.dll.original"
        ok "Backed up existing mfreadwrite.dll"
    fi
fi

cp "$SHIM_DLL" "$GAME_DIR/mfreadwrite.dll"
ok "Installed mfreadwrite.dll to game directory"

# ---------- Step 2: DLL overrides in user.reg ----------

echo ""
echo "Step 2: Setting DLL overrides..."

[[ -f "$USER_REG" ]] || fail "user.reg not found in bottle"

add_dll_override() {
    local dll="$1"
    local mode="$2"

    if grep -q "\"${dll}\"=\"${mode}\"" "$USER_REG" 2>/dev/null; then
        skip "$dll = $mode"
        return
    fi

    if grep -q "\"${dll}\"=" "$USER_REG" 2>/dev/null; then
        sed -i '' "s/\"${dll}\"=.*/\"${dll}\"=\"${mode}\"/" "$USER_REG"
        ok "$dll override updated to $mode"
        return
    fi

    if grep -q '^\[Software\\\\Wine\\\\DllOverrides\]' "$USER_REG" 2>/dev/null; then
        sed -i '' "/^\[Software\\\\\\\\Wine\\\\\\\\DllOverrides\]/a\\
\"${dll}\"=\"${mode}\"" "$USER_REG"
        ok "$dll override added ($mode)"
    else
        echo '' >> "$USER_REG"
        echo '[Software\\Wine\\DllOverrides]' >> "$USER_REG"
        echo "\"${dll}\"=\"${mode}\"" >> "$USER_REG"
        ok "$dll override section created with $dll=$mode"
    fi
}

add_dll_override "mfplat" "native,builtin"
add_dll_override "mfreadwrite" "native,builtin"

# ---------- Step 3: Environment variables (game-specific) ----------

STEP=3

if [[ ${#BOTTLE_ENV_VARS[@]} -gt 0 ]]; then
    echo ""
    echo "Step $STEP: Setting environment variables..."

    [[ -f "$CXBOTTLE" ]] || fail "cxbottle.conf not found in bottle"

    set_bottle_env() {
        local key="$1"
        local value="$2"

        if grep -q "^\"${key}\" = " "$CXBOTTLE" 2>/dev/null; then
            local current
            current=$(grep "^\"${key}\" = " "$CXBOTTLE" | head -1 | sed "s/^\"${key}\" = \"//;s/\"$//")
            if [[ "$current" = "$value" ]]; then
                skip "$key=$value"
                return
            fi
            sed -i '' "s/^\"${key}\" = .*/\"${key}\" = \"${value}\"/" "$CXBOTTLE"
            ok "$key updated to $value"
        else
            if grep -q '^\[EnvironmentVariables\]' "$CXBOTTLE" 2>/dev/null; then
                sed -i '' "/^\[EnvironmentVariables\]/a\\
\"${key}\" = \"${value}\"" "$CXBOTTLE"
                ok "$key=$value added"
            else
                echo "" >> "$CXBOTTLE"
                echo "[EnvironmentVariables]" >> "$CXBOTTLE"
                echo "\"${key}\" = \"${value}\"" >> "$CXBOTTLE"
                ok "Created [EnvironmentVariables] with $key=$value"
            fi
        fi
    }

    for entry in "${BOTTLE_ENV_VARS[@]}"; do
        key="${entry%%:*}"
        value="${entry#*:}"
        set_bottle_env "$key" "$value"
    done

    STEP=$((STEP + 1))
fi

# ---------- Step N: Disable crash reporter (game-specific) ----------

if [[ "$DISABLE_CRASH_REPORTER" == "true" ]]; then
    echo ""
    echo "Step $STEP: Disabling crash reporter..."

    if [[ -f "$GAME_DIR/CrashReport.exe" ]]; then
        mv "$GAME_DIR/CrashReport.exe" "$GAME_DIR/CrashReport.exe.bak"
        ok "Renamed CrashReport.exe -> CrashReport.exe.bak"
    elif [[ -f "$GAME_DIR/CrashReport.exe.bak" ]]; then
        skip "CrashReport.exe already renamed"
    else
        skip "CrashReport.exe not found"
    fi

    STEP=$((STEP + 1))
fi

# ---------- Step N: Install launchd agent ----------

echo ""
echo "Step $STEP: Installing launchd agent (auto-starts decode server)..."

# Unload existing agent if present
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    ok "Unloaded previous agent"
fi

# Remove stale flag file
rm -f "$FLAG_FILE"

DECODE_SERVER="$SCRIPT_DIR/scripts/decode_server.sh"
LOG_DIR="$HOME/Library/Logs"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DECODE_SERVER}</string>
        <string>--prefix</string>
        <string>${GAME_PREFIX}</string>
        <string>--drive-c</string>
        <string>${DRIVE_C}</string>
        <string>--ffmpeg</string>
        <string>${FFMPEG}</string>
    </array>

    <key>KeepAlive</key>
    <dict>
        <key>PathState</key>
        <dict>
            <key>${FLAG_FILE}</key>
            <true/>
        </dict>
    </dict>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/${GAME_ID}-decode-server.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/${GAME_ID}-decode-server.log</string>

    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
</dict>
</plist>
PLIST

ok "Created $PLIST_PATH"

launchctl load "$PLIST_PATH"
ok "Loaded launchd agent"

echo ""
echo "============================================"
echo " Installation complete!"
echo "============================================"
echo ""
echo "How it works:"
echo "  - Just launch $GAME_NAME from Steam normally"
echo "  - The decode server starts automatically when the game runs"
echo "  - It stops automatically when the game exits"
echo ""
echo "Logs: $LOG_DIR/${GAME_ID}-decode-server.log"
echo ""
echo "To uninstall: ./uninstall.sh $GAME"
echo "Manual launch (if needed): ./play.sh $GAME"
echo ""
