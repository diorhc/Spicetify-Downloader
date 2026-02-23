(function SpicetifyDownloader() {
  "use strict";

  const API_URL = "http://localhost:8765";
  let isDownloading = false;

  const QUALITY_OPTIONS = [
    { value: "128", label: "128 kbps - Low (smaller files)" },
    { value: "160", label: "160 kbps - Medium" },
    { value: "320", label: "320 kbps - High (recommended)" },
  ];

  // Get the Spotify web URL for the currently viewed page.
  // Uses Spicetify.Platform.History (correct desktop API) instead of
  // window.location.href which does not work in the desktop client.
  function getCurrentPageUrl() {
    const pathname =
      Spicetify?.Platform?.History?.location?.pathname || "";

    const playlistMatch = pathname.match(/^\/playlist\/([A-Za-z0-9]+)/);
    if (playlistMatch) {
      return {
        url: "https://open.spotify.com/playlist/" + playlistMatch[1],
        type: "playlist",
      };
    }

    const albumMatch = pathname.match(/^\/album\/([A-Za-z0-9]+)/);
    if (albumMatch) {
      return {
        url: "https://open.spotify.com/album/" + albumMatch[1],
        type: "album",
      };
    }

    // Fallback: use the URI of whatever is currently playing
    const contextUri = Spicetify?.Player?.data?.context_uri || "";
    const uriMatch = contextUri.match(/spotify:(playlist|album):([A-Za-z0-9]+)/);
    if (uriMatch) {
      return {
        url: "https://open.spotify.com/" + uriMatch[1] + "/" + uriMatch[2],
        type: uriMatch[1],
      };
    }

    return null;
  }

  function uriToUrl(uri) {
    const m = uri.match(/spotify:(playlist|album):([A-Za-z0-9]+)/);
    if (!m) return null;
    return { url: "https://open.spotify.com/" + m[1] + "/" + m[2], type: m[1] };
  }

  // Poll backend for progress updates
  function pollProgress(downloadId) {
    const interval = setInterval(async () => {
      try {
        const res = await fetch(API_URL + "/progress/" + downloadId);
        const data = await res.json();

        if (data.status === "downloading") {
          const msg =
            data.total > 0
              ? "Downloading... " + data.done + "/" + data.total + " tracks (" + data.percent + "%)"
              : "Downloading... please wait";
          Spicetify.showNotification(msg);
        } else if (data.status === "completed") {
          clearInterval(interval);
          isDownloading = false;
          Spicetify.showNotification("Download complete! Check your Music folder.");
        } else if (data.status === "failed") {
          clearInterval(interval);
          isDownloading = false;
          Spicetify.showNotification(
            data.error ? "Download failed: " + data.error : "Download failed.",
            true,
          );
        }
      } catch (_) {
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
    Spicetify.showNotification("Starting download at " + quality + " kbps...");

    try {
      const res = await fetch(API_URL + "/download", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url: url, quality: quality }),
      });
      const data = await res.json();

      if (data.status === "started") {
        pollProgress(data.download_id);
      } else {
        Spicetify.showNotification(data.error || "Failed to start download.", true);
        isDownloading = false;
      }
    } catch (_) {
      Spicetify.showNotification(
        "Cannot reach server. Is it running? Re-run install.bat.",
        true,
      );
      isDownloading = false;
    }
  }

  // Quality selection modal
  function showQualityModal(spotifyUrl, name) {
    const wrap = document.createElement("div");
    wrap.style.cssText = "padding:24px;text-align:center;min-width:260px";

    const title = document.createElement("h2");
    title.textContent = "Choose Quality";
    title.style.cssText = "margin:0 0 8px;color:#fff;font-size:18px;font-weight:700";
    wrap.appendChild(title);

    if (name) {
      const sub = document.createElement("p");
      sub.textContent = name;
      sub.style.cssText = "color:#b3b3b3;margin:0 0 20px;font-size:13px";
      wrap.appendChild(sub);
    }

    const btns = document.createElement("div");
    btns.style.cssText = "display:flex;flex-direction:column;gap:10px;margin-top:20px";

    QUALITY_OPTIONS.forEach(function(opt) {
      const btn = document.createElement("button");
      btn.textContent = opt.label;
      btn.style.cssText = "padding:12px 24px;background:#282828;color:#fff;border:1px solid #3e3e3e;border-radius:24px;cursor:pointer;font-size:14px;transition:all .15s";
      btn.onmouseenter = function() {
        btn.style.background = "#1DB954";
        btn.style.borderColor = "#1DB954";
        btn.style.color = "#000";
      };
      btn.onmouseleave = function() {
        btn.style.background = "#282828";
        btn.style.borderColor = "#3e3e3e";
        btn.style.color = "#fff";
      };
      btn.onclick = function() {
        Spicetify.PopupModal.hide();
        startDownload(spotifyUrl, opt.value);
      };
      btns.appendChild(btn);
    });

    wrap.appendChild(btns);

    Spicetify.PopupModal.display({
      title: "Spicetify Downloader",
      content: wrap,
      isLarge: false,
    });
  }

  // Right-click context menu on playlists and albums
  function registerContextMenu() {
    if (!Spicetify.ContextMenu) return;

    var shouldShow = function(uris) {
      var u = uris[0] || "";
      return u.startsWith("spotify:playlist:") || u.startsWith("spotify:album:");
    };

    var onSelect = function(uris) {
      var data = uriToUrl(uris[0]);
      if (!data) {
        Spicetify.showNotification("Cannot download this item.", true);
        return;
      }
      showQualityModal(data.url, "");
    };

    new Spicetify.ContextMenu.Item(
      "Download with SpotDL",
      onSelect,
      shouldShow,
      "download",
    ).register();
  }

  // Topbar download button (Ctrl+Shift+D shortcut always works even without topbar)
  function addTopbarButton() {
    if (!Spicetify.Topbar || !Spicetify.Topbar.Button) return;

    var ICON = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="16" height="16"><path fill="currentColor" d="M12 16l-5-5 1.41-1.41L11 13.17V4h2v9.17l2.59-2.58L17 11l-5 5zm-7 3h14v2H5v-2z"/></svg>';

    new Spicetify.Topbar.Button("Download", ICON, function() {
      var data = getCurrentPageUrl();
      if (!data) {
        Spicetify.showNotification(
          "Navigate to a playlist or album, then click Download.",
          true,
        );
        return;
      }
      showQualityModal(data.url, "");
    });
  }

  // Keyboard shortcut: Ctrl+Shift+D
  function registerKeyboard() {
    document.addEventListener("keydown", function(e) {
      if (e.ctrlKey && e.shiftKey && e.key === "D") {
        e.preventDefault();
        var data = getCurrentPageUrl();
        if (!data) {
          Spicetify.showNotification("Navigate to a playlist or album first.", true);
          return;
        }
        showQualityModal(data.url, "");
      }
    });
  }

  function init() {
    registerContextMenu();
    addTopbarButton();
    registerKeyboard();
    console.info("[SpicetifyDownloader] Extension loaded. Server:", API_URL);
  }

  // Wait for Spicetify APIs to be ready before running
  function waitForSpicetify() {
    if (
      typeof Spicetify !== "undefined" &&
      Spicetify.Platform &&
      Spicetify.showNotification
    ) {
      init();
    } else {
      setTimeout(waitForSpicetify, 200);
    }
  }

  waitForSpicetify();
})();