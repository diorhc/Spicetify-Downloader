// Spicetify Custom App — main entry point
// Spicetify calls render() when the sidebar page is opened.

const API_URL = "http://localhost:8765";
const react = Spicetify.React;
const reactDOM = Spicetify.ReactDOM;

// ── Utilities ──────────────────────────────────────────────────────────────

async function fetchJSON(path) {
  const res = await fetch(`${API_URL}${path}`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

// ── Components ─────────────────────────────────────────────────────────────

function StatusBadge({ online }) {
  return react.createElement(
    "div",
    {
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 8,
        padding: "6px 14px",
        borderRadius: 20,
        fontSize: 13,
        fontWeight: 600,
        background: online ? "rgba(29,185,84,.15)" : "rgba(233,20,41,.15)",
        color: online ? "#1DB954" : "#e91429",
        border: `1px solid ${online ? "#1DB954" : "#e91429"}`,
      },
    },
    react.createElement("span", {
      style: {
        width: 8,
        height: 8,
        borderRadius: "50%",
        background: online ? "#1DB954" : "#e91429",
        boxShadow: online ? "0 0 6px #1DB954" : "none",
      },
    }),
    online ? "Server running" : "Server offline",
  );
}

function DepsBadge({ label, ok }) {
  const color = ok ? "#1DB954" : "#f59e0b";
  return react.createElement(
    "span",
    {
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 4,
        fontSize: 12,
        color,
      },
    },
    react.createElement("span", {
      style: {
        width: 6,
        height: 6,
        borderRadius: "50%",
        background: color,
      },
    }),
    `${label}: ${ok ? "OK" : "Missing"}`,
  );
}

function ProgressBar({ percent }) {
  return react.createElement(
    "div",
    {
      style: {
        background: "#282828",
        borderRadius: 4,
        height: 6,
        overflow: "hidden",
        marginTop: 8,
      },
    },
    react.createElement("div", {
      style: {
        height: "100%",
        borderRadius: 4,
        background: "#1DB954",
        width: `${Math.min(percent, 100)}%`,
        transition: "width .4s ease",
      },
    }),
  );
}

function DownloadCard({ id }) {
  const [info, setInfo] = react.useState({
    status: "starting",
    done: 0,
    total: 0,
    percent: 0,
    error: "",
  });

  react.useEffect(() => {
    let active = true;
    const poll = async () => {
      try {
        const data = await fetchJSON(`/progress/${id}`);
        if (active) setInfo(data);
        if (active && data.status !== "completed" && data.status !== "failed") {
          setTimeout(poll, 2000);
        }
      } catch {
        if (active) setTimeout(poll, 4000);
      }
    };
    poll();
    return () => {
      active = false;
    };
  }, [id]);

  const statusLabel =
    {
      starting: "Starting\u2026",
      downloading:
        info.total > 0
          ? `${info.done} / ${info.total} tracks`
          : "Downloading\u2026",
      completed: "Completed \u2713",
      failed: "Failed",
    }[info.status] || info.status;

  const color =
    info.status === "completed"
      ? "#1DB954"
      : info.status === "failed"
        ? "#e91429"
        : "#b3b3b3";

  return react.createElement(
    "div",
    {
      style: {
        background: "rgba(255,255,255,.07)",
        borderRadius: 8,
        padding: "12px 16px",
        marginBottom: 10,
      },
    },
    react.createElement(
      "div",
      {
        style: {
          display: "flex",
          justifyContent: "space-between",
          fontSize: 13,
        },
      },
      react.createElement(
        "span",
        { style: { color: "#fff" } },
        `Download #${id}`,
      ),
      react.createElement("span", { style: { color } }, statusLabel),
    ),
    info.status === "downloading" &&
      info.total > 0 &&
      react.createElement(ProgressBar, { percent: info.percent }),
    info.status === "failed" &&
      info.error &&
      react.createElement(
        "p",
        { style: { color: "#e91429", fontSize: 12, marginTop: 6 } },
        info.error,
      ),
  );
}

// ── Main page ──────────────────────────────────────────────────────────────

function SettingsPage() {
  const [config, setConfig] = react.useState(null);
  const [online, setOnline] = react.useState(false);
  const [saving, setSaving] = react.useState(false);
  const [downloads, setDownloads] = react.useState([]);
  const [installing, setInstalling] = react.useState(false);

  const loadConfig = react.useCallback(async () => {
    try {
      const data = await fetchJSON("/config");
      setConfig(data);
      setOnline(true);
    } catch {
      setOnline(false);
    }
  }, []);

  const loadDownloads = react.useCallback(async () => {
    try {
      const data = await fetchJSON("/status");
      setDownloads(data.downloads || []);
    } catch {}
  }, []);

  // Poll server every 5s
  react.useEffect(() => {
    loadConfig();
    loadDownloads();
    const id = setInterval(() => {
      loadConfig();
      loadDownloads();
    }, 5000);
    return () => clearInterval(id);
  }, []);

  const handleSave = async () => {
    setSaving(true);
    try {
      await fetch(`${API_URL}/save-config`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          path: config.download_path,
          quality: config.quality,
          engine: config.engine,
        }),
      });
      Spicetify.showNotification("Settings saved!");
    } catch {
      Spicetify.showNotification(
        "Failed to save \u2014 is the server running?",
        true,
      );
    }
    setSaving(false);
  };

  const handleInstallDeps = async () => {
    setInstalling(true);
    Spicetify.showNotification("Installing dependencies\u2026");
    try {
      const res = await fetch(`${API_URL}/install-deps`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ engine: "all" }),
      });
      const data = await res.json();
      if (data.spotdl && data.ytdlp && data.ffmpeg) {
        Spicetify.showNotification("All dependencies installed!");
      } else {
        Spicetify.showNotification(
          data.error || "Some dependencies could not be installed.",
          true,
        );
      }
      loadConfig();
    } catch {
      Spicetify.showNotification("Failed to install dependencies.", true);
    }
    setInstalling(false);
  };

  const sect = (...children) =>
    react.createElement("div", { className: "sd-section" }, ...children);
  const label = (text) => react.createElement("h3", null, text);

  const anyDepsMissing =
    config &&
    (!config.spotdl_installed ||
      !config.ytdlp_installed ||
      !config.ffmpeg_installed);

  return react.createElement(
    "div",
    { className: "sd-wrap" },

    // Header
    react.createElement(
      "div",
      { className: "sd-header" },
      react.createElement("h1", null, "Spicetify Downloader"),
      react.createElement(StatusBadge, { online }),
    ),

    // "No API keys needed" badge
    online &&
      react.createElement(
        "div",
        {
          style: {
            display: "inline-flex",
            alignItems: "center",
            gap: 6,
            padding: "4px 12px",
            borderRadius: 16,
            fontSize: 12,
            fontWeight: 600,
            background: "rgba(29,185,84,.1)",
            color: "#1DB954",
            marginBottom: 16,
          },
        },
        "\u2713 No API keys required \u2014 works out of the box",
      ),

    // Dependency badges (when online)
    online &&
      config &&
      react.createElement(
        "div",
        {
          style: {
            display: "flex",
            gap: 16,
            marginBottom: 16,
            flexWrap: "wrap",
            alignItems: "center",
          },
        },
        react.createElement(DepsBadge, {
          label: "SpotDL",
          ok: config.spotdl_installed,
        }),
        react.createElement(DepsBadge, {
          label: "yt-dlp",
          ok: config.ytdlp_installed,
        }),
        react.createElement(DepsBadge, {
          label: "FFmpeg",
          ok: config.ffmpeg_installed,
        }),
        anyDepsMissing &&
          react.createElement(
            "button",
            {
              className: "sd-btn-secondary",
              onClick: handleInstallDeps,
              disabled: installing,
              style: { marginLeft: 8, padding: "4px 12px", fontSize: 12 },
            },
            installing ? "Installing\u2026" : "Install missing",
          ),
      ),

    // Offline notice
    !online &&
      sect(
        react.createElement(
          "div",
          { className: "sd-alert" },
          react.createElement(
            "p",
            { style: { fontWeight: 600, marginBottom: 6 } },
            "The background server is not running.",
          ),
          react.createElement(
            "p",
            null,
            "Run the installer command or ",
            react.createElement("code", null, "install.bat"),
            " to start it.",
          ),
          react.createElement(
            "button",
            { className: "sd-btn-secondary", onClick: loadConfig },
            "Retry connection",
          ),
        ),
      ),

    // Active downloads
    downloads.length > 0 &&
      sect(
        label("Active Downloads"),
        ...downloads.map((id) =>
          react.createElement(DownloadCard, { key: id, id }),
        ),
      ),

    // Settings (only when online)
    online &&
      config &&
      react.createElement(
        react.Fragment,
        null,

        // Download engine selector
        sect(
          label("Download Engine"),
          react.createElement(
            "select",
            {
              className: "sd-select",
              value: config.engine || "auto",
              onChange: (e) => setConfig({ ...config, engine: e.target.value }),
            },
            react.createElement(
              "option",
              { value: "auto" },
              "Auto — SpotDL first, then yt-dlp fallback (recommended)",
            ),
            react.createElement(
              "option",
              { value: "spotdl" },
              "SpotDL \u2014 Best quality, auto YouTube matching",
            ),
            react.createElement(
              "option",
              { value: "ytdlp" },
              "yt-dlp \u2014 Direct YouTube search & download",
            ),
          ),
          react.createElement(
            "p",
            { className: "sd-hint" },
            config.engine === "auto"
              ? "Auto mode tries SpotDL first, then yt-dlp. If yt-dlp has partial failures, SpotDL is tried again."
              : config.engine === "ytdlp"
              ? "yt-dlp searches YouTube for each track and downloads as MP3. If it fails, spotdl is used as fallback."
              : "SpotDL matches Spotify tracks to YouTube and downloads with metadata. If it fails, yt-dlp is used as fallback.",
          ),
        ),

        sect(
          label("Download Folder"),
          react.createElement("input", {
            className: "sd-input",
            type: "text",
            value: config.download_path || "",
            onChange: (e) =>
              setConfig({ ...config, download_path: e.target.value }),
            placeholder: "Path to save music",
          }),
          react.createElement(
            "p",
            { className: "sd-hint" },
            "Music files will be saved here. To play them in Spotify, add this folder under Settings \u2192 Local Files.",
          ),
        ),

        sect(
          label("Audio Quality"),
          react.createElement(
            "select",
            {
              className: "sd-select",
              value: config.quality || "320",
              onChange: (e) =>
                setConfig({ ...config, quality: e.target.value }),
            },
            react.createElement(
              "option",
              { value: "128" },
              "128 kbps \u2014 Low (smaller files)",
            ),
            react.createElement(
              "option",
              { value: "160" },
              "160 kbps \u2014 Medium",
            ),
            react.createElement(
              "option",
              { value: "320" },
              "320 kbps \u2014 High quality (recommended)",
            ),
          ),
        ),

        sect(
          react.createElement(
            "button",
            {
              className: "sd-btn",
              onClick: handleSave,
              disabled: saving,
            },
            saving ? "Saving\u2026" : "Save Settings",
          ),
        ),
      ),

    // How to use
    sect(
      label("How to Use"),
      react.createElement(
        "ol",
        { className: "sd-ol" },
        react.createElement(
          "li",
          null,
          "Open any playlist, album, or track in Spotify.",
        ),
        react.createElement(
          "li",
          null,
          "Right-click \u2192 ",
          react.createElement("strong", null, "Download for Offline"),
          ", or press ",
          react.createElement("strong", null, "Ctrl+Shift+D"),
          ", or click Spotify's ",
          react.createElement("strong", null, "Download"),
          " button.",
        ),
        react.createElement("li", null, "Pick your preferred audio quality."),
        react.createElement(
          "li",
          null,
          "The download runs in the background \u2014 progress appears here and as notifications.",
        ),
        react.createElement(
          "li",
          null,
          "To play downloaded music offline in Spotify, go to ",
          react.createElement("strong", null, "Settings \u2192 Local Files"),
          " and add your download folder.",
        ),
      ),
    ),

    // Quick install section
    sect(
      label("Quick Install (One-Liner)"),
      react.createElement(
        "p",
        { className: "sd-hint", style: { marginBottom: 8 } },
        "Share this command with friends to install:",
      ),
      react.createElement(
        "div",
        {
          style: {
            background: "#121212",
            padding: "10px 14px",
            borderRadius: 6,
            fontFamily: "monospace",
            fontSize: 12,
            color: "#1DB954",
            wordBreak: "break-all",
            cursor: "pointer",
            border: "1px solid #3e3e3e",
          },
          onClick: () => {
            const cmd =
              "iwr -useb https://raw.githubusercontent.com/diorhc/spicetify-downloader/main/install.ps1 | iex";
            if (navigator.clipboard) {
              navigator.clipboard.writeText(cmd);
              Spicetify.showNotification("Copied to clipboard!");
            }
          },
          title: "Click to copy",
        },
        "iwr -useb https://raw.githubusercontent.com/diorhc/spicetify-downloader/main/install.ps1 | iex",
      ),
    ),
  );
}

// ── Styles ─────────────────────────────────────────────────────────────────

const CSS = `
  .sd-wrap { padding: 32px; max-width: 620px; color: #fff; font-family: inherit; }
  .sd-header { display: flex; align-items: center; gap: 16px; margin-bottom: 12px; flex-wrap: wrap; }
  .sd-header h1 { font-size: 26px; font-weight: 700; color: #1DB954; margin: 0; }
  .sd-section {
    margin-bottom: 20px; padding: 18px 20px;
    background: rgba(255,255,255,.07);
    border-radius: 10px;
  }
  .sd-section h3 {
    font-size: 13px; font-weight: 600; text-transform: uppercase;
    letter-spacing: .08em; color: #b3b3b3; margin: 0 0 12px;
  }
  .sd-input, .sd-select {
    width: 100%; padding: 10px 12px; border: 1px solid #3e3e3e;
    border-radius: 6px; background: #121212; color: #fff;
    font-size: 14px; box-sizing: border-box;
  }
  .sd-input:focus, .sd-select:focus { outline: none; border-color: #1DB954; }
  .sd-hint { font-size: 12px; color: #727272; margin: 8px 0 0; }
  .sd-btn {
    width: 100%; padding: 12px; background: #1DB954; color: #000;
    border: none; border-radius: 24px; font-size: 14px;
    font-weight: 700; cursor: pointer; transition: background .15s;
  }
  .sd-btn:hover:not(:disabled) { background: #1ed760; }
  .sd-btn:disabled { opacity: .5; cursor: default; }
  .sd-btn-secondary {
    margin-top: 12px; padding: 8px 18px; background: transparent;
    color: #fff; border: 1px solid #fff; border-radius: 20px;
    font-size: 13px; cursor: pointer; transition: background .15s;
  }
  .sd-btn-secondary:hover { background: rgba(255,255,255,.1); }
  .sd-alert { padding: 4px 0; }
  .sd-alert p { font-size: 14px; color: #b3b3b3; margin: 0 0 4px; line-height: 1.5; }
  .sd-alert code { background: #282828; padding: 1px 6px; border-radius: 4px; font-size: 13px; color: #fff; }
  .sd-ol { padding-left: 18px; margin: 0; color: #b3b3b3; font-size: 14px; }
  .sd-ol li { margin-bottom: 8px; line-height: 1.5; }
`;

// ── CSS injection ──────────────────────────────────────────────────────────

let _cssInjected = false;
function injectCSS() {
  if (_cssInjected) return;
  _cssInjected = true;
  const el = document.createElement("style");
  el.textContent = CSS;
  document.head.appendChild(el);
}

// ── Spicetify entry point ──────────────────────────────────────────────────

function render() {
  injectCSS();
  return react.createElement(SettingsPage);
}
