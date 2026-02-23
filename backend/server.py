import os
import json
import threading
import platform
import logging
import subprocess
import sys
import re
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")

# ── Helpers ────────────────────────────────────────────────────────────────────

def get_default_download_path():
    home = os.path.expanduser("~")
    return os.path.join(home, "Music", "Spotify Downloads")

DEFAULT_CONFIG = {
    "download_path": get_default_download_path(),
    "quality": "320",
    "port": 8765
}

# download_id -> { url, status, progress, total, done, error }
ACTIVE_DOWNLOADS = {}
_download_counter = 0
_download_lock = threading.Lock()


def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return DEFAULT_CONFIG.copy()


def save_config(config):
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)


# ── SpotDL management ──────────────────────────────────────────────────────────

def check_spotdl_installed():
    try:
        result = subprocess.run(
            [sys.executable, "-m", "spotdl", "--version"],
            capture_output=True, text=True, timeout=5
        )
        return result.returncode == 0
    except Exception:
        return False


def auto_install_spotdl():
    """Try to install spotdl automatically. Returns True on success."""
    logger.info("SpotDL not found — installing automatically...")
    try:
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", "spotdl"],
            capture_output=True, text=True, timeout=120
        )
        if result.returncode == 0:
            logger.info("SpotDL installed successfully.")
            return True
        else:
            logger.error(f"pip install spotdl failed: {result.stderr[:300]}")
            return False
    except Exception as e:
        logger.error(f"auto-install failed: {e}")
        return False


# ── Download worker ────────────────────────────────────────────────────────────

def download_track(download_id, spotify_url, quality, download_path):
    """Run spotdl as a subprocess and track progress line-by-line."""
    logger.info(f"[{download_id}] Starting download: {spotify_url}")

    ACTIVE_DOWNLOADS[download_id]["status"] = "downloading"

    os.makedirs(download_path, exist_ok=True)

    cmd = [
        sys.executable, "-m", "spotdl",
        spotify_url,
        "--bitrate", f"{quality}k",
        "--output", download_path,
        "--log-level", "INFO",
    ]

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )

        # Pattern: "Downloaded X/Y songs"  or  "Downloading song X of Y"
        total_re  = re.compile(r'(\d+)\s+(?:songs?|tracks?)', re.IGNORECASE)
        done_re   = re.compile(r'Downloaded\s+(\d+)', re.IGNORECASE)
        skip_re   = re.compile(r'Skipping', re.IGNORECASE)

        for line in proc.stdout:
            line = line.rstrip()
            if line:
                logger.info(f"[spotdl] {line}")

            # Try to extract totals / progress from spotdl output
            m_total = total_re.search(line)
            if m_total:
                ACTIVE_DOWNLOADS[download_id]["total"] = int(m_total.group(1))

            m_done = done_re.search(line)
            if m_done:
                ACTIVE_DOWNLOADS[download_id]["done"] = int(m_done.group(1))
            elif "Downloading" in line and "of" in line:
                # "Downloading song 3 of 12 ..."
                m = re.search(r'(\d+)\s+of\s+(\d+)', line)
                if m:
                    ACTIVE_DOWNLOADS[download_id]["done"]  = int(m.group(1))
                    ACTIVE_DOWNLOADS[download_id]["total"] = int(m.group(2))

        proc.wait()

        if proc.returncode == 0:
            ACTIVE_DOWNLOADS[download_id]["status"] = "completed"
            logger.info(f"[{download_id}] Download completed.")
        else:
            ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
            ACTIVE_DOWNLOADS[download_id]["error"] = "spotdl exited with errors. Check the server log."
            logger.error(f"[{download_id}] spotdl exited with code {proc.returncode}")

    except FileNotFoundError:
        ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
        ACTIVE_DOWNLOADS[download_id]["error"] = "SpotDL not found. Restart Spotify Downloader."
        logger.error("spotdl executable not found.")
    except Exception as e:
        ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
        ACTIVE_DOWNLOADS[download_id]["error"] = str(e)
        logger.error(f"[{download_id}] Unexpected error: {e}")


# ── HTTP Handler ───────────────────────────────────────────────────────────────

class DownloadRequestHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        logger.info(f"[{self.address_string()}] {format % args}")

    # Allow the Spotify UI (different origin) to talk to our local server
    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/config":
            config = load_config()
            config["spotdl_installed"] = check_spotdl_installed()
            self._json(200, config)

        elif parsed.path == "/status":
            self._json(200, {
                "status": "ok",
                "downloads": list(ACTIVE_DOWNLOADS.keys())
            })

        elif parsed.path.startswith("/progress/"):
            dl_id = parsed.path.split("/progress/", 1)[1]
            info = ACTIVE_DOWNLOADS.get(dl_id)
            if info is None:
                self._json(404, {"error": "Unknown download id"})
            else:
                done  = info.get("done",  0)
                total = info.get("total", 0)
                pct   = round(done / total * 100) if total else 0
                self._json(200, {
                    "id":       dl_id,
                    "status":   info["status"],
                    "done":     done,
                    "total":    total,
                    "percent":  pct,
                    "error":    info.get("error", "")
                })

        elif parsed.path == "/check-spotdl":
            self._json(200, {"installed": check_spotdl_installed()})

        else:
            self._json(404, {"error": "Not found"})

    def do_POST(self):
        global _download_counter
        parsed = urlparse(self.path)
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        if parsed.path == "/download":
            try:
                data = json.loads(body.decode())
            except Exception:
                self._json(400, {"error": "Invalid JSON"}); return

            spotify_url   = data.get("url", "").strip()
            quality       = data.get("quality", "320")
            config        = load_config()
            download_path = data.get("path", config.get("download_path", DEFAULT_CONFIG["download_path"]))

            if not spotify_url:
                self._json(400, {"error": "No URL provided"}); return

            # Auto-install spotdl if missing — no manual step needed
            if not check_spotdl_installed():
                ok = auto_install_spotdl()
                if not ok:
                    self._json(503, {
                        "error": "Could not install SpotDL. Check your internet connection."
                    })
                    return

            with _download_lock:
                _download_counter += 1
                download_id = str(_download_counter)

            ACTIVE_DOWNLOADS[download_id] = {
                "url":    spotify_url,
                "status": "starting",
                "done":   0,
                "total":  0,
                "error":  ""
            }

            t = threading.Thread(
                target=download_track,
                args=(download_id, spotify_url, quality, download_path),
                daemon=True
            )
            t.start()

            self._json(200, {
                "status":      "started",
                "url":         spotify_url,
                "download_id": download_id
            })

        elif parsed.path == "/save-config":
            try:
                data = json.loads(body.decode())
            except Exception:
                self._json(400, {"error": "Invalid JSON"}); return

            config = load_config()
            if "path" in data:
                config["download_path"] = data["path"]
            if "quality" in data:
                config["quality"] = data["quality"]
            if "port" in data:
                config["port"] = data["port"]
            save_config(config)
            self._json(200, {"status": "saved"})

        else:
            self._json(404, {"error": "Not found"})


# ── Entry point ────────────────────────────────────────────────────────────────

def run_server(port=None):
    config = load_config()
    port = port or config.get("port", DEFAULT_CONFIG["port"])

    # Ensure download folder exists
    os.makedirs(config.get("download_path", DEFAULT_CONFIG["download_path"]), exist_ok=True)

    # Try to install spotdl proactively so the first download is instant
    if not check_spotdl_installed():
        auto_install_spotdl()

    httpd = HTTPServer(("", port), DownloadRequestHandler)
    logger.info(f"Spicetify Downloader server running on http://localhost:{port}")
    logger.info(f"Download folder : {config.get('download_path')}")
    logger.info(f"Default quality : {config.get('quality')} kbps")
    httpd.serve_forever()


if __name__ == "__main__":
    run_server()
