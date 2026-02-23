(function () {
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
    });

    react.useEffect(() => {
      let active = true;
      const poll = async () => {
        try {
          const data = await fetchJSON(`/progress/${id}`);
          if (active) setInfo(data);
          if (
            active &&
            data.status !== "completed" &&
            data.status !== "failed"
          ) {
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
        starting: "Starting…",
        downloading:
          info.total > 0
            ? `${info.done} / ${info.total} tracks`
            : "Downloading…",
        completed: "Completed ✓",
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

  function SettingsPage() {
    const [config, setConfig] = react.useState(null);
    const [online, setOnline] = react.useState(false);
    const [saving, setSaving] = react.useState(false);
    const [downloads, setDownloads] = react.useState([]);

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

    // Poll server status every 5 s
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
          }),
        });
        Spicetify.showNotification("Settings saved!");
      } catch {
        Spicetify.showNotification(
          "Failed to save — is the server running?",
          true,
        );
      }
      setSaving(false);
    };

    const sect = (children) =>
      react.createElement("div", { className: "sd-section" }, ...children);
    const label = (text) => react.createElement("h3", null, text);

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

      // Offline notice
      !online &&
        sect([
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
              "It should start automatically with Windows. If it does not, re-run ",
              react.createElement("code", null, "install.bat"),
              " to fix auto-start.",
            ),
            react.createElement(
              "button",
              { className: "sd-btn-secondary", onClick: loadConfig },
              "Retry connection",
            ),
          ),
        ]),

      // Active downloads
      downloads.length > 0 &&
        sect([
          label("Active Downloads"),
          ...downloads.map((id) =>
            react.createElement(DownloadCard, { key: id, id }),
          ),
        ]),

      // Settings (only when online)
      online &&
        config &&
        react.createElement(
          react.Fragment,
          null,

          sect([
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
              "Music files will be saved here.",
            ),
          ]),

          sect([
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
                "128 kbps — Low (smaller files)",
              ),
              react.createElement(
                "option",
                { value: "160" },
                "160 kbps — Medium",
              ),
              react.createElement(
                "option",
                { value: "320" },
                "320 kbps — High quality (recommended)",
              ),
            ),
          ]),

          sect([
            react.createElement(
              "button",
              {
                className: "sd-btn",
                onClick: handleSave,
                disabled: saving,
              },
              saving ? "Saving…" : "Save Settings",
            ),
          ]),
        ),

      // How to use
      sect([
        label("How to Use"),
        react.createElement(
          "ol",
          { className: "sd-ol" },
          react.createElement(
            "li",
            null,
            "Open any playlist or album in Spotify.",
          ),
          react.createElement(
            "li",
            null,
            "Click the ",
            react.createElement("strong", null, "Download"),
            " button (⬇) near the play button.",
          ),
          react.createElement("li", null, "Pick your preferred audio quality."),
          react.createElement(
            "li",
            null,
            "The download runs in the background — progress appears here.",
          ),
        ),
      ]),
    );
  }

  // ── Styles ─────────────────────────────────────────────────────────────────

  const CSS = `
        .sd-wrap { padding: 32px; max-width: 620px; color: #fff; font-family: inherit; }
        .sd-header { display: flex; align-items: center; gap: 16px; margin-bottom: 32px; flex-wrap: wrap; }
        .sd-header h1 { font-size: 26px; font-weight: 700; color: #1DB954; margin: 0; }
        .sd-section {
            margin-bottom: 20px; padding: 18px 20px;
            background: rgba(255,255,255,.07);
            border-radius: 10px;
        }
        .sd-section h3 { font-size: 13px; font-weight: 600; text-transform: uppercase;
                         letter-spacing: .08em; color: #b3b3b3; margin: 0 0 12px; }
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

  // ── Mount ──────────────────────────────────────────────────────────────────

  function init() {
    const styleEl = document.createElement("style");
    styleEl.textContent = CSS;
    document.head.appendChild(styleEl);

    const container = document.createElement("div");
    container.id = "spicetify-downloader-app";
    document
      .querySelector(".main-view-container__scroll-node")
      .appendChild(container);

    reactDOM.render(react.createElement(SettingsPage), container);
  }

  function render() {
    if (document.querySelector(".main-view-container__scroll-node")) {
      init();
    } else {
      setTimeout(render, 100);
    }
  }

  render();
})();
