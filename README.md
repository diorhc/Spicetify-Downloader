# Spicetify Downloader

Download music from Spotify for offline listening — directly inside the Spotify app.  
One click to install, one click to download.

## Installation

### Windows (one click)

1. Download this repository (click **Code → Download ZIP** on GitHub, extract it)
2. Double-click **`install.bat`**
3. Open Spotify — done!

The installer automatically sets up everything:

- Python (if missing)
- Spicetify (if missing)
- SpotDL (music download engine)
- FFmpeg (audio converter)
- Background server (auto-starts with Windows)

### Linux / macOS

```bash
chmod +x install.sh
./install.sh
```

The installer will attempt to install any missing dependencies via your system package manager.

---

## How to download music

There are **4 ways** to start a download:

| Method             | How                                                                                |
| ------------------ | ---------------------------------------------------------------------------------- |
| **Right-click**    | Right-click any playlist, album, or track → **Download with SpotDL**               |
| **Keyboard**       | Press **Ctrl+Shift+D**                                                             |
| **Top bar button** | Click the ⬇ button in the Spotify top bar                                          |
| **Sidebar panel**  | Open **Spicetify Downloader** in the left sidebar → manage settings & see progress |

After clicking, choose your quality (128 / 160 / 320 kbps) and the download starts in the background.

---

## Listening to downloaded music in Spotify

1. Go to **Settings → Local Files** in Spotify.
2. Click **Add a source** and select your download folder:
   - **Windows:** `C:\Users\YourName\Music\Spotify Downloads`
   - **Linux/macOS:** `~/Music/Spotify Downloads`
3. Enable **Show Local Files** in the sidebar.

---

## Troubleshooting

### "Server offline" in the sidebar panel

Re-run `install.bat` (Windows) or `install.sh` (Linux/macOS) — this will restart the background server.

### Download fails or gets stuck

1. Open the Spicetify Downloader panel in the sidebar to see the error.
2. Most common fix: check your internet connection.
3. If SpotDL or FFmpeg shows as "Missing" in the panel, click **Install missing** or re-run the installer.

### Music not showing up in Spotify

Go to **Settings → Local Files** and add your download folder (see above).

### Linux/macOS: "Permission denied"

```bash
chmod +x install.sh
```

### The installer says "Spicetify apply failed"

Close Spotify completely (including from the system tray), then run the installer again.

---

## Uninstall

```powershell
spicetify config custom_apps spicetify-downloader-
spicetify apply
```

Then delete:

- **Windows:** `%appdata%\spicetify\CustomApps\spicetify-downloader` and remove `SpicetifyDownloaderServer.vbs` from your Startup folder
- **Linux/macOS:** `~/.config/spicetify/CustomApps/spicetify-downloader` and remove the autostart entry

---

## License

MIT
