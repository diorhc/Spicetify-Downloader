(function SpicetifyDownloader() {
  "use strict";

  var API_URL = "http://localhost:8765";
  var isDownloading = false;
  var serverOnline = false;
  var activeDownload = null;
  var progressPollTimer = null;
  var rowRenderTimer = null;
  var nativeClickHooked = false;
  var resolvedTracklist = null; // { tracks: [{name, spotify_url}], collectionName: "" }

  // ── OGG Playback Recorder (Soggfy-style) ─────────────────────────
  var _recorder = null;
  var _recChunks = [];
  var _recTrackName = "";
  var _recDownloadPath = "";
  var _captureMode = false; // true while user has enabled capture
  var _capturedCount = 0;

  function _getAudioElement() {
    // Try Spicetify internal reference first
    try {
      if (Spicetify.Player && Spicetify.Player._htmlAudioElement) {
        return Spicetify.Player._htmlAudioElement;
      }
    } catch (_) {}
    // DOM fallback
    return document.querySelector("audio") || null;
  }

  function _stopRecording() {
    if (_recorder && _recorder.state !== "inactive") {
      _recorder.stop();
    }
    _recorder = null;
  }

  function _saveRecording() {
    if (!_recChunks.length || !_recTrackName) return;
    var chunks = _recChunks.slice();
    _recChunks = [];
    var mimeType = chunks[0] && chunks[0].type ? chunks[0].type : "audio/ogg";
    var blob = new Blob(chunks, { type: mimeType });
    if (blob.size < 4096) return; // too small — skip

    var reader = new FileReader();
    reader.onload = function () {
      var b64 = reader.result.split(",")[1] || "";
      fetch(API_URL + "/capture-track", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: _recTrackName,
          data: b64,
          mime_type: mimeType,
          path: _recDownloadPath,
        }),
      })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          if (d.status === "saved") {
            _capturedCount++;
            Spicetify.showNotification(
              "✅ Captured: " + _recTrackName + " (" + Math.round(blob.size / 1024) + " KB)"
            );
          }
        })
        .catch(function () {});
    };
    reader.readAsDataURL(blob);
  }

  function _startRecording(trackName, downloadPath) {
    _stopRecording();
    var audio = _getAudioElement();
    if (!audio) {
      console.warn("[SpicetifyDownloader] No audio element found for recording");
      return false;
    }
    var stream;
    try {
      stream = audio.captureStream ? audio.captureStream()
             : audio.mozCaptureStream ? audio.mozCaptureStream()
             : null;
    } catch (e) {
      console.warn("[SpicetifyDownloader] captureStream failed:", e);
      return false;
    }
    if (!stream) return false;

    var mimeType = "";
    if (typeof MediaRecorder !== "undefined") {
      if (MediaRecorder.isTypeSupported("audio/ogg; codecs=opus")) mimeType = "audio/ogg; codecs=opus";
      else if (MediaRecorder.isTypeSupported("audio/webm; codecs=opus")) mimeType = "audio/webm; codecs=opus";
      else if (MediaRecorder.isTypeSupported("audio/webm")) mimeType = "audio/webm";
    }

    try {
      _recorder = mimeType
        ? new MediaRecorder(stream, { mimeType: mimeType })
        : new MediaRecorder(stream);
    } catch (e) {
      console.warn("[SpicetifyDownloader] MediaRecorder init failed:", e);
      return false;
    }

    _recChunks = [];
    _recTrackName = trackName;
    _recDownloadPath = downloadPath;

    _recorder.ondataavailable = function (e) {
      if (e.data && e.data.size > 0) _recChunks.push(e.data);
    };
    _recorder.onerror = function (e) {
      console.warn("[SpicetifyDownloader] MediaRecorder error:", e);
    };

    _recorder.start(1000); // collect in 1-second slices
    console.info("[SpicetifyDownloader] Recording started:", trackName);
    return true;
  }

  // Called when the playing song changes while capture mode is active
  function _onSongChangeCapture() {
    if (!_captureMode) return;
    // Save the previous track
    _stopRecording();
    _saveRecording();

    // Start recording the new track
    try {
      var player = Spicetify.Player.data;
      var name =
        (player.item && player.item.name) ||
        (player.track && player.track.name) ||
        "";
      if (!name) return;
      var path = (activeDownload && activeDownload.downloadPath) || "";
      _startRecording(name, path);
    } catch (_) {}
  }

  // Toggle capture mode from the quality modal
  function startCaptureMode(downloadPath) {
    _captureMode = true;
    _capturedCount = 0;
    _recDownloadPath = downloadPath;
    // Record the currently-playing track immediately
    try {
      var player = Spicetify.Player.data;
      var name =
        (player.item && player.item.name) ||
        (player.track && player.track.name) ||
        "";
      if (name) _startRecording(name, downloadPath);
    } catch (_) {}
    Spicetify.showNotification(
      "🔴 Capture mode ON — play tracks to record them. Press Ctrl+Shift+D to stop."
    );
  }

  function stopCaptureMode() {
    _captureMode = false;
    _stopRecording();
    _saveRecording();
    Spicetify.showNotification(
      "⏹ Capture mode OFF — " + _capturedCount + " track(s) saved."
    );
  }

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

  function parseSpotifyUrl(url) {
    if (!url) return null;
    var m = url.match(
      /open\.spotify\.com\/(playlist|album|track)\/([A-Za-z0-9]+)/,
    );
    if (!m) return null;
    return { type: m[1], id: m[2] };
  }

  function getCurrentPageContext() {
    try {
      var pathname = Spicetify.Platform.History.location.pathname || "";
      var m = pathname.match(/^\/(playlist|album|track)\/([A-Za-z0-9]+)/);
      if (!m) return null;
      return { type: m[1], id: m[2] };
    } catch (_) {
      return null;
    }
  }

  // ── Spotify track-list resolver (via Spicetify.CosmosAsync) ─────────────
  // Uses Spotify’s own internal API — no API keys, always accurate.
  function fetchSpotifyTracklist(type, id) {
    var tracks = [];
    var collectionName = "";

    function cosmos(url) {
      if (
        typeof Spicetify !== "undefined" &&
        Spicetify.CosmosAsync &&
        typeof Spicetify.CosmosAsync.get === "function"
      ) {
        return Spicetify.CosmosAsync.get(url);
      }
      // Fallback: native fetch (Spicetify injects auth cookie automatically)
      return fetch(url, { credentials: "include" }).then(function (r) {
        return r.json();
      });
    }

    var MAX_TRACKS = 500;

    function fetchPlaylist() {
      var offset = 0;
      var limit = 100;

      function fetchPage() {
        var url =
          "https://api.spotify.com/v1/playlists/" +
          id +
          "/tracks?limit=" +
          limit +
          "&offset=" +
          offset +
          "&fields=next,items(track(name,id,artists(name)))";
        return cosmos(url).then(function (resp) {
          var items = resp.items || [];
          items.forEach(function (item) {
            var t = item && item.track;
            if (!t || !t.name) return;
            var artists = (t.artists || [])
              .map(function (a) { return a.name; })
              .join(", ");
            tracks.push({
              name: artists ? t.name + " " + artists : t.name,
              spotify_url: t.id
                ? "https://open.spotify.com/track/" + t.id
                : "",
            });
          });
          offset += limit;
          if (resp.next && offset < MAX_TRACKS && items.length === limit) {
            return fetchPage();
          }
        });
      }

      return fetchPage().then(function () {
        return cosmos(
          "https://api.spotify.com/v1/playlists/" + id + "?fields=name"
        ).then(function (r) {
          collectionName = (r && r.name) || "";
        });
      });
    }

    function fetchAlbum() {
      var offset = 0;
      var limit = 50;

      function fetchPage() {
        var url =
          "https://api.spotify.com/v1/albums/" +
          id +
          "/tracks?limit=" +
          limit +
          "&offset=" +
          offset;
        return cosmos(url).then(function (resp) {
          var items = resp.items || [];
          items.forEach(function (item) {
            if (!item || !item.name) return;
            var artists = (item.artists || [])
              .map(function (a) { return a.name; })
              .join(", ");
            tracks.push({
              name: artists ? item.name + " " + artists : item.name,
              spotify_url: item.id
                ? "https://open.spotify.com/track/" + item.id
                : "",
            });
          });
          offset += limit;
          if (resp.next && offset < MAX_TRACKS && items.length === limit) {
            return fetchPage();
          }
        });
      }

      return fetchPage().then(function () {
        return cosmos(
          "https://api.spotify.com/v1/albums/" + id + "?fields=name"
        ).then(function (r) {
          collectionName = (r && r.name) || "";
        });
      });
    }

    var chain =
      type === "playlist" ? fetchPlaylist() : fetchAlbum();

    return chain
      .then(function () {
        return { tracks: tracks, collectionName: collectionName };
      })
      .catch(function (e) {
        console.warn("[SpicetifyDownloader] CosmosAsync resolve failed:", e);
        return { tracks: [], collectionName: "" };
      });
  }

  function sameContext(a, b) {
    return !!(a && b && a.type === b.type && a.id === b.id);
  }

  function ensureStyles() {
    if (document.getElementById("sd-progress-style")) return;
    var style = document.createElement("style");
    style.id = "sd-progress-style";
    var C = 2 * Math.PI * 6;
    style.textContent =
      ".sd-track-cell{position:relative!important}" +
      ".sd-row-progress{position:absolute;inset:0;display:flex;align-items:center;" +
      "justify-content:center;pointer-events:none;z-index:5;border-radius:4px}" +
      ".sd-row-progress svg{display:block;overflow:visible}" +
      ".sd-row-progress .sd-bg{stroke:rgba(255,255,255,.18);stroke-width:2;fill:none}" +
      ".sd-row-progress .sd-fg{stroke:#1DB954;stroke-width:2;fill:none;stroke-linecap:round;" +
      "transform:rotate(-90deg);transform-origin:50% 50%;transition:stroke-dashoffset .3s linear}" +
      ".sd-row-progress.sd-failed .sd-fg{stroke:#e91429}" +
      ".sd-row-progress.sd-completed .sd-fg{stroke:#1DB954}" +
      ".sd-row-progress.sd-indeterminate .sd-fg{" +
      "stroke-dasharray:9 29;animation:sd-spin 0.9s linear infinite;transform-origin:50% 50%}" +
      "@keyframes sd-spin{from{transform:rotate(-90deg)}to{transform:rotate(270deg)}}";
    document.head.appendChild(style);
  }

  function getTrackRows() {
    var SELECTORS = [
      '[data-testid="tracklist-row"]',
      '[role="row"][aria-rowindex]',
      '[role="row"][data-uri]',
    ];
    for (var i = 0; i < SELECTORS.length; i++) {
      try {
        var found = Array.prototype.slice.call(
          document.querySelectorAll(SELECTORS[i]),
        );
        found = found.filter(function (r) {
          return (
            r.getAttribute("aria-rowindex") !== "1" &&
            !r.querySelector('[data-testid="tracklist-column-header"]')
          );
        });
        if (found.length) return found;
      } catch (_) {}
    }
    return [];
  }

  function getRowNumberCell(row) {
    if (!row) return null;
    var cell = row.querySelector('[aria-colindex="1"]');
    if (cell) return cell;
    cell = row.querySelector('[data-testid="tracklist-row-section-start"]');
    if (cell) return cell;
    cell = row.querySelector('[role="gridcell"]');
    if (cell) return cell;
    return row.firstElementChild;
  }

  function clearRowProgress() {
    document.querySelectorAll(".sd-row-progress").forEach(function (el) {
      var cell = el.parentElement;
      if (cell) cell.classList.remove("sd-track-cell");
      el.remove();
    });
  }

  function upsertRowProgress(row, state, percent) {
    var cell = getRowNumberCell(row);
    if (!cell) return;

    cell.classList.add("sd-track-cell");

    var mount = cell.querySelector(".sd-row-progress");
    if (!mount) {
      mount = document.createElement("span");
      mount.className = "sd-row-progress";
      mount.setAttribute("aria-hidden", "true");
      mount.innerHTML =
        '<svg viewBox="0 0 16 16" width="16" height="16">' +
        '<circle class="sd-bg" cx="8" cy="8" r="6"></circle>' +
        '<circle class="sd-fg" cx="8" cy="8" r="6"></circle>' +
        "</svg>";
      cell.appendChild(mount);
    }

    mount.classList.remove("sd-completed", "sd-failed", "sd-indeterminate");
    var fg = mount.querySelector(".sd-fg");
    var CIRC = 2 * Math.PI * 6;

    if (state === "completed") {
      mount.classList.add("sd-completed");
      fg.style.strokeDasharray = String(CIRC);
      fg.style.strokeDashoffset = "0";
      return;
    }
    if (state === "failed") {
      mount.classList.add("sd-failed");
      fg.style.strokeDasharray = String(CIRC);
      fg.style.strokeDashoffset = "0";
      return;
    }

    if (typeof percent === "number" && percent >= 0) {
      var p = Math.max(0, Math.min(100, percent));
      fg.style.strokeDasharray = String(CIRC);
      fg.style.strokeDashoffset = String(CIRC * (1 - p / 100));
    } else {
      mount.classList.add("sd-indeterminate");
      fg.style.strokeDasharray = null;
      fg.style.strokeDashoffset = null;
    }
  }

  function renderPerTrackProgress() {
    ensureStyles();

    if (!activeDownload) {
      clearRowProgress();
      return;
    }

    var currentPage = getCurrentPageContext();
    if (!sameContext(currentPage, activeDownload.context)) {
      clearRowProgress();
      return;
    }

    var rows = getTrackRows();
    if (!rows.length) return;

    var done = activeDownload.done || 0;
    var total = activeDownload.total || 0;
    var status = activeDownload.status || "downloading";

    rows.forEach(function (row, index) {
      if (status === "completed") {
        upsertRowProgress(row, "completed");
        return;
      }

      if (status === "failed") {
        if (index === done) {
          upsertRowProgress(row, "failed");
        }
        return;
      }

      // Total not yet known (still scanning) — spin all visible rows
      if (total === 0) {
        upsertRowProgress(row, "active", null);
        return;
      }

      if (index < done) {
        upsertRowProgress(row, "completed");
      } else if (index === done && done < total) {
        var currentTrackPct = null;
        if (typeof activeDownload.percent === "number" && total > 0) {
          currentTrackPct = Math.round(
            Math.max(0, activeDownload.percent - (done * 100) / total) * total,
          );
          if (currentTrackPct > 100) currentTrackPct = 100;
        }
        // 0 % renders as an invisible empty circle — show spinner instead
        if (!currentTrackPct) currentTrackPct = null;
        upsertRowProgress(row, "active", currentTrackPct);
      }
    });
  }

  function startRowRenderLoop() {
    if (rowRenderTimer) return;
    rowRenderTimer = setInterval(renderPerTrackProgress, 1200);
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
    if (progressPollTimer) clearInterval(progressPollTimer);

    function pollOnce() {
      fetch(API_URL + "/progress/" + downloadId)
        .then(function (res) {
          return res.json();
        })
        .then(function (data) {
          if (activeDownload && activeDownload.id === downloadId) {
            activeDownload.status = data.status;
            activeDownload.done = data.done || 0;
            activeDownload.total = data.total || 0;
            activeDownload.percent = data.percent || 0;
          }
          renderPerTrackProgress();

          if (data.status === "downloading") {
            // keep polling
          } else if (data.status === "completed") {
            if (progressPollTimer) {
              clearInterval(progressPollTimer);
              progressPollTimer = null;
            }
            isDownloading = false;
            var msg = "Download complete! Files saved to your Music folder.";
            if (data.error) {
              msg += " (" + data.error + ")";
            }
            Spicetify.showNotification(msg);

            // Offer capture mode if there were failed tracks in a collection
            var failedTracks = data.failed_tracks || [];
            if (failedTracks.length > 0 && activeDownload && activeDownload.context) {
              var ctx = activeDownload.context;
              var ctxUrl = "https://open.spotify.com/" + ctx.type + "/" + ctx.id;
              setTimeout(function () {
                showQualityModal(ctxUrl, null, failedTracks);
              }, 500);
            }

            setTimeout(function () {
              activeDownload = null;
              renderPerTrackProgress();
            }, 12000);
          } else if (data.status === "failed") {
            if (progressPollTimer) {
              clearInterval(progressPollTimer);
              progressPollTimer = null;
            }
            isDownloading = false;
            var failMsg = data.error || "Download failed.";
            fetch(API_URL + "/logs/" + downloadId)
              .then(function (r) {
                return r.json();
              })
              .then(function (logData) {
                var lines = (logData.lines || []).filter(function (l) {
                  var ll = l.toLowerCase();
                  return (
                    ll.indexOf("error") !== -1 ||
                    ll.indexOf("failed") !== -1 ||
                    ll.indexOf("exception") !== -1
                  );
                });
                if (lines.length) {
                  failMsg = lines[lines.length - 1].slice(0, 120);
                }
                Spicetify.showNotification("Download failed: " + failMsg, true);
              })
              .catch(function () {
                Spicetify.showNotification("Download failed: " + failMsg, true);
              });
            setTimeout(function () {
              activeDownload = null;
              renderPerTrackProgress();
            }, 15000);
          }
        })
        .catch(function () {
          /* server temporarily unreachable, keep polling */
        });
    }

    pollOnce();
    progressPollTimer = setInterval(pollOnce, 2000);
  }

  // ── Download trigger ─────────────────────────────────────────────────────

  function startDownload(url, quality) {
    if (isDownloading) {
      Spicetify.showNotification("A download is already in progress!", true);
      return;
    }
    isDownloading = true;

    var initialTotal = resolvedTracklist
      ? resolvedTracklist.tracks.length
      : 0;
    Spicetify.showNotification(
      "Starting download at " + quality + " kbps" +
      (initialTotal ? " • " + initialTotal + " tracks" : "") + "…"
    );

    activeDownload = {
      id: null,
      context: parseSpotifyUrl(url),
      status: "starting",
      done: 0,
      total: initialTotal,
      percent: 0,
      downloadPath: "",
    };
    renderPerTrackProgress();

    var postBody = { url: url, quality: quality };
    if (resolvedTracklist) {
      if (resolvedTracklist.tracks.length > 0) {
        postBody.tracks = resolvedTracklist.tracks;
      }
      if (resolvedTracklist.collectionName) {
        postBody.collection_name = resolvedTracklist.collectionName;
      }
    }
    resolvedTracklist = null; // reset after use

    fetch(API_URL + "/download", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(postBody),
    })
      .then(function (res) {
        return res.json();
      })
      .then(function (data) {
        if (data.status === "started") {
          if (activeDownload) {
            activeDownload.id = data.download_id;
            // Update total from server (in case backend adjusted it)
            if (data.total && data.total > 0) {
              activeDownload.total = data.total;
            }
          }
          pollProgress(data.download_id);
        } else {
          Spicetify.showNotification(
            data.error || "Failed to start download.",
            true,
          );
          isDownloading = false;
          activeDownload = null;
          renderPerTrackProgress();
        }
      })
      .catch(function () {
        Spicetify.showNotification(
          "Cannot reach the download server.\nRe-run the installer to fix it.",
          true,
        );
        isDownloading = false;
        activeDownload = null;
        renderPerTrackProgress();
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
    if (!serverOnline) {
      fetch(API_URL + "/health")
        .then(function (res) {
          if (res.ok) {
            serverOnline = true;
            doSmartDownload();
          } else {
            Spicetify.showNotification(
              "Download server is offline. Re-run the installer to start it.",
              true,
            );
          }
        })
        .catch(function () {
          Spicetify.showNotification(
            "Download server is offline. Re-run the installer to start it.",
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

    if (data.type === "track") {
      var name = getCurrentTrackName();
      resolvedTracklist = null;
      showQualityModal(data.url, name ? "Track: " + name : "Current track");
      return;
    }

    // For playlists/albums: resolve track list from Spotify internal API first
    var parsedId = parseSpotifyUrl(data.url);
    if (!parsedId) {
      showQualityModal(data.url, data.type === "playlist" ? "Playlist" : "Album");
      return;
    }

    Spicetify.showNotification("⏳ Resolving track list…");
    fetchSpotifyTracklist(parsedId.type, parsedId.id)
      .then(function (result) {
        resolvedTracklist = result;
        var count = result.tracks.length;
        var title = result.collectionName ||
          (data.type === "playlist" ? "Playlist" : "Album");
        var subtitle = title +
          (count > 0 ? " \u2022 " + count + " track" + (count !== 1 ? "s" : "") : "");
        showQualityModal(data.url, subtitle);
      })
      .catch(function () {
        resolvedTracklist = null;
        showQualityModal(
          data.url,
          data.type === "playlist" ? "Playlist" : "Album"
        );
      });
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

  function isLikelyNativeDownloadButton(btn) {
    if (!btn) return false;

    for (var i = 0; i < NATIVE_DOWNLOAD_SELECTORS.length; i++) {
      try {
        if (btn.matches(NATIVE_DOWNLOAD_SELECTORS[i])) return true;
      } catch (_) {}
    }

    var testId = (btn.getAttribute("data-testid") || "").toLowerCase();
    if (testId.indexOf("download") !== -1) return true;

    var label = (btn.getAttribute("aria-label") || "").toLowerCase();
    if (
      label.indexOf("download") !== -1 ||
      label.indexOf("\u0441\u043a\u0430\u0447\u0430\u0442") !== -1 ||
      label.indexOf("herunterladen") !== -1 ||
      label.indexOf("t\u00e9l\u00e9charger") !== -1 ||
      label.indexOf("descargar") !== -1 ||
      label.indexOf("scarica") !== -1 ||
      label.indexOf("pobierz") !== -1
    ) {
      return true;
    }

    return false;
  }

  function watchForNativeDownloadButtons() {
    if (nativeClickHooked) return;
    nativeClickHooked = true;

    document.addEventListener(
      "click",
      function (e) {
        var target = e.target;
        if (!target || !target.closest) return;
        var btn = target.closest("button,[role='button']");
        if (!isLikelyNativeDownloadButton(btn)) return;

        e.preventDefault();
        e.stopImmediatePropagation();
        triggerSmartDownload();
      },
      true,
    );
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
      if (data.type === "playlist" || data.type === "album") {
        var parsedId = parseSpotifyUrl(data.url);
        if (parsedId) {
          Spicetify.showNotification("\u23f3 Resolving track list\u2026");
          fetchSpotifyTracklist(parsedId.type, parsedId.id)
            .then(function (result) {
              resolvedTracklist = result;
              var count = result.tracks.length;
              var title =
                result.collectionName ||
                (data.type === "playlist" ? "Playlist" : "Album");
              var subtitle =
                title +
                (count > 0
                  ? " \u2022 " + count + " track" + (count !== 1 ? "s" : "")
                  : "");
              showQualityModal(data.url, subtitle);
            })
            .catch(function () {
              resolvedTracklist = null;
              showQualityModal(data.url, "");
            });
          return;
        }
      }
      resolvedTracklist = null;
      showQualityModal(data.url, "");
    };

    new Spicetify.ContextMenu.Item(
      "Download for Offline",
      onSelect,
      shouldShow,
      "download",
    ).register();
  }

  // ── Keyboard shortcut: Ctrl+Shift+D ──────────────────────────────────────

  function registerKeyboard() {
    document.addEventListener("keydown", function (e) {
      if (e.ctrlKey && e.shiftKey && e.key === "D") {
        e.preventDefault();
        if (_captureMode) {
          // Ctrl+Shift+D while in capture mode → stop capture
          stopCaptureMode();
        } else {
          triggerSmartDownload();
        }
      }
    });
  }

  // ── Init ─────────────────────────────────────────────────────────────────

  function init() {
    checkServerHealth();
    setInterval(checkServerHealth, 30000);

    registerContextMenu();
    registerKeyboard();
    watchForNativeDownloadButtons();
    startRowRenderLoop();

    // OGG capture: listen to song changes
    try {
      Spicetify.Player.addEventListener("songchange", _onSongChangeCapture);
    } catch (_) {}

    console.info(
      "[SpicetifyDownloader] Extension loaded (no API keys needed). Server:",
      API_URL,
    );
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
