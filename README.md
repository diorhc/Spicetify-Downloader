# Spicetify Downloader

Download music from Spotify for offline listening — directly inside the Spotify app.  
**No API keys required.** Dual engine: **spotdl** + **yt-dlp** with automatic fallback.

---

## Auto Install

### Windows (PowerShell)

```powershell
iwr -useb https://raw.githubusercontent.com/diorhc/spicetify-downloader/main/install.ps1 | iex
```

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/diorhc/spicetify-downloader/main/install.sh | sh
```

### Windows (manual — download ZIP first)

1. Download this repository (**Code → Download ZIP**, extract)
2. Double-click **`install.bat`**
3. Open Spotify — done!

---

## What gets installed

Everything is automatic — no configuration needed:

- **Python** (if missing)
- **Spicetify** (if missing)
- **spotdl** — primary download engine (matches Spotify tracks to YouTube audio)
- **yt-dlp** — fallback engine (YouTube search by track name)
- **FFmpeg** — audio conversion
- **Background server** — auto-starts with your OS

**No Spotify API keys, no developer dashboard, no environment variables.**

---

## How to download music

| Method             | How                                                                    |
| ------------------ | ---------------------------------------------------------------------- |
| **Spotify button** | Open an album/playlist and click Spotify's default **Download** button |
| **Right-click**    | Right-click any playlist, album, or track → **Download for Offline**   |
| **Keyboard**       | Press **Ctrl+Shift+D**                                                 |

After clicking, choose your quality (128 / 160 / 320 kbps) and the download starts in the background.

### Choosing the download engine

Open the **Spicetify Downloader** panel in Spotify's sidebar:

- **Auto** (recommended) — SpotDL first, then yt-dlp fallback; if yt-dlp has partial failures, SpotDL is tried again
- **SpotDL** (default) — best quality matching, uses embedded Spotify credentials
- **yt-dlp** — alternative engine, searches YouTube by track name

The system automatically falls back to the second engine if the first one fails.

---

## Listening to downloaded music in Spotify

1. Open **Settings → Local Files** in Spotify.
2. Click **Add a source** and select your download folder:
   - **Windows:** `C:\Users\YourName\Music\Spotify Downloads`
   - **Linux/macOS:** `~/Music/Spotify Downloads`
3. Enable **Show Local Files** in the sidebar.

---

## Troubleshooting

### "Server offline" in the sidebar panel

Re-run the installer (one-liner above, or `install.bat` / `install.sh`).

### Download fails or gets stuck

1. Open the Spicetify Downloader panel in the sidebar to see the error.
2. Check your internet connection.
3. If spotdl or FFmpeg shows as "Missing", click **Install missing** or re-run the installer.
4. Try switching the engine (SpotDL ↔ yt-dlp) in the sidebar panel.

### Music not showing up in Spotify

Go to **Settings → Local Files** and add your download folder (see above).

### Linux/macOS: "Permission denied"

```bash
chmod +x install.sh
```

### "Spicetify apply failed"

Close Spotify completely (including from the system tray), then run the installer again.

---

## Uninstall

```powershell
spicetify config custom_apps spicetify-downloader-
spicetify apply
```

Then delete:

- **Windows:** `%appdata%\spicetify\CustomApps\spicetify-downloader` and remove `SpicetifyDownloaderServer.cmd` from your Startup folder
- **macOS:** `~/.config/spicetify/CustomApps/spicetify-downloader` and the LaunchAgent plist
- **Linux:** `~/.config/spicetify/CustomApps/spicetify-downloader` and the `.desktop` autostart entry

---

## License

MIT
