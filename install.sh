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
    SPICETIFY_PATH="$HOME/.config/spicetify"
    AUTOSTART_DIR="$HOME/Library/LaunchAgents"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="Linux"
    SPICETIFY_PATH="$HOME/.config/spicetify"
    AUTOSTART_DIR="$HOME/.config/autostart"
else
    echo " [!] Unsupported OS: $OSTYPE"
    exit 1
fi

echo " Detected: $OS"
echo ""

# ── 2. Check Python ───────────────────────────────────────────────────────────
echo " [1/5] Checking Python..."
if ! command -v python3 &>/dev/null; then
    echo ""
    echo " [!] Python 3 not found!"
    if [[ "$OS" == "macOS" ]]; then
        echo "     Install via Homebrew:  brew install python"
    else
        echo "     Install via apt:       sudo apt install python3 python3-pip"
    fi
    echo ""
    exit 1
fi
PYVER=$(python3 --version 2>&1 | awk '{print $2}')
echo "     Python $PYVER found. OK"

# ── 3. Install SpotDL ─────────────────────────────────────────────────────────
echo ""
echo " [2/5] Installing SpotDL (music downloader)..."
python3 -m pip install --quiet --upgrade spotdl
echo "     SpotDL installed. OK"

# ── 4. Copy files ─────────────────────────────────────────────────────────────
echo ""
echo " [3/5] Copying files..."
CUSTOM_APP_PATH="$SPICETIFY_PATH/CustomApps/spicetify-downloader"
mkdir -p "$CUSTOM_APP_PATH"
cp -r custom-app/* "$CUSTOM_APP_PATH/"
cp backend/server.py "$SPICETIFY_PATH/"
cp backend/requirements.txt "$SPICETIFY_PATH/"
echo "     Done. OK"

# ── 5. Configure Spicetify ────────────────────────────────────────────────────
echo ""
echo " [4/5] Configuring Spicetify..."
if ! command -v spicetify &>/dev/null; then
    echo " [!] Spicetify not found. Install it first: https://spicetify.app/docs/getting-started"
    exit 1
fi
spicetify config custom_apps spicetify-downloader >/dev/null
spicetify apply >/dev/null
echo "     Spicetify configured. OK"

# ── 6. Set up auto-start ──────────────────────────────────────────────────────
echo ""
echo " [5/5] Setting up auto-start..."

if [[ "$OS" == "macOS" ]]; then
    # LaunchAgent plist
    mkdir -p "$AUTOSTART_DIR"
    PLIST="$AUTOSTART_DIR/com.spicetify-downloader.server.plist"
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
        <string>$(which python3)</string>
        <string>$SPICETIFY_PATH/server.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
    launchctl load "$PLIST" 2>/dev/null || true

elif [[ "$OS" == "Linux" ]]; then
    # XDG autostart .desktop file
    mkdir -p "$AUTOSTART_DIR"
    cat > "$AUTOSTART_DIR/spicetify-downloader.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Spicetify Downloader Server
Exec=$(which python3) $SPICETIFY_PATH/server.py
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
fi

echo "     Auto-start configured. OK"

# ── Start server now ──────────────────────────────────────────────────────────
echo ""
echo " Starting server in the background..."
nohup python3 "$SPICETIFY_PATH/server.py" >/dev/null 2>&1 &

echo ""
echo " ========================================="
echo "   Installation Complete!"
echo " ========================================="
echo ""
echo " The server will start automatically with your system."
echo " Open Spotify — you will see 'Spicetify Downloader' in the sidebar."
echo ""
