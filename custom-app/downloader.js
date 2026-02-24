(function SpicetifyDownloader() {
  "use strict";

  var API_URL = "http://localhost:8765";
  var isDownloading = false;
  var serverOnline = false;

  var QUALITY_OPTIONS = [
    { value: "128", label: "128 kbps \u2014 Low (smaller files)" },
    { value: "160", label: "160 kbps \u2014 Medium" },
    { value: "320", label: "320 kbps \u2014 High (recommended)" },
  ];

  // ── Helpers ──────────────────────────────────────────────────────────────

  function debounce(fn, ms) {
    var t;
    return function () {
      clearTimeout(t);
      t = setTimeout(fn, ms);
    };
  }

  function uriToUrl(uri) {
    if (!uri) return null;
    var m = uri.match(/spotify:(playlist|album|track):([A-Za-z0-9]+)/);
    if (!m) return null;
    return { url: "https://open.spotify.com/" + m[1] + "/" + m[2], type: m[1] };
  }

  function getCurrentPageUrl() {
    var pathname = "";
    try {
      pathname = Spicetify.Platform.History.location.pathname || "";
    } catch (_) {}

    var m;

    m = pathname.match(/^\/playlist\/([A-Za-z0-9]+)/);
    if (m)
      return {
        url: "https://open.spotify.com/playlist/" + m[1],
        type: "playlist",
      };

    m = pathname.match(/^\/album\/([A-Za-z0-9]+)/);
    if (m)
      return { url: "https://open.spotify.com/album/" + m[1], type: "album" };

    m = pathname.match(/^\/track\/([A-Za-z0-9]+)/);
    if (m)
      return { url: "https://open.spotify.com/track/" + m[1], type: "track" };

    // Fallback: currently playing context
    try {
      var contextUri = Spicetify.Player.data.context_uri || "";
      var ctx = uriToUrl(contextUri);
      if (ctx) return ctx;
    } catch (_) {}

    return null;
  }

  function getCurrentTrackUrl() {
    try {
      var player = Spicetify.Player.data;
      var trackUri =
        (player.item && player.item.uri) ||
        (player.track && player.track.uri) ||
        "";
      return uriToUrl(trackUri);
    } catch (_) {
      return null;
    }
  }

  function getCurrentTrackName() {
    try {
      var player = Spicetify.Player.data;
      return (
        (player.item && player.item.name) ||
        (player.track && player.track.name) ||
        ""
      );
    } catch (_) {
      return "";
    }
  }

  // ── Server health check ──────────────────────────────────────────────────

  function checkServerHealth() {
    fetch(API_URL + "/health", { method: "GET" })
      .then(function (res) {
        if (res.ok) {
          serverOnline = true;
          console.info("[SpicetifyDownloader] Server is online.");
        } else {
          serverOnline = false;
        }
      })
      .catch(function () {
        serverOnline = false;
        console.warn("[SpicetifyDownloader] Server is offline.");
      });
  }

  // ── Progress polling ─────────────────────────────────────────────────────

  function pollProgress(downloadId) {
    var interval = setInterval(function () {
      fetch(API_URL + "/progress/" + downloadId)
        .then(function (res) {
          return res.json();
        })
        .then(function (data) {
          if (data.status === "downloading") {
            var msg =
              data.total > 0
                ? "Downloading... " +
                  data.done +
                  "/" +
                  data.total +
                  " (" +
                  data.percent +
                  "%)"
                : "Downloading... please wait";
            Spicetify.showNotification(msg);
          } else if (data.status === "completed") {
            clearInterval(interval);
            isDownloading = false;
            Spicetify.showNotification(
              "Download complete! Files saved to your Music folder.",
            );
          } else if (data.status === "failed") {
            clearInterval(interval);
            isDownloading = false;
            Spicetify.showNotification(data.error || "Download failed.", true);
          }
        })
        .catch(function () {
          /* server temporarily unreachable, keep polling */
        });
    }, 2500);
  }

  // ── Download trigger ─────────────────────────────────────────────────────

  function startDownload(url, quality) {
    if (isDownloading) {
      Spicetify.showNotification("A download is already in progress!", true);
      return;
    }
    isDownloading = true;
    Spicetify.showNotification("Starting download at " + quality + " kbps...");

    fetch(API_URL + "/download", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: url, quality: quality }),
    })
      .then(function (res) {
        return res.json();
      })
      .then(function (data) {
        if (data.status === "started") {
          pollProgress(data.download_id);
        } else {
          Spicetify.showNotification(
            data.error || "Failed to start download.",
            true,
          );
          isDownloading = false;
        }
      })
      .catch(function () {
        Spicetify.showNotification(
          "Cannot reach the download server.\nRe-run install.bat to fix it.",
          true,
        );
        isDownloading = false;
      });
  }

  // ── Quality modal ────────────────────────────────────────────────────────

  function showQualityModal(spotifyUrl, subtitle) {
    var wrap = document.createElement("div");
    wrap.style.cssText = "padding:24px;text-align:center;min-width:280px";

    var title = document.createElement("h2");
    title.textContent = "Choose Quality";
    title.style.cssText =
      "margin:0 0 6px;color:#fff;font-size:18px;font-weight:700";
    wrap.appendChild(title);

    if (subtitle) {
      var sub = document.createElement("p");
      sub.textContent = subtitle;
      sub.style.cssText =
        "color:#b3b3b3;margin:0 0 16px;font-size:13px;word-break:break-word";
      wrap.appendChild(sub);
    }

    var btns = document.createElement("div");
    btns.style.cssText =
      "display:flex;flex-direction:column;gap:10px;margin-top:16px";

    QUALITY_OPTIONS.forEach(function (opt) {
      var btn = document.createElement("button");
      btn.textContent = opt.label;
      btn.style.cssText =
        "padding:12px 24px;background:#282828;color:#fff;border:1px solid #3e3e3e;" +
        "border-radius:24px;cursor:pointer;font-size:14px;transition:all .15s";
      btn.onmouseenter = function () {
        btn.style.background = "#1DB954";
        btn.style.borderColor = "#1DB954";
        btn.style.color = "#000";
      };
      btn.onmouseleave = function () {
        btn.style.background = "#282828";
        btn.style.borderColor = "#3e3e3e";
        btn.style.color = "#fff";
      };
      btn.onclick = function () {
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

  // ── Smart download ───────────────────────────────────────────────────────

  function triggerSmartDownload() {
    // Check server first
    if (!serverOnline) {
      // Quick recheck
      fetch(API_URL + "/health")
        .then(function (res) {
          if (res.ok) {
            serverOnline = true;
            doSmartDownload();
          } else {
            Spicetify.showNotification(
              "Download server is offline. Re-run install.bat to start it.",
              true,
            );
          }
        })
        .catch(function () {
          Spicetify.showNotification(
            "Download server is offline. Re-run install.bat to start it.",
            true,
          );
        });
      return;
    }
    doSmartDownload();
  }

  function doSmartDownload() {
    var data = getCurrentPageUrl();
    if (!data) data = getCurrentTrackUrl();

    if (!data) {
      Spicetify.showNotification(
        "Navigate to a playlist, album, or track first.",
        true,
      );
      return;
    }

    var subtitle = "";
    if (data.type === "track") {
      var name = getCurrentTrackName();
      subtitle = name ? "Track: " + name : "Current track";
    } else if (data.type === "playlist") {
      subtitle = "Current playlist";
    } else if (data.type === "album") {
      subtitle = "Current album";
    }

    showQualityModal(data.url, subtitle);
  }

  // ── Intercept native download buttons ────────────────────────────────────

  var NATIVE_DOWNLOAD_SELECTORS = [
    '[data-testid="download-button"]',
    'button[aria-label="Download"]',
    'button[aria-label="download"]',
    'button[aria-label="\u0421\u043a\u0430\u0447\u0430\u0442\u044c"]',
    'button[aria-label="Herunterladen"]',
    'button[aria-label="T\u00e9l\u00e9charger"]',
    'button[aria-label="Descargar"]',
    'button[aria-label="Scarica"]',
    'button[aria-label="Pobierz"]',
  ];

  function patchNativeDownloadButton(btn) {
    if (btn.dataset.sdPatched) return;
    btn.dataset.sdPatched = "1";
    btn.addEventListener(
      "click",
      function (e) {
        e.preventDefault();
        e.stopImmediatePropagation();
        triggerSmartDownload();
      },
      true,
    );
  }

  function patchAllNativeButtons() {
    NATIVE_DOWNLOAD_SELECTORS.forEach(function (sel) {
      try {
        document.querySelectorAll(sel).forEach(patchNativeDownloadButton);
      } catch (_) {}
    });
  }

  function watchForNativeDownloadButtons() {
    patchAllNativeButtons();
    var observer = new MutationObserver(debounce(patchAllNativeButtons, 250));
    observer.observe(document.body, { childList: true, subtree: true });
  }

  // ── Right-click context menu ─────────────────────────────────────────────

  function registerContextMenu() {
    if (!Spicetify.ContextMenu) return;

    var shouldShow = function (uris) {
      var u = uris[0] || "";
      return (
        u.startsWith("spotify:playlist:") ||
        u.startsWith("spotify:album:") ||
        u.startsWith("spotify:track:")
      );
    };

    var onSelect = function (uris) {
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

  // ── Topbar download button ───────────────────────────────────────────────

  function addTopbarButton() {
    if (!Spicetify.Topbar || !Spicetify.Topbar.Button) return;

    var ICON =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="16" height="16">' +
      '<path fill="currentColor" d="M12 16l-5-5 1.41-1.41L11 13.17V4h2v9.17l2.59-2.58L17 11l-5 5zm-7 3h14v2H5v-2z"/>' +
      "</svg>";

    new Spicetify.Topbar.Button("Download", ICON, function () {
      triggerSmartDownload();
    });
  }

  // ── Keyboard shortcut: Ctrl+Shift+D ──────────────────────────────────────

  function registerKeyboard() {
    document.addEventListener("keydown", function (e) {
      if (e.ctrlKey && e.shiftKey && e.key === "D") {
        e.preventDefault();
        triggerSmartDownload();
      }
    });
  }

  // ── Init ─────────────────────────────────────────────────────────────────

  function init() {
    // Check server health on load
    checkServerHealth();
    // Re-check every 30 seconds
    setInterval(checkServerHealth, 30000);

    registerContextMenu();
    addTopbarButton();
    registerKeyboard();
    watchForNativeDownloadButtons();
    console.info("[SpicetifyDownloader] Extension loaded. Server:", API_URL);
  }

  function waitForSpicetify() {
    if (
      typeof Spicetify !== "undefined" &&
      Spicetify.Platform &&
      Spicetify.showNotification
    ) {
      init();
    } else {
      setTimeout(waitForSpicetify, 300);
    }
  }

  waitForSpicetify();
})();
