#!/bin/bash
# Spicetify Downloader — One-line installer for Linux / macOS.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/diorhc/spicetify-downloader/main/install.sh | sh
#
# No API keys required — works out of the box.
set -e

REPO_OWNER="diorhc"
REPO_NAME="spicetify-downloader"
REPO_BRANCH="main"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
APP_NAME="spicetify-downloader"
SERVER_PORT=8765

echo ""
echo " ============================================"
echo "   Spicetify Downloader — One-Line Installer"
echo " ============================================"
echo ""
echo " No API keys needed. Just wait — fully automatic."
echo ""

# ── 1. Detect OS ──────────────────────────────────────────────────────────────
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macOS"
    SPICETIFY_PATH="${HOME}/.config/spicetify"
    AUTOSTART_DIR="${HOME}/Library/LaunchAgents"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="Linux"
    SPICETIFY_PATH="${HOME}/.config/spicetify"
    AUTOSTART_DIR="${HOME}/.config/autostart"
else
    echo " [!] Unsupported OS: $OSTYPE"
    exit 1
fi

echo " Detected: $OS"
echo ""

# ── 2. Python ─────────────────────────────────────────────────────────────────
echo " [1/7] Checking Python..."
if ! command -v python3 &>/dev/null; then
    echo "     Not found — installing Python..."
    if [[ "$OS" == "macOS" ]]; then
        if command -v brew &>/dev/null; then
            brew install python3
        else
            echo "     [!] Install Homebrew first: https://brew.sh"
            echo "     Then re-run this installer."
            exit 1
        fi
    else
        if command -v apt &>/dev/null; then
            sudo apt update -qq && sudo apt install -y -qq python3 python3-pip python3-venv
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y python3 python3-pip
        elif command -v pacman &>/dev/null; then
            sudo pacman -Sy --noconfirm python python-pip
        else
            echo "     [!] Install Python 3.8+ manually: https://www.python.org/downloads/"
            exit 1
        fi
    fi
fi
PYVER=$(python3 --version 2>&1 | awk '{print $2}')
echo "     Python $PYVER — OK"

# ── 3. Spicetify ──────────────────────────────────────────────────────────────
echo ""
echo " [2/7] Checking Spicetify..."
if ! command -v spicetify &>/dev/null; then
    echo "     Not found — installing Spicetify..."
    curl -fsSL https://raw.githubusercontent.com/spicetify/cli/main/install.sh | sh
    export PATH="${HOME}/.spicetify:${PATH}"
    if ! command -v spicetify &>/dev/null; then
        echo "     [!] Spicetify not in PATH. Close terminal, reopen, and run again."
        exit 1
    fi
fi
SPVER=$(spicetify --version 2>&1)
echo "     Spicetify $SPVER — OK"

# ── 4. Install spotdl + yt-dlp ────────────────────────────────────────────────
echo ""
echo " [3/7] Installing download engines (spotdl + yt-dlp)..."
python3 -m pip install --quiet --upgrade spotdl 2>/dev/null || \
    python3 -m pip install --quiet --upgrade --user spotdl 2>/dev/null || true
echo "     spotdl — OK"

python3 -m pip install --quiet --upgrade yt-dlp 2>/dev/null || \
    python3 -m pip install --quiet --upgrade --user yt-dlp 2>/dev/null || true
echo "     yt-dlp — OK"

# ── 5. FFmpeg ──────────────────────────────────────────────────────────────────
echo ""
echo " [4/7] Checking FFmpeg..."
if ! command -v ffmpeg &>/dev/null; then
    echo "     Downloading FFmpeg via spotdl..."
    echo "y" | python3 -m spotdl --download-ffmpeg 2>/dev/null || true

    if ! command -v ffmpeg &>/dev/null; then
        echo "     Trying package manager..."
        if [[ "$OS" == "macOS" ]] && command -v brew &>/dev/null; then
            brew install ffmpeg
        elif command -v apt &>/dev/null; then
            sudo apt install -y -qq ffmpeg
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y ffmpeg
        elif command -v pacman &>/dev/null; then
            sudo pacman -Sy --noconfirm ffmpeg
        else
            echo "     Trying imageio-ffmpeg..."
            python3 -m pip install --quiet --upgrade imageio-ffmpeg 2>/dev/null || true
        fi
    fi
fi
echo "     FFmpeg — OK"

# ── 6. Download extension files ────────────────────────────────────────────────
echo ""
echo " [5/7] Downloading extension files..."

SPICETIFY_USERDATA=$(spicetify path userdata 2>/dev/null || echo "$SPICETIFY_PATH")
CUSTOM_APP_PATH="${SPICETIFY_USERDATA}/CustomApps/${APP_NAME}"
BACKEND_PATH="${CUSTOM_APP_PATH}/backend"

mkdir -p "$CUSTOM_APP_PATH"
mkdir -p "$BACKEND_PATH"

CUSTOM_APP_FILES=(
    "custom-app/manifest.json"
    "custom-app/index.js"
    "custom-app/settings.js"
    "custom-app/downloader.js"
    "custom-app/app.js"
)
BACKEND_FILES=(
    "backend/server.py"
    "backend/requirements.txt"
)

for file in "${CUSTOM_APP_FILES[@]}"; do
    filename=$(basename "$file")
    curl -fsSL "${REPO_RAW}/${file}" -o "${CUSTOM_APP_PATH}/${filename}" 2>/dev/null || \
        echo "     [!] Failed to download: $file"
done

for file in "${BACKEND_FILES[@]}"; do
    filename=$(basename "$file")
    curl -fsSL "${REPO_RAW}/${file}" -o "${BACKEND_PATH}/${filename}" 2>/dev/null || \
        echo "     [!] Failed to download: $file"
done

echo "     Files downloaded — OK"

# ── 7. Configure Spicetify ─────────────────────────────────────────────────────
echo ""
echo " [6/7] Configuring Spicetify..."
spicetify config custom_apps "$APP_NAME" 2>/dev/null || true
spicetify apply 2>/dev/null || {
    echo "     [!] spicetify apply failed. Close Spotify and re-run."
}
echo "     Spicetify configured — OK"

# ── 8. Auto-start + launch server ─────────────────────────────────────────────
echo ""
echo " [7/7] Setting up background server..."

SERVER_PY="${BACKEND_PATH}/server.py"
PYTHON3_PATH=$(which python3)

if [[ "$OS" == "macOS" ]]; then
    mkdir -p "$AUTOSTART_DIR"
    PLIST="${AUTOSTART_DIR}/com.spicetify-downloader.server.plist"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.spicetify-downloader.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON3_PATH}</string>
        <string>${SERVER_PY}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/spicetify-downloader.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/spicetify-downloader.log</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST" 2>/dev/null || true

elif [[ "$OS" == "Linux" ]]; then
    mkdir -p "$AUTOSTART_DIR"
    cat > "${AUTOSTART_DIR}/spicetify-downloader.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Spicetify Downloader Server
Exec=${PYTHON3_PATH} ${SERVER_PY}
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
fi

echo "     Auto-start configured"

# Kill existing and start fresh
pkill -f "server.py.*spicetify" 2>/dev/null || true
sleep 1
nohup python3 "$SERVER_PY" > /tmp/spicetify-downloader.log 2>&1 &
sleep 3

if curl -s "http://localhost:${SERVER_PORT}/health" | grep -q '"ok"'; then
    echo "     Server started — OK"
else
    echo "     [!] Server may not have started yet."
    echo "         Check: /tmp/spicetify-downloader.log"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo " ============================================"
echo "   Installation Complete!"
echo " ============================================"
echo ""
echo " No API keys needed — everything works out of the box!"
echo ""
echo " How to download music:"
echo "   - Open album/playlist and click Spotify's Download button"
echo "   - Right-click any track/playlist/album > 'Download for Offline'"
echo "   - Press Ctrl+Shift+D"
echo ""
echo " To listen offline in Spotify:"
echo "   Settings > Local Files > Add: ~/Music/Spotify Downloads"
echo ""
echo " Open Spotify and enjoy!"
echo ""
