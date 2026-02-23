# Spicetify Downloader

Download music from Spotify for offline listening — directly inside the Spotify app.

## What you need

| Requirement | Download link                              |
| ----------- | ------------------------------------------ |
| Python 3.8+ | https://www.python.org/downloads/          |
| Spicetify   | https://spicetify.app/docs/getting-started |

> When installing Python, tick **"Add Python to PATH"**.

---

## Installation (one step)

### Windows

Double-click **`install.bat`**.

The installer will:

- Check that Python is installed
- Install SpotDL automatically
- Set up the Spicetify extension
- Configure the server to **start automatically** with Windows — you never need to start it manually

### Linux / macOS

```bash
chmod +x install.sh
./install.sh
```

Same automatic setup as above, including auto-start on login.

---

## Using the downloader

1. Open any **playlist** or **album** in Spotify.
2. Click the **⬇ Download** button near the play controls.
3. Choose quality (320 kbps recommended).

That's it. Progress is visible in **Spicetify Downloader** in your sidebar.

---

## Listening to downloaded music in Spotify

1. Go to **Settings → Local Files** in Spotify.
2. Click **Add a source** and pick your download folder:
   - **Windows:** `C:\Users\YourName\Music\Spotify Downloads`
   - **Linux/macOS:** `~/Music/Spotify Downloads`
3. Enable **Show Local Files** in the sidebar.

---

## Troubleshooting

### "Server offline" shown in the sidebar

The background server is not running.
Re-run `install.bat` (Windows) or `install.sh` (Linux/macOS) — it will repair the auto-start setup and launch the server immediately.

### Download fails

Open Spotify Downloader in the sidebar to see the error message. Most common fixes:

- Check your internet connection.
- Re-run the installer to repair SpotDL.

### Music not appearing in Spotify after download

Go to **Settings → Local Files** and make sure your download folder is added as a source (see above).

### Linux/macOS: permission denied

```bash
chmod +x install.sh
```

---

## Uninstall

```bash
spicetify config custom_apps spicetify-downloader-
spicetify apply
```

Then delete the folder:

- **Windows:** `%appdata%\spicetify\CustomApps\spicetify-downloader`
- **Linux/macOS:** `~/.config/spicetify/CustomApps/spicetify-downloader`

---

## License

MIT
