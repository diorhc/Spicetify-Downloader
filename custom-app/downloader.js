(function SpicetifyDownloader() {
  const API_URL = "http://localhost:8765";

  let isDownloading = false;
  let injectedButtons = new Set();

  const QUALITY_OPTIONS = [
    { value: "128", label: "128 kbps (Low)" },
    { value: "160", label: "160 kbps (Medium)" },
    { value: "320", label: "320 kbps (High)" },
  ];

  async function getConfig() {
    try {
      const res = await fetch(`${API_URL}/config`);
      return await res.json();
    } catch {
      return { quality: "320" };
    }
  }

  async function pollProgress(downloadId) {
    const interval = setInterval(async () => {
      try {
        const res = await fetch(`${API_URL}/progress/${downloadId}`);
        const data = await res.json();

        if (data.status === "downloading") {
          if (data.total > 0) {
            Spicetify.showNotification(
              `Downloading… ${data.done}/${data.total} tracks (${data.percent}%)`,
            );
          } else {
            Spicetify.showNotification("Downloading… please wait");
          }
        } else if (data.status === "completed") {
          clearInterval(interval);
          isDownloading = false;
          Spicetify.showNotification(
            "✓ Download complete! Check your Music folder.",
          );
        } else if (data.status === "failed") {
          clearInterval(interval);
          isDownloading = false;
          Spicetify.showNotification(
            data.error ? `Download failed: ${data.error}` : "Download failed.",
            true,
          );
        }
      } catch {
        // server temporarily unreachable, keep polling
      }
    }, 3000);
  }

  async function startDownload(url, quality) {
    if (isDownloading) {
      Spicetify.showNotification("A download is already in progress!", true);
      return;
    }

    isDownloading = true;
    Spicetify.showNotification("Starting download…");

    try {
      const res = await fetch(`${API_URL}/download`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url, quality }),
      });

      const data = await res.json();

      if (data.status === "started") {
        Spicetify.showNotification(`Download started at ${quality} kbps`);
        pollProgress(data.download_id);
      } else {
        Spicetify.showNotification(
          data.error || "Failed to start download.",
          true,
        );
        isDownloading = false;
      }
    } catch {
      Spicetify.showNotification(
        "Cannot reach the server. Make sure Spicetify Downloader is running.",
        true,
      );
      isDownloading = false;
    }
  }

  function createQualityModal(spotifyUrl, name) {
    const modalContent = document.createElement("div");
    modalContent.style.cssText = `
            padding: 20px;
            text-align: center;
        `;

    const title = document.createElement("h2");
    title.textContent = "Download Quality";
    title.style.cssText = "margin-bottom: 10px; color: #fff;";
    modalContent.appendChild(title);

    const subtitle = document.createElement("p");
    subtitle.textContent = name || "Selected tracks";
    subtitle.style.cssText = "color: #b3b3b3; margin-bottom: 20px;";
    modalContent.appendChild(subtitle);

    const buttonsDiv = document.createElement("div");
    buttonsDiv.style.cssText =
      "display: flex; flex-direction: column; gap: 10px;";

    QUALITY_OPTIONS.forEach((opt) => {
      const btn = document.createElement("button");
      btn.textContent = opt.label;
      btn.style.cssText = `
                padding: 12px 24px;
                background: #282828;
                color: #fff;
                border: none;
                border-radius: 20px;
                cursor: pointer;
                font-size: 14px;
                transition: background 0.2s;
            `;
      btn.onmouseenter = () => (btn.style.background = "#383838");
      btn.onmouseleave = () => (btn.style.background = "#282828");
      btn.onclick = () => {
        Spicetify.PopupModal.hide();
        startDownload(spotifyUrl, opt.value);
      };
      buttonsDiv.appendChild(btn);
    });

    modalContent.appendChild(buttonsDiv);

    Spicetify.PopupModal.display({
      title: "Spicetify Downloader",
      content: modalContent,
      isLarge: false,
    });
  }

  function getSpotifyUrlFromPage() {
    const url = window.location.href;

    const playlistMatch = url.match(/playlist\/([a-zA-Z0-9]+)/);
    if (playlistMatch) {
      return {
        url: `https://open.spotify.com/playlist/${playlistMatch[1]}`,
        name: getPlaylistName(),
        type: "playlist",
      };
    }

    const albumMatch = url.match(/album\/([a-zA-Z0-9]+)/);
    if (albumMatch) {
      return {
        url: `https://open.spotify.com/album/${albumMatch[1]}`,
        name: getAlbumName(),
        type: "album",
      };
    }

    return null;
  }

  function getPlaylistName() {
    const selectors = [
      '[data-testid="playlist-details"] h1',
      ".main-view-container__scroll-node h1",
      ".playlist-details h1",
      "header h1",
    ];

    for (const sel of selectors) {
      const el = document.querySelector(sel);
      if (el) return el.textContent.trim();
    }

    return "Playlist";
  }

  function getAlbumName() {
    const selectors = [
      '[data-testid="album-details"] h1',
      ".main-view-container__scroll-node h1",
      "header h1",
    ];

    for (const sel of selectors) {
      const el = document.querySelector(sel);
      if (el) return el.textContent.trim();
    }

    return "Album";
  }

  function findDownloadButtons() {
    const buttons = [];

    const allButtons = document.querySelectorAll("button");
    allButtons.forEach((btn) => {
      if (injectedButtons.has(btn)) return;

      const ariaLabel = btn.getAttribute("aria-label");
      const svg = btn.querySelector("svg");

      if (!svg) return;

      const isDownloadBtn =
        ariaLabel &&
        ariaLabel.toLowerCase().includes("download") &&
        !ariaLabel.toLowerCase().includes("make available offline");

      if (isDownloadBtn) {
        buttons.push(btn);
      }
    });

    return buttons;
  }

  function injectDownloadHandlers() {
    const downloadButtons = findDownloadButtons();

    downloadButtons.forEach((btn) => {
      injectedButtons.add(btn);

      btn.addEventListener("click", async (e) => {
        e.preventDefault();
        e.stopPropagation();

        const spotifyData = getSpotifyUrlFromPage();

        if (spotifyData) {
          createQualityModal(spotifyData.url, spotifyData.name);
        } else {
          Spicetify.showNotification(
            "Unable to get URL. Navigate to a playlist or album.",
            true,
          );
        }
      });
    });
  }

  function init() {
    setInterval(injectDownloadHandlers, 2000);
    injectDownloadHandlers();
    console.log("Spicetify Downloader Extension loaded");
  }

  if (!Spicetify.Player || !Spicetify.Platform) {
    setTimeout(init, 1000);
    return;
  }

  init();
})();
