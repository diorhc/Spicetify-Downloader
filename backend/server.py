import os
import json
import threading
import time
import logging
import subprocess
import sys
import re
import shutil
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# ── Logging ────────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# ── Config ─────────────────────────────────────────────────────────────────────

CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")


def get_default_download_path():
    home = os.path.expanduser("~")
    return os.path.join(home, "Music", "Spotify Downloads")


DEFAULT_CONFIG = {
    "download_path": get_default_download_path(),
    "quality": "320",
    "port": 8765
}


def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return DEFAULT_CONFIG.copy()


def save_config(config):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)


# ── Active downloads ───────────────────────────────────────────────────────────

# download_id -> { url, status, done, total, error, started_at }
ACTIVE_DOWNLOADS = {}
_download_counter = 0
_download_lock = threading.Lock()

_CLEANUP_AGE = 1800  # 30 min


def cleanup_old_downloads():
    """Remove finished downloads older than _CLEANUP_AGE."""
    now = time.time()
    to_remove = []
    with _download_lock:
        for dl_id, info in ACTIVE_DOWNLOADS.items():
            if info["status"] in ("completed", "failed"):
                if now - info.get("started_at", now) > _CLEANUP_AGE:
                    to_remove.append(dl_id)
        for dl_id in to_remove:
            del ACTIVE_DOWNLOADS[dl_id]
    if to_remove:
        logger.info(f"Cleaned up {len(to_remove)} old download(s).")


def _cleanup_loop():
    while True:
        time.sleep(300)
        try:
            cleanup_old_downloads()
        except Exception:
            pass


# ── Dependency checks (cached) ─────────────────────────────────────────────────

_spotdl_cache = {"installed": None, "checked_at": 0.0}
_ffmpeg_cache = {"installed": None, "checked_at": 0.0}
_spotdl_caps_cache = {"caps": None, "checked_at": 0.0}
_CACHE_TTL = 120  # seconds


def check_spotdl_installed():
    now = time.time()
    if _spotdl_cache["installed"] is not None and (now - _spotdl_cache["checked_at"]) < _CACHE_TTL:
        return _spotdl_cache["installed"]
    try:
        result = subprocess.run(
            [sys.executable, "-m", "spotdl", "--version"],
            capture_output=True, text=True, timeout=10
        )
        installed = result.returncode == 0
    except Exception:
        installed = False
    _spotdl_cache["installed"] = installed
    _spotdl_cache["checked_at"] = now
    return installed


def check_ffmpeg_installed():
    now = time.time()
    if _ffmpeg_cache["installed"] is not None and (now - _ffmpeg_cache["checked_at"]) < _CACHE_TTL:
        return _ffmpeg_cache["installed"]
    installed = get_ffmpeg_path() is not None
    _ffmpeg_cache["installed"] = installed
    _ffmpeg_cache["checked_at"] = now
    return installed


def get_ffmpeg_path():
    """Return path to ffmpeg binary if available (system or managed)."""
    # 1) system ffmpeg
    system_ffmpeg = shutil.which("ffmpeg")
    if system_ffmpeg:
        return system_ffmpeg

    # 2) managed ffmpeg from imageio-ffmpeg package
    try:
        import imageio_ffmpeg  # type: ignore
        managed = imageio_ffmpeg.get_ffmpeg_exe()
        if managed and os.path.exists(managed):
            return managed
    except Exception:
        pass

    return None


def auto_install_spotdl():
    """Install spotdl via pip. Returns True on success."""
    logger.info("SpotDL not found — installing automatically...")
    try:
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", "--upgrade", "spotdl"],
            capture_output=True, text=True, timeout=180
        )
        if result.returncode == 0:
            logger.info("SpotDL installed successfully.")
            _spotdl_cache["installed"] = True
            _spotdl_cache["checked_at"] = time.time()
            return True
        else:
            logger.error(f"pip install spotdl failed: {result.stderr[:500]}")
            return False
    except Exception as e:
        logger.error(f"Auto-install spotdl failed: {e}")
        return False


def auto_install_ffmpeg():
    """Use spotdl's built-in FFmpeg downloader. Returns True on success."""
    logger.info("FFmpeg not found — downloading via spotdl...")
    try:
        result = subprocess.run(
            [sys.executable, "-m", "spotdl", "--download-ffmpeg"],
            capture_output=True, text=True, timeout=180
        )
        if result.returncode == 0:
            logger.info("FFmpeg downloaded successfully via spotdl.")
            _ffmpeg_cache["installed"] = True
            _ffmpeg_cache["checked_at"] = time.time()
            return True
        else:
            logger.warning(f"spotdl --download-ffmpeg output: {result.stderr[:500]}")
    except Exception as e:
        logger.warning(f"FFmpeg auto-download failed: {e}")

    # Fallback: install managed ffmpeg via Python package (works without system package manager)
    logger.info("Trying fallback FFmpeg install via imageio-ffmpeg...")
    try:
        pip_result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", "--upgrade", "imageio-ffmpeg"],
            capture_output=True,
            text=True,
            timeout=180,
        )
        if pip_result.returncode == 0 and get_ffmpeg_path():
            logger.info("FFmpeg installed via imageio-ffmpeg.")
            _ffmpeg_cache["installed"] = True
            _ffmpeg_cache["checked_at"] = time.time()
            return True
        logger.warning(f"imageio-ffmpeg install failed: {pip_result.stderr[:500]}")
    except Exception as e:
        logger.warning(f"Fallback FFmpeg install failed: {e}")

    return False


def get_spotdl_capabilities():
    """Detect supported CLI flags for installed spotdl version."""
    now = time.time()
    if _spotdl_caps_cache["caps"] is not None and (now - _spotdl_caps_cache["checked_at"]) < _CACHE_TTL:
        return _spotdl_caps_cache["caps"]

    caps = {
        "supports_download_subcommand": False,
        "supports_bitrate_arg": False,
        "supports_ignore_ffmpeg_version": False,
        "supports_ffmpeg_arg": False,
    }

    try:
        result = subprocess.run(
            [sys.executable, "-m", "spotdl", "--help"],
            capture_output=True,
            text=True,
            timeout=12,
        )
        help_text = (result.stdout or "") + "\n" + (result.stderr or "")
        lower = help_text.lower()

        caps["supports_download_subcommand"] = " spotdl download" in lower or "{download" in lower
        caps["supports_bitrate_arg"] = "--bitrate" in lower
        caps["supports_ignore_ffmpeg_version"] = "--ignore-ffmpeg-version" in lower
        caps["supports_ffmpeg_arg"] = "--ffmpeg" in lower or " -f," in lower
    except Exception:
        pass

    _spotdl_caps_cache["caps"] = caps
    _spotdl_caps_cache["checked_at"] = now
    return caps


def ensure_dependencies():
    """Make sure spotdl and FFmpeg are available. Auto-install if missing."""
    if not check_spotdl_installed():
        if not auto_install_spotdl():
            return False, "Could not install SpotDL. Check your internet connection."
    if not check_ffmpeg_installed():
        auto_install_ffmpeg()
        if not check_ffmpeg_installed():
            return False, "FFmpeg is missing. Run installer again or install dependencies from Settings page."
    return True, ""


# ── Download worker ────────────────────────────────────────────────────────────

def download_track(download_id, spotify_url, quality, download_path):
    """Run spotdl as a subprocess and track progress."""
    logger.info(f"[{download_id}] Starting download: {spotify_url}")

    with _download_lock:
        ACTIVE_DOWNLOADS[download_id]["status"] = "downloading"

    os.makedirs(download_path, exist_ok=True)

    caps = get_spotdl_capabilities()

    cmd = [sys.executable, "-m", "spotdl"]
    if caps["supports_download_subcommand"]:
        cmd.append("download")

    cmd.append(spotify_url)
    cmd.extend(["--output", download_path])

    if caps["supports_bitrate_arg"]:
        cmd.extend(["--bitrate", f"{quality}k"])

    if caps["supports_ignore_ffmpeg_version"]:
        cmd.append("--ignore-ffmpeg-version")

    ffmpeg_path = get_ffmpeg_path()
    if ffmpeg_path and caps["supports_ffmpeg_arg"]:
        cmd.extend(["--ffmpeg", ffmpeg_path])

    try:
        extra = {}
        if sys.platform == "win32":
            extra["creationflags"] = subprocess.CREATE_NO_WINDOW

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            encoding="utf-8",
            errors="replace",
            cwd=download_path,
            **extra,
        )

        # spotdl v4/v5 output patterns
        total_re = re.compile(r'(?:Found|Loaded)\s+(\d+)\s+(?:songs?|tracks?)', re.IGNORECASE)
        of_re    = re.compile(r'(\d+)\s*/\s*(\d+)')
        done_re  = re.compile(r'Downloaded\s+(?:\".+?\"\s+)?\((\d+)', re.IGNORECASE)

        tail = []
        for line in proc.stdout:
            line = line.rstrip()
            if not line:
                continue
            logger.info(f"[spotdl] {line}")
            tail.append(line)
            if len(tail) > 15:
                tail.pop(0)

            m_total = total_re.search(line)
            if m_total:
                with _download_lock:
                    ACTIVE_DOWNLOADS[download_id]["total"] = int(m_total.group(1))

            if any(kw in line for kw in ("Downloaded", "Downloading", "Skipping", "Processing")):
                m_of = of_re.search(line)
                if m_of:
                    done_val  = int(m_of.group(1))
                    total_val = int(m_of.group(2))
                    with _download_lock:
                        ACTIVE_DOWNLOADS[download_id]["done"] = done_val
                        if total_val > 0:
                            ACTIVE_DOWNLOADS[download_id]["total"] = total_val
                    continue

            m_done = done_re.search(line)
            if m_done:
                with _download_lock:
                    ACTIVE_DOWNLOADS[download_id]["done"] = int(m_done.group(1))

        proc.wait(timeout=600)

        if proc.returncode == 0:
            with _download_lock:
                ACTIVE_DOWNLOADS[download_id]["status"] = "completed"
            logger.info(f"[{download_id}] Download completed.")
        else:
            error_message = "spotdl exited with errors."
            if tail:
                meaningful = None
                for candidate in reversed(tail):
                    c = candidate.strip()
                    if not c:
                        continue
                    lower = c.lower()
                    if any(skip in lower for skip in ("warning", "debug", "info")):
                        continue
                    meaningful = c
                    break
                if meaningful:
                    error_message = meaningful

            with _download_lock:
                ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
                ACTIVE_DOWNLOADS[download_id]["error"] = error_message
            logger.error(f"[{download_id}] spotdl exited with code {proc.returncode}")

    except FileNotFoundError:
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
            ACTIVE_DOWNLOADS[download_id]["error"] = "SpotDL not found. Re-run the installer."
        logger.error("spotdl executable not found.")
    except subprocess.TimeoutExpired:
        proc.kill()
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
            ACTIVE_DOWNLOADS[download_id]["error"] = "Download timed out (10 min limit)."
        logger.error(f"[{download_id}] Timed out.")
    except Exception as e:
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
            ACTIVE_DOWNLOADS[download_id]["error"] = str(e)
        logger.error(f"[{download_id}] Unexpected error: {e}")


# ── HTTP Handler ───────────────────────────────────────────────────────────────

class DownloadRequestHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        logger.debug(f"[{self.address_string()}] {fmt % args}")

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    def _json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    # ── GET ────────────────────────────────────────────────────────────────

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self._json(200, {"status": "ok", "version": "1.1.0"})

        elif parsed.path == "/config":
            config = load_config()
            config["spotdl_installed"] = check_spotdl_installed()
            config["ffmpeg_installed"] = check_ffmpeg_installed()
            self._json(200, config)

        elif parsed.path == "/status":
            with _download_lock:
                active_ids = [
                    k for k, v in ACTIVE_DOWNLOADS.items()
                    if v["status"] in ("starting", "downloading")
                ]
                all_ids = list(ACTIVE_DOWNLOADS.keys())
            self._json(200, {"status": "ok", "active": active_ids, "downloads": all_ids})

        elif parsed.path.startswith("/progress/"):
            dl_id = parsed.path.split("/progress/", 1)[1]
            with _download_lock:
                info = ACTIVE_DOWNLOADS.get(dl_id)
            if info is None:
                self._json(404, {"error": "Unknown download id"})
            else:
                done  = info.get("done", 0)
                total = info.get("total", 0)
                pct   = round(done / total * 100) if total else 0
                self._json(200, {
                    "id": dl_id, "status": info["status"],
                    "done": done, "total": total, "percent": pct,
                    "error": info.get("error", ""),
                })

        elif parsed.path == "/check-deps":
            self._json(200, {
                "spotdl": check_spotdl_installed(),
                "ffmpeg": check_ffmpeg_installed(),
            })

        else:
            self._json(404, {"error": "Not found"})

    # ── POST ───────────────────────────────────────────────────────────────

    def do_POST(self):
        global _download_counter
        parsed = urlparse(self.path)
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        if parsed.path == "/download":
            try:
                data = json.loads(body.decode("utf-8"))
            except Exception:
                self._json(400, {"error": "Invalid JSON"})
                return

            spotify_url   = data.get("url", "").strip()
            quality       = data.get("quality", "320")
            config        = load_config()
            download_path = data.get("path", config.get("download_path", DEFAULT_CONFIG["download_path"]))

            if not spotify_url:
                self._json(400, {"error": "No URL provided"})
                return

            if "open.spotify.com/" not in spotify_url and "spotify:" not in spotify_url:
                self._json(400, {"error": "Invalid Spotify URL"})
                return

            ok, err = ensure_dependencies()
            if not ok:
                self._json(503, {"error": err})
                return

            with _download_lock:
                _download_counter += 1
                download_id = str(_download_counter)
                ACTIVE_DOWNLOADS[download_id] = {
                    "url": spotify_url, "status": "starting",
                    "done": 0, "total": 0, "error": "",
                    "started_at": time.time(),
                }

            t = threading.Thread(
                target=download_track,
                args=(download_id, spotify_url, quality, download_path),
                daemon=True,
            )
            t.start()

            self._json(200, {"status": "started", "url": spotify_url, "download_id": download_id})

        elif parsed.path == "/save-config":
            try:
                data = json.loads(body.decode("utf-8"))
            except Exception:
                self._json(400, {"error": "Invalid JSON"})
                return
            config = load_config()
            if "path" in data:
                config["download_path"] = data["path"]
            if "quality" in data:
                config["quality"] = data["quality"]
            if "port" in data:
                config["port"] = data["port"]
            save_config(config)
            self._json(200, {"status": "saved"})

        elif parsed.path == "/install-deps":
            ok, err = ensure_dependencies()
            self._json(200 if ok else 503, {
                "spotdl": check_spotdl_installed(),
                "ffmpeg": check_ffmpeg_installed(),
                "error": err,
            })

        else:
            self._json(404, {"error": "Not found"})


# ── Reusable HTTP Server ──────────────────────────────────────────────────────

class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


# ── Entry point ────────────────────────────────────────────────────────────────

def run_server(port=None):
    config = load_config()
    port = port or config.get("port", DEFAULT_CONFIG["port"])

    dl_path = config.get("download_path", DEFAULT_CONFIG["download_path"])
    os.makedirs(dl_path, exist_ok=True)

    # Pre-install deps
    logger.info("Checking dependencies...")
    if not check_spotdl_installed():
        auto_install_spotdl()
    if not check_ffmpeg_installed():
        auto_install_ffmpeg()

    # Start cleanup thread
    threading.Thread(target=_cleanup_loop, daemon=True).start()

    # Start HTTP server
    try:
        httpd = ReusableHTTPServer(("127.0.0.1", port), DownloadRequestHandler)
    except OSError:
        # Check if our server is already running
        import urllib.request
        try:
            r = urllib.request.urlopen(f"http://localhost:{port}/health", timeout=3)
            if r.status == 200:
                logger.info(f"Server already running on port {port}. Exiting.")
                return
        except Exception:
            pass
        logger.error(f"Cannot bind to port {port}. Close any program using it and retry.")
        sys.exit(1)

    logger.info(f"Spicetify Downloader server on http://localhost:{port}")
    logger.info(f"Download folder : {dl_path}")
    logger.info(f"Default quality : {config.get('quality', '320')} kbps")
    logger.info(f"SpotDL ready    : {check_spotdl_installed()}")
    logger.info(f"FFmpeg ready    : {check_ffmpeg_installed()}")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Server stopped.")
        httpd.server_close()


if __name__ == "__main__":
    run_server()
