#!/bin/bash
set -e

echo ""
echo " ========================================="
echo "   Spicetify Downloader — Easy Installer"
echo " ========================================="
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

# ── 2. Check Python ──────────────────────────────────────────────────────────
echo " [1/6] Checking Python..."
if ! command -v python3 &>/dev/null; then
    echo ""
    echo " [!] Python 3 not found!"
    if [[ "$OS" == "macOS" ]]; then
        echo "     Attempting to install via Homebrew..."
        if command -v brew &>/dev/null; then
            brew install python3
        else
            echo "     Homebrew not found. Install Python manually:"
            echo "       brew install python   OR   https://www.python.org/downloads/"
            exit 1
        fi
    else
        echo "     Attempting to install via apt..."
        if command -v apt &>/dev/null; then
            sudo apt update -qq && sudo apt install -y -qq python3 python3-pip python3-venv
        else
            echo "     apt not found. Install Python manually:"
            echo "       sudo dnf install python3   OR   https://www.python.org/downloads/"
            exit 1
        fi
    fi
fi
PYVER=$(python3 --version 2>&1 | awk '{print $2}')
echo "     Python $PYVER — OK"

# ── 3. Check/Install Spicetify ──────────────────────────────────────────────
echo ""
echo " [2/6] Checking Spicetify..."
if ! command -v spicetify &>/dev/null; then
    echo "     Not found — installing Spicetify..."
    curl -fsSL https://raw.githubusercontent.com/spicetify/cli/main/install.sh | sh
    # Add to PATH for this session
    export PATH="${HOME}/.spicetify:${PATH}"
    if ! command -v spicetify &>/dev/null; then
        echo ""
        echo " [!] Spicetify installed but not in PATH."
        echo "     Close this terminal, reopen, and run install.sh again."
        exit 1
    fi
fi
SPVER=$(spicetify --version 2>&1)
echo "     Spicetify $SPVER — OK"

# ── 4. Install SpotDL ────────────────────────────────────────────────────────
echo ""
echo " [3/6] Installing SpotDL (music downloader)..."
python3 -m pip install --quiet --upgrade spotdl 2>/dev/null || \
    python3 -m pip install --quiet --upgrade --user spotdl
echo "     SpotDL — OK"

# ── 5. FFmpeg ─────────────────────────────────────────────────────────────────
echo ""
echo " [4/6] Checking FFmpeg..."
if ! command -v ffmpeg &>/dev/null; then
    echo "     FFmpeg not found — downloading via SpotDL..."
    python3 -m spotdl --download-ffmpeg 2>/dev/null || true
    if ! command -v ffmpeg &>/dev/null; then
        echo "     Trying package manager..."
        if [[ "$OS" == "macOS" ]] && command -v brew &>/dev/null; then
            brew install ffmpeg
        elif command -v apt &>/dev/null; then
            sudo apt install -y -qq ffmpeg
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y ffmpeg
        else
            echo "     [!] Could not install FFmpeg automatically."
            echo "         Please install it manually: https://ffmpeg.org/download.html"
        fi
    fi
fi
echo "     FFmpeg — OK"

# ── 6. Copy files ────────────────────────────────────────────────────────────
echo ""
echo " [5/6] Copying files..."

# Detect spicetify userdata path
SPICETIFY_USERDATA=$(spicetify path userdata 2>/dev/null || echo "$SPICETIFY_PATH")

CUSTOM_APP_PATH="${SPICETIFY_USERDATA}/CustomApps/spicetify-downloader"
BACKEND_PATH="${CUSTOM_APP_PATH}/backend"

mkdir -p "$CUSTOM_APP_PATH"
mkdir -p "$BACKEND_PATH"

# Copy custom-app files
cp -f custom-app/manifest.json "$CUSTOM_APP_PATH/"
cp -f custom-app/index.js      "$CUSTOM_APP_PATH/"
cp -f custom-app/settings.js   "$CUSTOM_APP_PATH/"
cp -f custom-app/downloader.js "$CUSTOM_APP_PATH/"
cp -f custom-app/app.js        "$CUSTOM_APP_PATH/" 2>/dev/null || true

# Copy backend files
cp -f backend/server.py        "$BACKEND_PATH/"
cp -f backend/requirements.txt "$BACKEND_PATH/"

echo "     Files copied — OK"

# ── 7. Configure Spicetify ───────────────────────────────────────────────────
echo ""
echo " [6/6] Configuring Spicetify..."
spicetify config custom_apps spicetify-downloader
spicetify apply
echo "     Spicetify configured — OK"

# ── 8. Set up auto-start ─────────────────────────────────────────────────────
echo ""
echo " Setting up auto-start..."

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

echo "     Auto-start configured — OK"

# ── Kill existing server and start fresh ───────────────────────────────────────
echo ""
echo " Starting server..."
pkill -f "server.py.*spicetify" 2>/dev/null || true
sleep 1
nohup python3 "$SERVER_PY" > /tmp/spicetify-downloader.log 2>&1 &
sleep 3

# Verify
if curl -s http://localhost:8765/health | grep -q '"ok"'; then
    echo "     Server started — OK"
else
    echo "     [!] Server may not have started yet. Check /tmp/spicetify-downloader.log"
fi

echo ""
echo " ========================================="
echo "   Installation Complete!"
echo " ========================================="
echo ""
echo " The server starts automatically with your system."
echo " Open Spotify — you will see 'Spicetify Downloader' in the sidebar."
echo ""
echo " How to download music:"
echo "   - Right-click any playlist/album/track > 'Download with SpotDL'"
echo "   - OR press Ctrl+Shift+D"
echo "   - OR click the download button in the top bar"
echo ""
echo " Downloaded files: ~/Music/Spotify Downloads"
echo ""
