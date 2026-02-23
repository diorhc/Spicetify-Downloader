# Spicetify Downloader

Download music from Spotify for offline listening - directly inside the Spotify app.

## Installation

### Windows - one click

1. Download this repository (click **Code -> Download ZIP** on GitHub, extract it)
2. Double-click **`install.bat`**
3. Open Spotify - done

The installer automatically installs everything that is missing (Python, Spicetify, SpotDL). No manual setup needed.

### Linux / macOS

```bash
chmod +x install.sh
./install.sh
```

---

## How to download music

1. Open any **playlist** or **album** in Spotify.
2. Click the **Download** button near the play controls.
3. Choose quality (320 kbps recommended).

Progress is visible in the **Spicetify Downloader** panel in your sidebar.

---

## Listening to downloaded music in Spotify

1. Go to **Settings -> Local Files** in Spotify.
2. Click **Add a source** and select your download folder:
   - **Windows:** `C:\Users\YourName\Music\Spotify Downloads`
   - **Linux/macOS:** `~/Music/Spotify Downloads`
3. Enable **Show Local Files** in the sidebar.

---

## Troubleshooting

### "Server offline" in the sidebar
Re-run `install.bat` - it will repair and restart the server.

### Download fails
Open the Spicetify Downloader panel in the sidebar to see the error message.
Most common fix: check your internet connection and re-run `install.bat`.

### Music not showing up in Spotify after download
Go to **Settings -> Local Files** and add your download folder (see above).

### Linux/macOS: "Permission denied"
```bash
chmod +x install.sh
```

---

## Uninstall

```powershell
spicetify config custom_apps spicetify-downloader-
spicetify apply
```

Then delete `%appdata%\spicetify\CustomApps\spicetify-downloader` (Windows)
or `~/.config/spicetify/CustomApps/spicetify-downloader` (Linux/macOS).

---

## License

MIT