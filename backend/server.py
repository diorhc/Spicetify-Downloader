import os
import json
import threading
import time
import logging
import subprocess
import sys
import re
import shutil
import collections
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
    "port": 8765,
    "engine": "auto",  # "auto", "spotdl" or "ytdlp"
}


def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                cfg = json.load(f)
                # Migrate: ensure engine key exists
                if "engine" not in cfg:
                    cfg["engine"] = DEFAULT_CONFIG["engine"]
                elif cfg.get("engine") not in ("auto", "spotdl", "ytdlp"):
                    cfg["engine"] = DEFAULT_CONFIG["engine"]
                return cfg
        except Exception:
            pass
    return DEFAULT_CONFIG.copy()


def save_config(config):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)


# ── Active downloads ───────────────────────────────────────────────────────────

ACTIVE_DOWNLOADS = {}
DOWNLOAD_LOGS = {}
_download_counter = 0
_download_lock = threading.Lock()
_CLEANUP_AGE = 1800


def cleanup_old_downloads():
    now = time.time()
    to_remove = []
    with _download_lock:
        for dl_id, info in ACTIVE_DOWNLOADS.items():
            if info["status"] in ("completed", "failed"):
                if now - info.get("started_at", now) > _CLEANUP_AGE:
                    to_remove.append(dl_id)
        for dl_id in to_remove:
            del ACTIVE_DOWNLOADS[dl_id]
            DOWNLOAD_LOGS.pop(dl_id, None)
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
_ytdlp_cache = {"installed": None, "checked_at": 0.0}
_ffmpeg_cache = {"installed": None, "checked_at": 0.0}
_spotdl_ver_cache = {"ver": None, "checked_at": 0.0}
_CACHE_TTL = 120


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


def check_ytdlp_installed():
    now = time.time()
    if _ytdlp_cache["installed"] is not None and (now - _ytdlp_cache["checked_at"]) < _CACHE_TTL:
        return _ytdlp_cache["installed"]
    installed = shutil.which("yt-dlp") is not None
    if not installed:
        try:
            result = subprocess.run(
                [sys.executable, "-m", "yt_dlp", "--version"],
                capture_output=True, text=True, timeout=10
            )
            installed = result.returncode == 0
        except Exception:
            pass
    _ytdlp_cache["installed"] = installed
    _ytdlp_cache["checked_at"] = now
    return installed


def get_ytdlp_cmd():
    """Return the yt-dlp command (either system binary or python module)."""
    system_ytdlp = shutil.which("yt-dlp")
    if system_ytdlp:
        return [system_ytdlp]
    return [sys.executable, "-m", "yt_dlp"]


def get_spotdl_version():
    now = time.time()
    if _spotdl_ver_cache["ver"] is not None and (now - _spotdl_ver_cache["checked_at"]) < _CACHE_TTL:
        return _spotdl_ver_cache["ver"]
    ver = (4, 0, 0)
    try:
        r = subprocess.run(
            [sys.executable, "-m", "spotdl", "--version"],
            capture_output=True, text=True, timeout=10
        )
        text = (r.stdout + r.stderr).strip()
        m = re.search(r'(\d+)\.(\d+)\.?(\d*)', text)
        if m:
            ver = (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))
    except Exception:
        pass
    _spotdl_ver_cache["ver"] = ver
    _spotdl_ver_cache["checked_at"] = now
    logger.info(f"SpotDL version detected: {ver[0]}.{ver[1]}.{ver[2]}")
    return ver


def check_ffmpeg_installed():
    now = time.time()
    if _ffmpeg_cache["installed"] is not None and (now - _ffmpeg_cache["checked_at"]) < _CACHE_TTL:
        return _ffmpeg_cache["installed"]
    installed = get_ffmpeg_path() is not None
    _ffmpeg_cache["installed"] = installed
    _ffmpeg_cache["checked_at"] = now
    return installed


def get_ffmpeg_path():
    system_ffmpeg = shutil.which("ffmpeg")
    if system_ffmpeg:
        return system_ffmpeg
    try:
        import imageio_ffmpeg
        managed = imageio_ffmpeg.get_ffmpeg_exe()
        if managed and os.path.exists(managed):
            return managed
    except Exception:
        pass
    for candidate in [
        os.path.join(os.path.expanduser("~"), ".spotdl", "ffmpeg.exe"),
        os.path.join(os.path.expanduser("~"), ".spotdl", "ffmpeg"),
        os.path.join(os.path.expanduser("~"), "AppData", "Local", "spotdl", "ffmpeg.exe"),
    ]:
        if os.path.exists(candidate):
            return candidate
    return None


def get_ffprobe_path():
    system_ffprobe = shutil.which("ffprobe")
    if system_ffprobe:
        return system_ffprobe

    ffmpeg_path = get_ffmpeg_path()
    if ffmpeg_path:
        ffmpeg_dir = os.path.dirname(os.path.abspath(ffmpeg_path))
        candidate = os.path.join(ffmpeg_dir, "ffprobe.exe" if sys.platform == "win32" else "ffprobe")
        if os.path.exists(candidate):
            return candidate

    return None


def build_ffmpeg_env():
    env = os.environ.copy()
    ffmpeg_path = get_ffmpeg_path()
    ffprobe_path = get_ffprobe_path()
    if ffmpeg_path:
        ffmpeg_dir = os.path.dirname(os.path.abspath(ffmpeg_path))
        env["PATH"] = ffmpeg_dir + os.pathsep + env.get("PATH", "")
        env["FFMPEG_BINARY"] = ffmpeg_path
        logger.info(f"FFmpeg injected into subprocess env: {ffmpeg_path}")
    if ffprobe_path:
        env["FFPROBE_BINARY"] = ffprobe_path
    return env


def auto_install_spotdl():
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
            _spotdl_ver_cache["ver"] = None
            return True
        else:
            logger.error(f"pip install spotdl failed: {result.stderr[:500]}")
            return False
    except Exception as e:
        logger.error(f"Auto-install spotdl failed: {e}")
        return False


def auto_install_ytdlp():
    logger.info("yt-dlp not found — installing automatically...")
    try:
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", "--upgrade", "yt-dlp"],
            capture_output=True, text=True, timeout=180
        )
        if result.returncode == 0:
            logger.info("yt-dlp installed successfully.")
            _ytdlp_cache["installed"] = True
            _ytdlp_cache["checked_at"] = time.time()
            return True
        else:
            logger.error(f"pip install yt-dlp failed: {result.stderr[:500]}")
            return False
    except Exception as e:
        logger.error(f"Auto-install yt-dlp failed: {e}")
        return False


def auto_install_ffmpeg():
    logger.info("FFmpeg not found — attempting auto-install...")
    # Method 1: spotdl --download-ffmpeg
    if check_spotdl_installed():
        try:
            result = subprocess.run(
                [sys.executable, "-m", "spotdl", "--download-ffmpeg"],
                capture_output=True, text=True, timeout=300, input="y\n"
            )
            if get_ffmpeg_path():
                logger.info("FFmpeg downloaded via spotdl.")
                _ffmpeg_cache["installed"] = True
                _ffmpeg_cache["checked_at"] = time.time()
                return True
        except Exception as e:
            logger.warning(f"FFmpeg via spotdl: {e}")

    # Method 2: imageio-ffmpeg
    try:
        pip_result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", "--upgrade", "imageio-ffmpeg"],
            capture_output=True, text=True, timeout=180,
        )
        if pip_result.returncode == 0 and get_ffmpeg_path():
            logger.info("FFmpeg installed via imageio-ffmpeg.")
            _ffmpeg_cache["installed"] = True
            _ffmpeg_cache["checked_at"] = time.time()
            return True
    except Exception as e:
        logger.warning(f"Fallback FFmpeg install failed: {e}")

    return False


def ensure_dependencies(engine=None):
    """Make sure selected engine + FFmpeg are available. Returns (ok, error_str)."""
    if engine is None:
        engine = load_config().get("engine", "auto")

    if engine == "spotdl":
        if not check_spotdl_installed():
            if not auto_install_spotdl():
                return False, "Could not install SpotDL. Check your internet connection."
    elif engine == "ytdlp":
        if not check_ytdlp_installed():
            if not auto_install_ytdlp():
                return False, "Could not install yt-dlp. Check your internet connection."
    else:  # auto
        if not check_spotdl_installed() and not auto_install_spotdl():
            if not check_ytdlp_installed() and not auto_install_ytdlp():
                return False, "Could not install spotdl or yt-dlp. Check your internet connection."
        if not check_ytdlp_installed():
            auto_install_ytdlp()

    if not check_ffmpeg_installed():
        auto_install_ffmpeg()
        if not check_ffmpeg_installed():
            return False, "FFmpeg is missing. Run installer again or install from Settings page."

    return True, ""


# ── Spotify URL helpers ────────────────────────────────────────────────────────

def parse_spotify_url(url):
    """Extract (type, id) from a Spotify URL. Returns None if invalid."""
    m = re.search(r'open\.spotify\.com/(playlist|album|track)/([A-Za-z0-9]+)', url)
    if m:
        return m.group(1), m.group(2)
    m = re.search(r'spotify:(playlist|album|track):([A-Za-z0-9]+)', url)
    if m:
        return m.group(1), m.group(2)
    return None


def spotify_url_to_search_query(url):
    """
    Convert Spotify URL to a search query using Spotify's oEmbed API (no auth needed).
    """
    oembed_url = f"https://open.spotify.com/oembed?url={url}"
    try:
        import urllib.request
        req = urllib.request.Request(oembed_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("title", "")
    except Exception as e:
        logger.warning(f"oEmbed lookup failed: {e}")
        return ""


# ── Spotify embed scraper (no API needed) ──────────────────────────────────────

def scrape_spotify_tracks(url):
    """
    Use Spotify's public embed/oEmbed endpoints to get track info.
    Returns list of dicts: [{name, spotify_url}, ...]
    No API keys required.
    """
    parsed = parse_spotify_url(url)
    if not parsed:
        return []

    content_type, content_id = parsed

    if content_type == "track":
        title = spotify_url_to_search_query(url)
        return [{"name": title or f"track {content_id}", "spotify_url": url}]

    # For playlists/albums: try embed page to extract track data
    embed_url = f"https://open.spotify.com/embed/{content_type}/{content_id}"
    try:
        import urllib.request
        req = urllib.request.Request(embed_url, headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        })
        with urllib.request.urlopen(req, timeout=15) as resp:
            html = resp.read().decode("utf-8", errors="replace")

        # Try to extract __NEXT_DATA__ JSON
        m = re.search(r'<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.DOTALL)
        if m:
            try:
                next_data = json.loads(m.group(1))
                # Navigate common JSON structures
                props = next_data.get("props", {}).get("pageProps", {})
                state = props.get("state", props)

                items = []
                for key in ("tracks", "trackList", "items"):
                    candidate = state.get(key)
                    if isinstance(candidate, dict):
                        items = candidate.get("items", [])
                    elif isinstance(candidate, list):
                        items = candidate
                    if items:
                        break

                if not items and "data" in state:
                    data = state["data"]
                    if isinstance(data, dict):
                        for key in ("tracks", "trackList"):
                            candidate = data.get(key)
                            if isinstance(candidate, dict):
                                items = candidate.get("items", [])
                            elif isinstance(candidate, list):
                                items = candidate
                            if items:
                                break

                tracks = []
                for item in items:
                    track = item.get("track", item) if isinstance(item, dict) else {}
                    name = track.get("name", "")
                    artists = ", ".join(a.get("name", "") for a in track.get("artists", []))
                    track_id = track.get("id", "")
                    search_q = f"{name} {artists}" if artists else name
                    if search_q.strip():
                        tracks.append({
                            "name": search_q,
                            "spotify_url": f"https://open.spotify.com/track/{track_id}" if track_id else "",
                        })
                if tracks:
                    return tracks
            except Exception as e:
                logger.warning(f"Failed to parse embed JSON: {e}")

        # Fallback: try regex patterns on embed HTML
        track_pattern = re.findall(
            r'"name"\s*:\s*"([^"]+)"[^}]*?"artists"\s*:\s*\[([^\]]*)\]',
            html
        )
        if track_pattern:
            tracks = []
            for name, artists_json in track_pattern:
                artist_names = re.findall(r'"name"\s*:\s*"([^"]+)"', artists_json)
                search_q = f"{name} {', '.join(artist_names)}" if artist_names else name
                tracks.append({"name": search_q, "spotify_url": ""})
            if tracks:
                return tracks

    except Exception as e:
        logger.warning(f"Embed scrape failed: {e}")

    # Final fallback: just get the playlist/album title from oEmbed
    title = spotify_url_to_search_query(url)
    if title:
        return [{"name": title, "spotify_url": url}]

    return []


# ── Command builder: spotdl ───────────────────────────────────────────────────

_help_cache = {"text": None, "checked_at": 0.0}


def _spotdl_help():
    now = time.time()
    if _help_cache["text"] is not None and (now - _help_cache["checked_at"]) < _CACHE_TTL:
        return _help_cache["text"]
    try:
        r = subprocess.run(
            [sys.executable, "-m", "spotdl", "--help"],
            capture_output=True, text=True, timeout=15
        )
        text = (r.stdout or "") + (r.stderr or "")
    except Exception:
        text = ""
    _help_cache["text"] = text
    _help_cache["checked_at"] = now
    return text


def build_spotdl_cmd(spotify_url, quality, download_path):
    """
    Build the spotdl command. No API keys needed — spotdl v4+ uses
    embedded credentials automatically.
    """
    major, minor, patch = get_spotdl_version()
    ffmpeg_path = get_ffmpeg_path()
    help_text = _spotdl_help().lower()

    out_template_v4 = os.path.join(download_path, "{title} - {artists}.{output-ext}")
    path_template_v3 = "{title} - {artist}.{ext}"

    cmd = [sys.executable, "-m", "spotdl"]

    if major >= 4:
        cmd.append("download")
        cmd.append(spotify_url)
        cmd.extend(["--output", out_template_v4])
        cmd.extend(["--bitrate", f"{quality}k"])
        cmd.extend(["--overwrite", "skip"])
        if "--ignore-ffmpeg-version" in help_text:
            cmd.append("--ignore-ffmpeg-version")
        if ffmpeg_path and "--ffmpeg" in help_text:
            cmd.extend(["--ffmpeg", ffmpeg_path])
    else:
        cmd.append(spotify_url)
        cmd.extend(["--output", download_path])
        cmd.extend(["-p", path_template_v3])
        if ffmpeg_path and "--ffmpeg" in help_text:
            cmd.extend(["--ffmpeg", ffmpeg_path])

    logger.info(f"SpotDL v{major}.{minor}.{patch} command: {' '.join(cmd)}")
    return cmd


# ── Command builder: yt-dlp ──────────────────────────────────────────────────

def build_ytdlp_cmd(search_query, quality, download_path, filename=None):
    """Build yt-dlp command to search YouTube and download audio."""
    cmd = get_ytdlp_cmd()

    # Search YouTube for the query
    cmd.append(f"ytsearch1:{search_query}")

    ffmpeg_path = get_ffmpeg_path()
    ffprobe_path = get_ffprobe_path()
    can_postprocess = bool(ffmpeg_path and ffprobe_path)

    # Always pick best audio stream.
    cmd.extend(["-f", "bestaudio/best"])

    # Convert to MP3 only when full ffmpeg toolchain is available.
    if can_postprocess:
        cmd.extend(["-x", "--audio-format", "mp3"])

    # Quality mapping
    quality_map = {"128": "128K", "160": "160K", "320": "320K"}
    if can_postprocess:
        cmd.extend(["--audio-quality", quality_map.get(quality, "320K")])

    # Output template
    if filename:
        safe_name = re.sub(r'[\\/:*?"<>|]', '_', filename)
        out_path = os.path.join(download_path, f"{safe_name}.%(ext)s")
    else:
        out_path = os.path.join(download_path, "%(title)s.%(ext)s")

    cmd.extend(["-o", out_path])
    cmd.append("--no-playlist")
    if can_postprocess:
        cmd.append("--add-metadata")

    # FFmpeg location for post-processing
    if can_postprocess and ffmpeg_path:
        cmd.extend(["--ffmpeg-location", os.path.dirname(os.path.abspath(ffmpeg_path))])

    if not can_postprocess:
        logger.warning("ffprobe not found; yt-dlp will download original audio format without MP3 conversion")

    logger.info(f"yt-dlp command: {' '.join(cmd)}")
    return cmd


# ── Output parser: spotdl ─────────────────────────────────────────────────────

def parse_spotdl_line(line, download_id):
    m_total = re.search(r'(?:Found|Loaded)\s+(\d+)\s+(?:songs?|tracks?)', line, re.IGNORECASE)
    if m_total:
        with _download_lock:
            if int(m_total.group(1)) > ACTIVE_DOWNLOADS[download_id]["total"]:
                ACTIVE_DOWNLOADS[download_id]["total"] = int(m_total.group(1))
        return

    if any(kw in line for kw in ("Downloaded", "Downloading", "Skipping", "Processing", "Searching")):
        m_of = re.search(r'(\d+)\s*/\s*(\d+)', line)
        if m_of:
            done_val = int(m_of.group(1))
            total_val = int(m_of.group(2))
            with _download_lock:
                if done_val > ACTIVE_DOWNLOADS[download_id]["done"]:
                    ACTIVE_DOWNLOADS[download_id]["done"] = done_val
                if total_val > ACTIVE_DOWNLOADS[download_id]["total"]:
                    ACTIVE_DOWNLOADS[download_id]["total"] = total_val
            return

    if re.match(r'\s*(Downloaded|Skipping|Failed|Error)\b', line, re.IGNORECASE):
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["done"] += 1


# ── Download worker: spotdl ───────────────────────────────────────────────────

def download_with_spotdl(download_id, spotify_url, quality, download_path):
    """Run spotdl as subprocess. No API keys required."""
    logger.info(f"[{download_id}] Starting spotdl download: {spotify_url}")

    with _download_lock:
        ACTIVE_DOWNLOADS[download_id]["status"] = "downloading"
        DOWNLOAD_LOGS[download_id] = collections.deque(maxlen=200)

    os.makedirs(download_path, exist_ok=True)
    cmd = build_spotdl_cmd(spotify_url, quality, download_path)
    env = build_ffmpeg_env()

    try:
        extra = {}
        if sys.platform == "win32":
            extra["creationflags"] = subprocess.CREATE_NO_WINDOW

        rate_limited = False

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            encoding="utf-8",
            errors="replace",
            cwd=download_path,
            env=env,
            **extra,
        )

        for line in proc.stdout:
            line = line.rstrip()
            if not line:
                continue
            logger.info(f"[spotdl] {line}")
            lower = line.lower()
            with _download_lock:
                if download_id in DOWNLOAD_LOGS:
                    DOWNLOAD_LOGS[download_id].append(line)
            parse_spotdl_line(line, download_id)

            if (
                "rate/request limit" in lower
                or "retry will occur after" in lower
                or "too many requests" in lower
            ):
                rate_limited = True
                logger.warning(f"[{download_id}] spotdl rate-limited, switching to fallback engine.")
                with _download_lock:
                    if download_id in DOWNLOAD_LOGS:
                        DOWNLOAD_LOGS[download_id].append("spotdl rate-limited; switching to fallback engine")
                try:
                    proc.terminate()
                except Exception:
                    pass
                break

        proc.wait(timeout=600)

        if proc.returncode == 0 and not rate_limited:
            with _download_lock:
                total = ACTIVE_DOWNLOADS[download_id].get("total", 0)
                done = ACTIVE_DOWNLOADS[download_id].get("done", 0)
                if total > 0 and done < total:
                    ACTIVE_DOWNLOADS[download_id]["done"] = total
                ACTIVE_DOWNLOADS[download_id]["status"] = "completed"
            logger.info(f"[{download_id}] spotdl download completed.")
            return True
        else:
            error_message = (
                "spotdl hit a temporary rate limit; falling back to yt-dlp."
                if rate_limited
                else f"spotdl exited with code {proc.returncode}."
            )
            with _download_lock:
                log_lines = list(DOWNLOAD_LOGS.get(download_id, []))
            if not rate_limited:
                for candidate in reversed(log_lines):
                    c = candidate.strip()
                    if not c:
                        continue
                    lower = c.lower()
                    if any(skip in lower for skip in ("warning:", "debug:", "info:", "processing")):
                        continue
                    error_message = c
                    break
            with _download_lock:
                ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
                ACTIVE_DOWNLOADS[download_id]["error"] = error_message
            logger.error(f"[{download_id}] spotdl failed: {error_message}")
            return False

    except FileNotFoundError:
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
            ACTIVE_DOWNLOADS[download_id]["error"] = "SpotDL not found. Re-run the installer."
        return False
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except Exception:
            pass
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
            ACTIVE_DOWNLOADS[download_id]["error"] = "Download timed out (10 min limit)."
        return False
    except Exception as e:
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
            ACTIVE_DOWNLOADS[download_id]["error"] = str(e)
        return False


# ── Download worker: yt-dlp ───────────────────────────────────────────────────

def download_single_ytdlp(search_query, quality, download_path, filename=None):
    """Download a single track via yt-dlp. Returns (success, error_msg)."""
    cmd = build_ytdlp_cmd(search_query, quality, download_path, filename)
    env = build_ffmpeg_env()
    media_exts = {".mp3", ".m4a", ".webm", ".opus", ".ogg", ".wav", ".flac", ".aac"}

    try:
        before_files = {
            name for name in os.listdir(download_path)
            if os.path.splitext(name)[1].lower() in media_exts
        }
    except Exception:
        before_files = set()

    try:
        extra = {}
        if sys.platform == "win32":
            extra["creationflags"] = subprocess.CREATE_NO_WINDOW

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            encoding="utf-8",
            errors="replace",
            cwd=download_path,
            env=env,
            **extra,
        )

        output_lines = []
        for line in proc.stdout:
            line = line.rstrip()
            if line:
                output_lines.append(line)
                logger.info(f"[yt-dlp] {line}")

        proc.wait(timeout=300)

        if proc.returncode == 0:
            return True, ""
        else:
            err = f"yt-dlp exited with code {proc.returncode}"
            for line in reversed(output_lines):
                low = line.lower()
                if "error" in low or "failed" in low or "unable" in low:
                    err = line
                    break

            # Some post-processing steps can fail after media was already downloaded.
            try:
                after_files = {
                    name for name in os.listdir(download_path)
                    if os.path.splitext(name)[1].lower() in media_exts
                }
            except Exception:
                after_files = set()

            if len(after_files - before_files) > 0:
                logger.warning(f"yt-dlp returned non-zero but media file was created: {err}")
                return True, ""

            return False, err

    except Exception as e:
        return False, str(e)


def download_with_ytdlp(download_id, spotify_url, quality, download_path, tracks=None):
    """
    Download via yt-dlp.  If *tracks* is provided (pre-resolved by the frontend
    via Spicetify.CosmosAsync) it is used directly, skipping all scraping.
    """
    logger.info(f"[{download_id}] Starting yt-dlp download: {spotify_url}")

    with _download_lock:
        ACTIVE_DOWNLOADS[download_id]["status"] = "downloading"
        DOWNLOAD_LOGS[download_id] = collections.deque(maxlen=500)

    os.makedirs(download_path, exist_ok=True)
    parsed = parse_spotify_url(spotify_url)

    if not parsed:
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
            ACTIVE_DOWNLOADS[download_id]["error"] = "Invalid Spotify URL."
        return False

    content_type, content_id = parsed

    if content_type == "track":
        # ── Single track ───────────────────────────────────────────────────
        if tracks and tracks[0].get("name"):
            title = tracks[0]["name"]
        else:
            title = spotify_url_to_search_query(spotify_url) or f"spotify track {content_id}"

        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["total"] = 1
            if download_id in DOWNLOAD_LOGS:
                DOWNLOAD_LOGS[download_id].append(f"Searching YouTube: {title}")

        success, err = download_single_ytdlp(title, quality, download_path, title)
        with _download_lock:
            if success:
                ACTIVE_DOWNLOADS[download_id]["done"] = 1
                ACTIVE_DOWNLOADS[download_id]["status"] = "completed"
            else:
                ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
                ACTIVE_DOWNLOADS[download_id]["error"] = err
            if download_id in DOWNLOAD_LOGS:
                DOWNLOAD_LOGS[download_id].append(
                    "Completed!" if success else f"Failed: {err}"
                )
        return success

    else:
        # ── Playlist / album ───────────────────────────────────────────────
        if tracks:
            # Pre-resolved from the Spicetify frontend — fast & accurate
            logger.info(f"[{download_id}] Using pre-resolved track list ({len(tracks)} tracks)")
            with _download_lock:
                ACTIVE_DOWNLOADS[download_id]["total"] = len(tracks)
                if download_id in DOWNLOAD_LOGS:
                    DOWNLOAD_LOGS[download_id].append(
                        f"Track list from Spotify ({len(tracks)} tracks)."
                    )
        else:
            # Fallback: scrape Spotify embed page
            with _download_lock:
                if download_id in DOWNLOAD_LOGS:
                    DOWNLOAD_LOGS[download_id].append(f"Fetching {content_type} track list...")

            tracks = scrape_spotify_tracks(spotify_url)
            if not tracks:
                title = spotify_url_to_search_query(spotify_url)
                if title:
                    with _download_lock:
                        ACTIVE_DOWNLOADS[download_id]["total"] = 1
                    success, err = download_single_ytdlp(title, quality, download_path, title)
                    with _download_lock:
                        if success:
                            ACTIVE_DOWNLOADS[download_id]["done"] = 1
                            ACTIVE_DOWNLOADS[download_id]["status"] = "completed"
                        else:
                            ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
                            ACTIVE_DOWNLOADS[download_id]["error"] = err
                    return success
                else:
                    with _download_lock:
                        ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
                        ACTIVE_DOWNLOADS[download_id]["error"] = (
                            "Could not retrieve track list. "
                            "Try the spotdl engine or paste a direct track URL."
                        )
                    return False

            with _download_lock:
                ACTIVE_DOWNLOADS[download_id]["total"] = len(tracks)
                if download_id in DOWNLOAD_LOGS:
                    DOWNLOAD_LOGS[download_id].append(f"Found {len(tracks)} tracks.")

        total = len(tracks)
        failed_tracks = []  # collect failed ones for capture-mode hint
        failed_count = 0
        for i, track in enumerate(tracks):
            search_q = track.get("name", "")
            if not search_q:
                failed_count += 1
                continue

            with _download_lock:
                if download_id in DOWNLOAD_LOGS:
                    DOWNLOAD_LOGS[download_id].append(f"[{i+1}/{total}] {search_q}")

            success, err = download_single_ytdlp(search_q, quality, download_path, search_q)

            with _download_lock:
                ACTIVE_DOWNLOADS[download_id]["done"] = i + 1
                if not success:
                    failed_count += 1
                    failed_tracks.append(track)
                    if download_id in DOWNLOAD_LOGS:
                        DOWNLOAD_LOGS[download_id].append(f"  ✗ Failed: {err}")
                else:
                    if download_id in DOWNLOAD_LOGS:
                        DOWNLOAD_LOGS[download_id].append(f"  ✓ Done")

        # Store failed tracks for potential playback capture
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["failed_tracks"] = failed_tracks
            if failed_count == total:
                ACTIVE_DOWNLOADS[download_id]["status"] = "failed"
                ACTIVE_DOWNLOADS[download_id]["error"] = "All tracks failed to download."
            elif failed_count > 0:
                ACTIVE_DOWNLOADS[download_id]["status"] = "completed"
                ACTIVE_DOWNLOADS[download_id]["error"] = (
                    f"{failed_count}/{total} tracks failed. "
                    "Open the playlist and use Capture mode to record missing tracks."
                )
            else:
                ACTIVE_DOWNLOADS[download_id]["status"] = "completed"

        logger.info(
            f"[{download_id}] yt-dlp batch done: {total - failed_count}/{total} succeeded."
        )
        return failed_count < total


# ── Unified download worker ───────────────────────────────────────────────────

def download_track(download_id, spotify_url, quality, download_path, engine=None, tracks=None):
    """Main download entry point. Picks engine, with automatic fallback.

    *tracks*: optional list of {name, spotify_url} dicts pre-resolved by the
    frontend via Spicetify.CosmosAsync — skips scraping when provided.
    """
    if engine is None:
        engine = load_config().get("engine", "auto")

    logger.info(f"[{download_id}] Engine: {engine}, pre-resolved tracks: {len(tracks) if tracks else 0}")

    def _reset_for_fallback(message):
        with _download_lock:
            ACTIVE_DOWNLOADS[download_id]["status"] = "downloading"
            ACTIVE_DOWNLOADS[download_id]["done"] = 0
            ACTIVE_DOWNLOADS[download_id]["total"] = 0
            ACTIVE_DOWNLOADS[download_id]["error"] = ""
            if download_id in DOWNLOAD_LOGS:
                DOWNLOAD_LOGS[download_id].append(message)

    if engine == "auto":
        # Prefer spotdl first (ignores pre-resolved tracks — spotdl resolves itself)
        success = download_with_spotdl(download_id, spotify_url, quality, download_path)
        if success:
            return

        if check_ytdlp_installed():
            logger.info(f"[{download_id}] auto: spotdl failed, falling back to yt-dlp...")
            _reset_for_fallback("--- Auto fallback: spotdl \u2192 yt-dlp ---")
            # Pass pre-resolved tracks so yt-dlp skips scraping
            ytdlp_success = download_with_ytdlp(
                download_id, spotify_url, quality, download_path, tracks=tracks
            )

            # If yt-dlp had partial failures, do a final spotdl pass.
            with _download_lock:
                partial_info = ACTIVE_DOWNLOADS[download_id].get("error", "")
            if ytdlp_success and partial_info and "tracks failed" in partial_info.lower() and check_spotdl_installed():
                logger.info(f"[{download_id}] auto: yt-dlp partial failures, final spotdl pass...")
                _reset_for_fallback("--- Auto fallback: yt-dlp partial \u2192 spotdl ---")
                download_with_spotdl(download_id, spotify_url, quality, download_path)
        return

    if engine == "spotdl":
        success = download_with_spotdl(download_id, spotify_url, quality, download_path)
        if not success and check_ytdlp_installed():
            logger.info(f"[{download_id}] spotdl failed, falling back to yt-dlp...")
            _reset_for_fallback("--- Falling back to yt-dlp ---")
            ytdlp_success = download_with_ytdlp(
                download_id, spotify_url, quality, download_path, tracks=tracks
            )
            with _download_lock:
                partial_info = ACTIVE_DOWNLOADS[download_id].get("error", "")
            if ytdlp_success and partial_info and "tracks failed" in partial_info.lower() and check_spotdl_installed():
                logger.info(f"[{download_id}] yt-dlp partial failures, final spotdl pass...")
                _reset_for_fallback("--- Final fallback: yt-dlp partial \u2192 spotdl ---")
                download_with_spotdl(download_id, spotify_url, quality, download_path)
    elif engine == "ytdlp":
        success = download_with_ytdlp(
            download_id, spotify_url, quality, download_path, tracks=tracks
        )
        if not success and check_spotdl_installed():
            logger.info(f"[{download_id}] yt-dlp failed, falling back to spotdl...")
            _reset_for_fallback("--- Falling back to spotdl ---")
            download_with_spotdl(download_id, spotify_url, quality, download_path)
    else:
        download_with_spotdl(download_id, spotify_url, quality, download_path)


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
            config = load_config()
            self._json(200, {
                "status": "ok",
                "version": "2.0.0",
                "engine": config.get("engine", "spotdl"),
            })

        elif parsed.path == "/config":
            config = load_config()
            config["spotdl_installed"] = check_spotdl_installed()
            config["ytdlp_installed"] = check_ytdlp_installed()
            config["ffmpeg_installed"] = check_ffmpeg_installed()
            config["ffprobe_installed"] = get_ffprobe_path() is not None
            if check_spotdl_installed():
                ver = get_spotdl_version()
                config["spotdl_version"] = f"{ver[0]}.{ver[1]}.{ver[2]}"
            else:
                config["spotdl_version"] = "N/A"
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
                done = info.get("done", 0)
                total = info.get("total", 0)
                pct = round(done / total * 100) if total else 0
                self._json(200, {
                    "id": dl_id, "status": info["status"],
                    "done": done, "total": total, "percent": pct,
                    "error": info.get("error", ""),
                    "collection": info.get("collection", ""),
                    "failed_tracks": info.get("failed_tracks", []),
                })

        elif parsed.path.startswith("/logs/"):
            dl_id = parsed.path.split("/logs/", 1)[1]
            with _download_lock:
                lines = list(DOWNLOAD_LOGS.get(dl_id, []))
            self._json(200, {"id": dl_id, "lines": lines[-50:]})

        elif parsed.path == "/check-deps":
            result = {
                "spotdl": check_spotdl_installed(),
                "ytdlp": check_ytdlp_installed(),
                "ffmpeg": check_ffmpeg_installed(),
                "ffprobe": get_ffprobe_path() is not None,
                "ffmpeg_path": get_ffmpeg_path() or "",
            }
            if check_spotdl_installed():
                ver = get_spotdl_version()
                result["spotdl_version"] = f"{ver[0]}.{ver[1]}.{ver[2]}"
            else:
                result["spotdl_version"] = "N/A"
            self._json(200, result)

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

            spotify_url = data.get("url", "").strip()
            quality = data.get("quality", "320")
            config = load_config()
            download_path = data.get("path", config.get("download_path", DEFAULT_CONFIG["download_path"]))
            engine = data.get("engine", config.get("engine", "spotdl"))

            if not spotify_url:
                self._json(400, {"error": "No URL provided"})
                return

            if "open.spotify.com/" not in spotify_url and "spotify:" not in spotify_url:
                self._json(400, {"error": "Invalid Spotify URL"})
                return

            # Optional pre-resolved track list from Spicetify frontend
            tracks = data.get("tracks", None)  # list of {name, spotify_url}
            collection_name = data.get("collection_name", "").strip()

            # For playlists and albums: save into a named subfolder
            parsed_type = parse_spotify_url(spotify_url)
            if parsed_type and parsed_type[0] in ("playlist", "album"):
                folder_name = collection_name  # prefer frontend-provided name
                if not folder_name and not tracks:
                    # Only call oEmbed when the frontend gave us nothing
                    folder_name = spotify_url_to_search_query(spotify_url)
                if folder_name:
                    safe_name = re.sub(r'[\\/:*?"<>|]', "_", folder_name).strip(". ")
                    if safe_name:
                        download_path = os.path.join(download_path, safe_name)
                        logger.info(f"Collection subfolder: {download_path}")

            ok, err = ensure_dependencies(engine)
            if not ok:
                self._json(503, {"error": err})
                return

            # Determine initial total so frontend progress bar shows instantly
            initial_total = len(tracks) if tracks else 0

            with _download_lock:
                _download_counter += 1
                download_id = str(_download_counter)
                ACTIVE_DOWNLOADS[download_id] = {
                    "url": spotify_url, "status": "starting",
                    "done": 0, "total": initial_total, "error": "",
                    "started_at": time.time(), "engine": engine,
                    "collection": collection_name,
                }
                DOWNLOAD_LOGS[download_id] = collections.deque(maxlen=500)

            t = threading.Thread(
                target=download_track,
                args=(download_id, spotify_url, quality, download_path, engine, tracks),
                daemon=True,
            )
            t.start()

            self._json(200, {
                "status": "started",
                "url": spotify_url,
                "download_id": download_id,
                "engine": engine,
                "total": initial_total,
            })

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
            if "engine" in data and data["engine"] in ("auto", "spotdl", "ytdlp"):
                config["engine"] = data["engine"]
            save_config(config)
            self._json(200, {"status": "saved"})

        elif parsed.path == "/install-deps":
            try:
                data = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                data = {}
            install_engine = data.get("engine", "all")

            results = {}
            errors = []

            if install_engine in ("all", "spotdl"):
                if not check_spotdl_installed():
                    if auto_install_spotdl():
                        results["spotdl"] = True
                    else:
                        results["spotdl"] = False
                        errors.append("Could not install spotdl")
                else:
                    results["spotdl"] = True

            if install_engine in ("all", "ytdlp"):
                if not check_ytdlp_installed():
                    if auto_install_ytdlp():
                        results["ytdlp"] = True
                    else:
                        results["ytdlp"] = False
                        errors.append("Could not install yt-dlp")
                else:
                    results["ytdlp"] = True

            if not check_ffmpeg_installed():
                auto_install_ffmpeg()

            results["ffmpeg"] = check_ffmpeg_installed()
            if not results["ffmpeg"]:
                errors.append("Could not install FFmpeg")

            results["error"] = "; ".join(errors) if errors else ""
            self._json(200 if not errors else 503, results)

        elif parsed.path == "/capture-track":
            # Save audio captured by the frontend via MediaRecorder (Soggfy-style)
            import base64
            try:
                data = json.loads(body.decode("utf-8"))
            except Exception:
                self._json(400, {"error": "Invalid JSON"})
                return

            track_name = (data.get("name") or "captured_track").strip()
            audio_b64   = data.get("data", "")
            mime_type   = data.get("mime_type", "audio/ogg")
            config      = load_config()
            dl_path     = data.get("path") or config.get("download_path", DEFAULT_CONFIG["download_path"])

            if not audio_b64:
                self._json(400, {"error": "No audio data"})
                return

            ext = ".ogg"
            if "webm" in mime_type:
                ext = ".webm"
            elif "mp4" in mime_type or "aac" in mime_type:
                ext = ".m4a"
            elif "mpeg" in mime_type or "mp3" in mime_type:
                ext = ".mp3"

            safe_name = re.sub(r'[\\/:*?"<>|]', "_", track_name).strip(". ")
            if not safe_name:
                safe_name = "captured_track"

            try:
                audio_bytes = base64.b64decode(audio_b64)
                if len(audio_bytes) < 4096:
                    self._json(400, {"error": "Audio data too short — recording incomplete"})
                    return

                os.makedirs(dl_path, exist_ok=True)
                out_path = os.path.join(dl_path, safe_name + ext)

                # Avoid overwriting existing files
                counter = 1
                while os.path.exists(out_path):
                    out_path = os.path.join(dl_path, f"{safe_name} ({counter}){ext}")
                    counter += 1

                with open(out_path, "wb") as f:
                    f.write(audio_bytes)

                logger.info(f"Captured track saved: {out_path} ({len(audio_bytes)} bytes)")
                self._json(200, {"status": "saved", "path": out_path, "size": len(audio_bytes)})
            except Exception as e:
                logger.error(f"Failed to save captured track: {e}")
                self._json(500, {"error": str(e)})

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

    logger.info("Checking dependencies...")
    spotdl_ok = check_spotdl_installed()
    ytdlp_ok = check_ytdlp_installed()
    ffmpeg_ok = check_ffmpeg_installed()
    logger.info(f"SpotDL : {'OK' if spotdl_ok else 'MISSING'}")
    logger.info(f"yt-dlp : {'OK' if ytdlp_ok else 'MISSING'}")
    logger.info(f"FFmpeg : {'OK' if ffmpeg_ok else 'MISSING'} ({get_ffmpeg_path() or 'not found'})")
    logger.info(f"Engine : {config.get('engine', 'spotdl')}")

    # Auto-install missing deps in background
    if not spotdl_ok:
        threading.Thread(target=auto_install_spotdl, daemon=True).start()
    if not ytdlp_ok:
        threading.Thread(target=auto_install_ytdlp, daemon=True).start()
    if not ffmpeg_ok:
        threading.Thread(target=auto_install_ffmpeg, daemon=True).start()

    threading.Thread(target=_cleanup_loop, daemon=True).start()

    try:
        httpd = ReusableHTTPServer(("127.0.0.1", port), DownloadRequestHandler)
    except OSError:
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
    logger.info("No API keys required!")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Server stopped.")
        httpd.server_close()


if __name__ == "__main__":
    run_server()
