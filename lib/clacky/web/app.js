// ── app.js — Main entry point ──────────────────────────────────────────────
//
// Coordinates WS, Sessions, Tasks, Skills and Settings modules.
// Handles WS event dispatch and wires up all DOM event listeners.
//
// Load order (in index.html):
//   ws.js → sessions.js → tasks.js → skills.js → app.js
// ─────────────────────────────────────────────────────────────────────────

// ── DOM helper (shared by all modules loaded after this) ──────────────────
const $ = id => document.getElementById(id);

// ── Utilities (shared) ────────────────────────────────────────────────────
function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// ── Router ────────────────────────────────────────────────────────────────
//
// Single source of truth for panel visibility and URL hash.
//
// Views:
//   welcome            → /#
//   session/{id}       → /#session/{id}
//   tasks              → /#tasks
//   skills             → /#skills
//   settings           → /#settings
//
// Usage:
//   Router.navigate("session", { id: "abc123" })
//   Router.navigate("tasks")
//   Router.navigate("welcome")
//
// All panels must be listed in PANELS so they are hidden before the active
// one is shown. Modules must NOT touch panel display styles directly.
// ─────────────────────────────────────────────────────────────────────────
const PANELS = [
  "setup-panel",
  "onboard-panel",
  "welcome",
  "chat-panel",
  "task-detail-panel",
  "skills-panel",
  "channels-panel",
  "settings-panel",
];

const Router = (() => {
  let _current     = null;  // current view name
  let _params      = {};    // current params (e.g. { id: "abc" } for session view)
  let _skipNextHashChange = false;  // prevent echo loop when we set hash ourselves

  // Hide all panels.
  function _hideAll() {
    PANELS.forEach(p => {
      const el = $(p);
      if (el) el.style.display = "none";
    });
  }

  // Update the URL hash without triggering a hashchange handler loop.
  function _setHash(hash) {
    _skipNextHashChange = true;
    location.hash = hash;
  }

  // Resolve a hash string into { view, params }.
  function _parseHash(hash) {
    const h = (hash || "").replace(/^#\/?/, "");
    if (!h)                           return { view: "welcome",  params: {} };
    if (h === "tasks")                return { view: "tasks",    params: {} };
    if (h === "skills")               return { view: "skills",   params: {} };
    if (h === "channels")             return { view: "channels", params: {} };
    if (h === "settings")             return { view: "settings", params: {} };
    const m = h.match(/^session\/(.+)$/);
    if (m)                            return { view: "session",  params: { id: m[1] } };
    return { view: "welcome", params: {} };
  }

  // Sidebar items managed by Router (keyed by view name → element id).
  // Router is the single authority for active highlight — modules must NOT
  // add/remove the "active" class on these elements themselves.
  const SIDEBAR_ITEMS = {
    tasks:    "tasks-sidebar-item",
    skills:   "skills-sidebar-item",
    channels: "channels-sidebar-item",
  };

  // Remove active highlight from all Router-managed sidebar items.
  function _clearSidebarActive() {
    Object.values(SIDEBAR_ITEMS).forEach(id => {
      const el = $(id);
      if (el) el.classList.remove("active");
    });
  }

  // Core: apply a view change. Called both from navigate() and hashchange.
  function _apply(view, params = {}) {
    _current = view;
    _params  = params;

    // Close sidebar on mobile when navigating to any view
    _mobileCloseSidebar();

    // ── Clean up previous state ──────────────────────────────────────────
    if (Sessions.activeId) {
      Sessions._cacheActiveAndDeselect();
    }
    Sessions.updateInfoBar(null);  // hide info bar when leaving any session
    // Clear all sidebar highlights and settings button active state
    _clearSidebarActive();
    const btnSettings = $("btn-settings");
    if (btnSettings) btnSettings.classList.remove("active");

    _hideAll();

    // Reveal #app on first navigation — ensures the correct view (and language)
    // is already in place before the user sees anything.
    // #app covers sidebar + main, so data-i18n elements in the sidebar are also
    // hidden until applyAll() has run (prevents flash of English sidebar labels).
    const appEl = document.getElementById("app");
    if (appEl && appEl.style.visibility === "hidden") {
      I18n.applyAll();  // Translate all data-i18n elements before revealing
      appEl.style.visibility = "";
    }

    // ── Activate target panel + sidebar highlight ────────────────────────
    switch (view) {

      case "session": {
        const id = params.id;
        const s  = Sessions.find(id);
        if (!s) {
          // Session not found (e.g. deleted) — fall back to welcome
          _apply("welcome");
          return;
        }
        _setHash(`session/${id}`);
        $("chat-panel").style.display       = "flex";
        $("chat-panel").style.flexDirection = "column";
        $("chat-title").textContent = s.name;
        Sessions.updateStatusBar(s.status);
        Sessions.updateInfoBar(s);
        Sessions._restoreMessagesPublic(id);
        Sessions._setActiveId(id);
        WS.setSubscribedSession(id);
        // Only disable send button until server confirms subscription
        // Input field remains usable so user can type while waiting
        $("btn-send").disabled = true;
        WS.send({ type: "subscribe", session_id: id });
        Sessions.renderList();
        $("user-input").focus();

        // Load session-scoped skill list (filtered by agent profile) for slash autocomplete
        SkillAC.loadForSession(id);

        // Always reload history on every switch (cache is not used)
        Sessions.loadHistory(id);
        break;
      }

      case "tasks":
        _setHash("tasks");
        $("task-detail-panel").style.display = "flex";
        Tasks.onPanelShow();
        Sessions.renderList();
        break;

      case "skills":
        _setHash("skills");
        $("skills-panel").style.display = "flex";
        Skills.onPanelShow();
        Sessions.renderList();
        break;

      case "channels":
        _setHash("channels");
        $("channels-panel").style.display = "flex";
        Channels.onPanelShow();
        Sessions.renderList();
        break;

      case "settings":
        _setHash("settings");
        $("settings-panel").style.display = "";
        if (btnSettings) btnSettings.classList.add("active");
        Settings.open();
        Sessions.renderList();
        break;

      case "setup":
        // Full-screen mandatory setup (language + API key). No hash — keep URL clean.
        $("setup-panel").style.display = "flex";
        break;

      case "onboard":
        // Kept for compatibility; setup-panel is now used for first-run setup.
        $("onboard-panel").style.display = "flex";
        break;

      default:  // "welcome"
        _setHash("");
        $("welcome").style.display = "";
        Sessions.renderList();
        break;
    }

    // Re-apply sidebar active highlight after all rendering is done.
    // renderSection() rebuilds the DOM element, so we stamp active *after*.
    _clearSidebarActive();
    const activeItem = SIDEBAR_ITEMS[view];
    if (activeItem) $(activeItem)?.classList.add("active");
  }

  // Listen for browser back/forward (or manual hash edits).
  window.addEventListener("hashchange", () => {
    if (_skipNextHashChange) {
      _skipNextHashChange = false;
      return;
    }
    const { view, params } = _parseHash(location.hash);
    _apply(view, params);
  });

  return {
    get current() { return _current; },
    get params()  { return _params; },

    /** Navigate to a view. This is the only way panels should change. */
    navigate(view, params = {}) {
      _apply(view, params);
    },

    /** Restore state from current URL hash (called once on boot after data loads). */
    restoreFromHash() {
      const { view, params } = _parseHash(location.hash);
      _apply(view, params);
    },
  };
})();

// ── Modal utility ─────────────────────────────────────────────────────────
const Modal = (() => {
  /** Show a yes/no confirmation dialog. Returns a Promise<boolean>. */
  function confirm(message) {
    return new Promise(resolve => {
      $("modal-message").textContent   = message;
      $("modal-overlay").style.display = "flex";

      const cleanup = (result) => {
        $("modal-overlay").style.display = "none";
        $("modal-yes").onclick = null;
        $("modal-no").onclick  = null;
        resolve(result);
      };
      $("modal-yes").onclick = () => cleanup(true);
      $("modal-no").onclick  = () => cleanup(false);
    });
  }

  return { confirm };
})();

// ── Confirmation modal ────────────────────────────────────────────────────
function showConfirmModal(confId, message) {
  $("modal-message").textContent   = message;
  $("modal-overlay").style.display = "flex";

  const answer = result => {
    $("modal-overlay").style.display = "none";
    WS.send({ type: "confirmation", session_id: Sessions.activeId, id: confId, result });
  };
  $("modal-yes").onclick = () => answer("yes");
  $("modal-no").onclick  = () => answer("no");
}

// ── WS event dispatcher ───────────────────────────────────────────────────
// Guard: restore hash routing only once after initial session_list arrives.
let _initialRestoreDone = false;

WS.onEvent(ev => {
  switch (ev.type) {

    // ── Internal WS lifecycle ──────────────────────────────────────────
    case "_ws_connected": {
      const banner = document.getElementById("offline-banner");
      if (banner) banner.style.display = "none";
      const hint = $("ws-disconnect-hint");
      if (hint) hint.style.display = "none";
      break;
    }

    case "_ws_disconnected": {
      const banner = document.getElementById("offline-banner");
      if (banner) {
        banner.textContent = I18n.t("offline.banner");
        banner.style.display = "block";
      }
      Sessions.clearProgress();
      Sessions.updateStatusBar("idle");
      break;
    }

    // ── Session list ───────────────────────────────────────────────────
    case "session_list": {
      Sessions.setAll(ev.sessions || [], !!ev.has_more);
      Sessions.renderList();

      // Restore URL hash once on initial connect; ignore subsequent session_list events.
      // Skip if we are already on a session view (e.g. onboard flow navigated there
      // before WS connected) — restoreFromHash would wrongly redirect to "welcome"
      // because there is no hash set during onboarding.
      if (!_initialRestoreDone) {
        _initialRestoreDone = true;
        if (Router.current !== "session") {
          Router.restoreFromHash();
        }
      } else {
        // If active session was deleted, go to welcome
        if (Sessions.activeId && !Sessions.find(Sessions.activeId)) {
          Router.navigate("welcome");
        }
      }
      break;
    }

    // ── Session lifecycle ──────────────────────────────────────────────
    case "subscribed": {
      // Re-enable send button now that the server has confirmed the subscription.
      $("btn-send").disabled = false;
      $("user-input").focus();
      // If this session was created by Tasks.run(), fire the agent now that
      // we're guaranteed to receive its broadcasts.
      const pendingId = Sessions.takePendingRunTask();
      if (pendingId && pendingId === ev.session_id) {
        WS.send({ type: "run_task", session_id: pendingId });
      }
      // If a slash-command was queued (e.g. /onboard from first-boot flow),
      // send it now — after restoreFromHash has settled — so appendMsg won't be wiped.
      const pendingMsg = Sessions.takePendingMessage();
      if (pendingMsg && pendingMsg.session_id === ev.session_id) {
        Sessions.appendMsg("user", escapeHtml(pendingMsg.content), { time: new Date() });
        WS.send({ type: "message", session_id: pendingMsg.session_id, content: pendingMsg.content });
      }
      break;
    }

    case "session_update": {
      // Two shapes arrive under this type:
      //   (1) Full session object from http_server broadcast_session_update:
      //       { type, session: { id, name, status, total_cost, total_tasks, ... } }
      //   (2) Partial real-time update from web_ui_controller (cost/tasks/status):
      //       { type, session_id, cost?, tasks?, status? }
      let sid, patch;
      if (ev.session) {
        // Shape (1): full session — use as-is
        sid   = ev.session.id;
        patch = ev.session;
      } else {
        // Shape (2): partial update — build patch from top-level fields
        sid   = ev.session_id;
        patch = {};
        if (ev.cost   !== undefined) patch.total_cost  = ev.cost;
        if (ev.tasks  !== undefined) patch.total_tasks = ev.tasks;
        if (ev.status !== undefined) patch.status      = ev.status;
      }
      if (!sid) break;
      Sessions.patch(sid, patch);
      Sessions.renderList();
      if (sid === Sessions.activeId) {
        const current = Sessions.find(sid);
        if (patch.status !== undefined) Sessions.updateStatusBar(patch.status);
        Sessions.updateInfoBar(current);
        // Update chat title in case session was renamed
        $("chat-title").textContent = current?.name || "";
      }
      // When a session finishes, refresh tasks and skills
      if (patch.status === "idle") { Tasks.load(); Skills.load(); }
      break;
    }

    case "session_renamed": {
      Sessions.patch(ev.session_id, { name: ev.name });
      Sessions.renderList();
      if (ev.session_id === Sessions.activeId) {
        $("chat-title").textContent = ev.name;
      }
      break;
    }

    case "session_deleted":
      Sessions.remove(ev.session_id);
      if (ev.session_id === Sessions.activeId) Router.navigate("welcome");
      Sessions.renderList();
      break;

    // ── Chat messages ──────────────────────────────────────────────────
    case "history_user_message":
      // Emitted only during history replay — never from live WS.
      // Rendered by Sessions._fetchHistory; nothing to do here.
      break;

    case "assistant_message":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendMsg("assistant", ev.content);
      break;

    case "tool_call":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendToolCall(ev.name, ev.args, ev.summary);
      break;

    case "tool_result":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendToolResult(ev.result);
      break;

    case "tool_stdout":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendToolStdout(ev.lines);
      break;

    case "tool_error":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendMsg("info", `⚠ Tool error: ${escapeHtml(ev.error)}`);
      break;

    case "token_usage":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendTokenUsage(ev);
      break;

    case "progress":
      if (ev.session_id !== Sessions.activeId) break;
      if (ev.status === "start") Sessions.showProgress(ev.message || I18n.t("chat.thinking"));
      else Sessions.clearProgress();
      break;

    case "complete":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.collapseToolGroup();
      Sessions.appendInfo(`✓ ${I18n.t("chat.done", { n: ev.iterations, cost: (ev.cost || 0).toFixed(4) })}`);
      break;

    case "request_confirmation":
      if (ev.session_id !== Sessions.activeId) break;
      showConfirmModal(ev.id, ev.message);
      break;

    case "interrupted":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.collapseToolGroup();
      Sessions.appendInfo(I18n.t("chat.interrupted"));
      break;

    // ── Info / errors ──────────────────────────────────────────────────
    case "idle_status":
      // Two-phase: "start" shows a spinner line, "end" updates it in-place
      Sessions.updateIdleStatus(ev.phase, ev.message);
      break;

    case "info":
      Sessions.appendInfo(ev.message);
      break;

    case "warning":
      Sessions.appendInfo("⚠ " + ev.message);
      break;

    case "success":
      Sessions.appendMsg("success", "✓ " + escapeHtml(ev.message));
      break;

    case "error":
      if (!ev.session_id || ev.session_id === Sessions.activeId)
        Sessions.appendMsg("error", escapeHtml(ev.message));
      break;
  }
});

// ── Image & file attachments ──────────────────────────────────────────────
const _pendingImages = [];
const _pendingFiles  = [];
const MAX_IMAGE_SIZE        = 5 * 1024 * 1024;   // 5 MB — hard reject before compression
const MAX_IMAGE_BYTES_SEND  = 512 * 1024;         // 512 KB — target after compression
const MAX_IMAGE_LONG_EDGE   = 1920;               // px — scale down if larger
const MAX_FILE_BYTES = 32 * 1024 * 1024;  // 32 MB
const ACCEPTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];
const ACCEPTED_DOC_TYPES   = [
  "application/pdf",
  "application/zip",
  "application/x-zip-compressed",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document", // .docx
  "application/msword",                                                        // .doc
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",        // .xlsx
  "application/vnd.ms-excel",                                                  // .xls
  "application/vnd.openxmlformats-officedocument.presentationml.presentation", // .pptx
  "application/vnd.ms-powerpoint",                                             // .ppt
  "text/csv",                                                                  // .csv
  "application/csv",                                                           // .csv (some browsers)
];

function _docTypeIcon(mimeType) {
  if (mimeType === "application/pdf") return "📄";
  if (mimeType === "application/zip" || mimeType === "application/x-zip-compressed") return "🗜️";
  if (mimeType.includes("wordprocessingml") || mimeType === "application/msword") return "📝";
  if (mimeType.includes("spreadsheetml") || mimeType === "application/vnd.ms-excel") return "📊";
  if (mimeType.includes("presentationml") || mimeType === "application/vnd.ms-powerpoint") return "📋";
  if (mimeType === "text/csv" || mimeType === "application/csv") return "📊";
  return "📎";
}

// Compress an image File/Blob to a data URL within MAX_IMAGE_BYTES_SEND.
// Strategy: scale down to MAX_IMAGE_LONG_EDGE, then reduce JPEG quality until small enough.
// GIF is not compressible via Canvas — returned as-is if within limit.
function _compressImage(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error("Failed to read image"));
    reader.onload = e => {
      const img = new Image();
      img.onerror = () => reject(new Error("Failed to decode image"));
      img.onload = () => {
        // Scale down if needed
        let { width, height } = img;
        if (width > MAX_IMAGE_LONG_EDGE || height > MAX_IMAGE_LONG_EDGE) {
          const ratio = Math.min(MAX_IMAGE_LONG_EDGE / width, MAX_IMAGE_LONG_EDGE / height);
          width  = Math.round(width  * ratio);
          height = Math.round(height * ratio);
        }

        const canvas = document.createElement("canvas");
        canvas.width  = width;
        canvas.height = height;
        const ctx = canvas.getContext("2d");
        ctx.drawImage(img, 0, 0, width, height);

        // GIF: LLMs only see the first frame anyway — render via Canvas and compress as JPEG

        // Try decreasing quality until under limit
        let quality = 0.85;
        let dataUrl = canvas.toDataURL("image/jpeg", quality);
        while (dataUrl.length * 0.75 > MAX_IMAGE_BYTES_SEND && quality > 0.2) {
          quality -= 0.1;
          dataUrl = canvas.toDataURL("image/jpeg", quality);
        }
        resolve(dataUrl);
      };
      img.src = e.target.result;
    };
    reader.readAsDataURL(file);
  });
}

function _addImageFile(file) {
  if (!ACCEPTED_IMAGE_TYPES.includes(file.type)) {
    alert(`Unsupported image type: ${file.type}\nSupported: PNG, JPEG, GIF, WEBP`);
    return;
  }
  if (file.size > MAX_IMAGE_SIZE) {
    alert(`Image too large: ${file.name} (max 5 MB)`);
    return;
  }
  _compressImage(file)
    .then(dataUrl => {
      _pendingImages.push({ dataUrl, name: file.name, mimeType: "image/jpeg" });
      _renderAttachmentPreviews();
    })
    .catch(err => alert(`Image processing failed: ${err.message}`));
}

function _addGenericFile(file) {
  if (file.size > MAX_FILE_BYTES) {
    alert(`File too large: ${file.name} (max 32 MB)`);
    return;
  }
  // Upload file to server via HTTP — only the path is returned, no base64 in memory
  const formData = new FormData();
  formData.append("file", file);
  fetch("/api/upload", { method: "POST", body: formData })
    .then(r => r.json())
    .then(data => {
      if (!data.ok) { alert(`Upload failed: ${data.error}`); return; }
      _pendingFiles.push({
        name:      data.name,
        path:      data.path,
        mime_type: file.type
      });
      _renderAttachmentPreviews();
      setTimeout(() => $("user-input").focus(), 100);
    })
    .catch(err => alert(`Upload error: ${err.message}`));
}

function _addAttachmentFile(file) {
  if (ACCEPTED_DOC_TYPES.includes(file.type)) {
    _addGenericFile(file);
  } else {
    _addImageFile(file);
  }
}

function _renderAttachmentPreviews() {
  const strip = $("image-preview-strip");
  strip.innerHTML = "";
  const hasContent = _pendingImages.length > 0 || _pendingFiles.length > 0;
  if (!hasContent) {
    strip.style.display = "none";
    return;
  }
  strip.style.display = "flex";

  // Render image thumbnails
  _pendingImages.forEach((img, idx) => {
    const item = document.createElement("div");
    item.className = "img-preview-item";
    item.title = img.name;
    const thumbnail = document.createElement("img");
    thumbnail.src = img.dataUrl;
    thumbnail.alt = img.name;
    const removeBtn = document.createElement("button");
    removeBtn.className = "img-preview-remove";
    removeBtn.textContent = "✕";
    removeBtn.title = "Remove";
    removeBtn.addEventListener("click", () => {
      _pendingImages.splice(idx, 1);
      _renderAttachmentPreviews();
    });
    item.appendChild(thumbnail);
    item.appendChild(removeBtn);
    strip.appendChild(item);
  });

  // Render file cards (PDF, ZIP, DOC, XLS, PPT, etc.)
  _pendingFiles.forEach((f, idx) => {
    const item = document.createElement("div");
    item.className = "pdf-preview-item";
    item.title = f.name;

    const icon = document.createElement("div");
    icon.className = "pdf-preview-icon";
    icon.textContent = _docTypeIcon(f.mime_type);

    const info = document.createElement("div");
    info.className = "pdf-preview-info";

    const name = document.createElement("div");
    name.className = "pdf-preview-name";
    name.textContent = f.name;

    const typeLabel = document.createElement("div");
    typeLabel.className = "pdf-preview-type";
    typeLabel.textContent = (f.name.split(".").pop() || "file").toUpperCase();

    info.appendChild(name);
    info.appendChild(typeLabel);

    const removeBtn = document.createElement("button");
    removeBtn.className = "pdf-preview-remove";
    removeBtn.textContent = "✕";
    removeBtn.title = "Remove";
    removeBtn.addEventListener("click", () => {
      _pendingFiles.splice(idx, 1);
      _renderAttachmentPreviews();
    });

    item.appendChild(icon);
    item.appendChild(info);
    item.appendChild(removeBtn);
    strip.appendChild(item);
  });
}

// Keep backward-compat alias (used in drag-drop / paste handlers below)
function _renderImagePreviews() { _renderAttachmentPreviews(); }

// ── Send message ──────────────────────────────────────────────────────────
let _sending = false;

function sendMessage() {
  if (_sending) return;
  const input   = $("user-input");
  const content = input.value.trim();
  if (!content && _pendingImages.length === 0 && _pendingFiles.length === 0) return;
  if (!Sessions.activeId) return;

  if (!WS.ready) {
    const hint = $("ws-disconnect-hint");
    if (hint) {
      hint.textContent = I18n.t("chat.disconnected.hint");
      hint.style.display = "block";
      hint.style.opacity = "1";
      clearTimeout(hint._hideTimer);
      hint._hideTimer = setTimeout(() => {
        hint.style.opacity = "0";
        setTimeout(() => { hint.style.display = "none"; }, 400);
      }, 2000);
    }
    return;
  }

  _sending = true;

  let bubbleHtml = content ? escapeHtml(content) : "";
  if (_pendingImages.length > 0) {
    const thumbs = _pendingImages
      .map(img => `<img src="${img.dataUrl}" alt="${escapeHtml(img.name)}" class="msg-image-thumb">`)
      .join("");
    bubbleHtml = thumbs + (bubbleHtml ? "<br>" + bubbleHtml : "");
  }
  if (_pendingFiles.length > 0) {
    const badges = _pendingFiles.map(f => {
      const icon = _docTypeIcon(f.mime_type);
      const ext  = (f.name.split(".").pop() || "file").toUpperCase();
      return `<span class="msg-pdf-badge">` +
        `<span class="msg-pdf-badge-icon">${icon}</span>` +
        `<span class="msg-pdf-badge-info">` +
          `<span class="msg-pdf-badge-name">${escapeHtml(f.name)}</span>` +
          `<span class="msg-pdf-badge-type">${escapeHtml(ext)}</span>` +
        `</span>` +
      `</span>`;
    }).join(" ");
    bubbleHtml = badges + (bubbleHtml ? "<br>" + bubbleHtml : "");
  }
  Sessions.appendMsg("user", bubbleHtml, { time: new Date() });

  // Merge images and files into unified files array
  const files = [
    ..._pendingImages.map(img => ({
      name:      img.name,
      mime_type: img.mimeType || "image/jpeg",
      data_url:  img.dataUrl
    })),
    ..._pendingFiles.map(f => ({
      name:      f.name,
      path:      f.path,
      mime_type: f.mime_type
    }))
  ];
  _pendingImages.length = 0;
  _pendingFiles.length  = 0;
  _renderAttachmentPreviews();

  WS.send({ type: "message", session_id: Sessions.activeId, content, files });
  input.value        = "";
  input.style.height = "auto";
  setTimeout(() => { _sending = false; }, 300);
}

// ── DOM event listeners ───────────────────────────────────────────────────
// Sidebar toggle (with mobile overlay support)
function _isMobile() { return window.innerWidth <= 768; }

function _closeSidebar() {
  $("sidebar").classList.add("hidden");
  $("sidebar-overlay").classList.remove("active");
}

function _openSidebar() {
  $("sidebar").classList.remove("hidden");
  if (_isMobile()) $("sidebar-overlay").classList.add("active");
}

function _toggleSidebar() {
  const isHidden = $("sidebar").classList.contains("hidden");
  isHidden ? _openSidebar() : _closeSidebar();
}

if ($("btn-toggle-sidebar")) {
  $("btn-toggle-sidebar").addEventListener("click", _toggleSidebar);
}

// Tap overlay to close sidebar on mobile
$("sidebar-overlay").addEventListener("click", _closeSidebar);

// On mobile: start with sidebar hidden
if (_isMobile()) _closeSidebar();

// Mobile back button in chat-header: tap to go back to welcome
const _btnBack = document.querySelector(".chat-back-btn");
if (_btnBack) _btnBack.addEventListener("click", () => Router.navigate("welcome"));

// On mobile: shorten textarea placeholder so it doesn't wrap
if (_isMobile()) {
  const inp = $("user-input");
  if (inp) inp.setAttribute("placeholder", inp.placeholder.replace(/\s*[\(（].*[\)）]/, "").trim());
}

// On mobile: auto-close sidebar when switching sessions/pages
function _mobileCloseSidebar() {
  if (_isMobile()) _closeSidebar();
}

// ── New session split button [+ ▾] ────────────────────────────────────────
// btn-new-session-inline: click → create General session immediately
// btn-new-session-arrow:  click → toggle dropdown
// dropdown items:         click → create session with chosen agent_profile
// btn-new-project-entry:  click → open inline new-project form
if ($("btn-new-session-inline")) {
  $("btn-new-session-inline").addEventListener("click", () => Sessions.create("general"));
}
if ($("btn-new-session-arrow")) {
  $("btn-new-session-arrow").addEventListener("click", (e) => {
    e.stopPropagation();
    const dd = $("new-session-dropdown");
    if (dd) dd.hidden = !dd.hidden;
  });
}
// Dropdown item clicks
document.querySelectorAll("#new-session-dropdown .dropdown-item").forEach(item => {
  item.addEventListener("click", (e) => {
    e.stopPropagation();
    $("new-session-dropdown").hidden = true;

    // "New Project" entry — open inline form instead of creating immediately
    if (item.id === "btn-new-project-entry") {
      NewProjectForm.open();
      return;
    }

    const profile = item.dataset.profile || "general";
    Sessions.create(profile);
  });
});
// Close dropdown when clicking elsewhere
document.addEventListener("click", () => {
  const dd = $("new-session-dropdown");
  if (dd && !dd.hidden) dd.hidden = true;
});

$("btn-welcome-new").addEventListener("click", () => Sessions.create("general"));

// ── New Project inline form ────────────────────────────────────────────────
const NewProjectForm = {
  _defaultDir() {
    // Generate default dir like ~/clacky_projects/my-project
    return "~/clacky_projects/my-project";
  },

  open() {
    const panel = $("new-project-form");
    const input = $("new-project-dir");
    if (!panel) return;
    // Set default directory value
    if (input && !input.value) input.value = this._defaultDir();
    // Animate open
    panel.hidden = false;
    requestAnimationFrame(() => panel.classList.add("panel--open"));
    // Focus input and select the "my-project" part so user can rename easily
    if (input) {
      input.focus();
      const val = input.value;
      const lastSlash = val.lastIndexOf("/");
      if (lastSlash >= 0) {
        input.setSelectionRange(lastSlash + 1, val.length);
      } else {
        input.select();
      }
    }
  },

  close() {
    const panel = $("new-project-form");
    if (!panel) return;
    panel.classList.remove("panel--open");
    setTimeout(() => { panel.hidden = true; }, 200);
  },

  async submit() {
    const input = $("new-project-dir");
    const createBtn = $("btn-new-project-create");
    const dir = input ? input.value.trim() : "";
    if (!dir) { input && input.focus(); return; }

    // Derive session name from directory basename
    const basename = dir.replace(/\/$/, "").split("/").pop() || "Project";
    const name = basename;

    if (createBtn) createBtn.disabled = true;

    const res = await fetch("/api/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name,
        agent_profile: "coding",
        source: "manual",
        working_dir: dir
      })
    });
    const data = await res.json();

    if (createBtn) createBtn.disabled = false;

    if (!res.ok) {
      const msg = data.error || "unknown error";
      const friendly = res.status === 409
        ? I18n.t("sessions.dirNotEmpty")
        : I18n.t("sessions.createError") + msg;
      alert(friendly);
      return;
    }

    const session = data.session;
    if (!session) return;

    // Reset form for next use
    if (input) input.value = "";
    this.close();

    Sessions.add(session);
    Sessions.renderList();
    Sessions.select(session.id);
    // After subscribe is confirmed, auto-send /new to trigger the new-project skill
    Sessions.setPendingMessage(session.id, "/new");
  }
};

if ($("btn-new-project-cancel")) {
  $("btn-new-project-cancel").addEventListener("click", () => NewProjectForm.close());
}
if ($("btn-new-project-create")) {
  $("btn-new-project-create").addEventListener("click", () => NewProjectForm.submit());
}
// Enter key inside directory input
if ($("new-project-dir")) {
  $("new-project-dir").addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); NewProjectForm.submit(); }
    if (e.key === "Escape") { e.preventDefault(); NewProjectForm.close(); }
  });
}

// Load-more sessions button (dynamic — rendered by Sessions.renderList, use delegation)
document.addEventListener("click", e => {
  if (e.target && e.target.id === "btn-load-more-sessions") {
    Sessions.loadMore();
  }
});

// ── Session search bar ─────────────────────────────────────────────────────
// Magnifier toggle button
document.addEventListener("click", e => {
  if (e.target && e.target.closest("#btn-session-search-toggle")) {
    Sessions.toggleSearch();
  }
});

// Close button inside panel
document.addEventListener("click", e => {
  if (e.target && e.target.id === "btn-session-search-close") {
    if (Sessions.searchOpen) Sessions.toggleSearch();
  }
});

// Enter key → commitSearch
document.addEventListener("keydown", e => {
  if (e.key === "Enter" && e.target && e.target.id === "session-search-q") {
    e.preventDefault();
    Sessions.commitSearch();
  }
});

// Inline ✕ button — clear the q input and re-fetch
document.addEventListener("click", e => {
  if (e.target && e.target.id === "btn-search-q-clear") {
    const qEl = document.getElementById("session-search-q");
    if (qEl) qEl.value = "";
    Sessions.clearFilter("q");
  }
});

// Clear active filters (type + date) and re-fetch once
document.addEventListener("click", e => {
  if (e.target && e.target.id === "btn-search-clear-all") {
    const typeEl = document.getElementById("session-search-type");
    const dateEl = document.getElementById("session-search-date");
    if (typeEl) typeEl.value = "";
    if (dateEl) dateEl.value = "";
    Sessions.commitSearch();
  }
});

// Show/hide inline ✕ as user types in search input
document.addEventListener("input", e => {
  if (e.target && e.target.id === "session-search-q") {
    const btn = document.getElementById("btn-search-q-clear");
    if (btn) btn.hidden = !e.target.value;
  }
});

// Type select and date change → immediate commit (they're explicit choices, not typing)
document.addEventListener("change", e => {
  if (e.target && (e.target.id === "session-search-type" || e.target.id === "session-search-date")) {
    Sessions.commitSearch();
  }
});

// Theme toggle in header
if ($("theme-toggle-header")) {
  $("theme-toggle-header").addEventListener("click", () => Theme.toggle());
}
$("btn-delete-session").addEventListener("click", () => {
  if (Sessions.activeId) Sessions.deleteSession(Sessions.activeId);
});

// Load older history when the user scrolls to the top of the message list
$("messages").addEventListener("scroll", () => {
  const messages = $("messages");
  if (messages.scrollTop < 80 && Sessions.activeId && Sessions.hasMoreHistory(Sessions.activeId)) {
    Sessions.loadMoreHistory(Sessions.activeId);
  }
});
$("btn-send").addEventListener("click", sendMessage);
$("btn-interrupt").addEventListener("click", () =>
  WS.send({ type: "interrupt", session_id: Sessions.activeId })
);

$("btn-attach").addEventListener("click", () => $("image-file-input").click());

// / button: set input to "/" and open skill autocomplete
// mousedown + preventDefault prevents the textarea from losing focus (which would
// trigger the blur→hide timer and immediately close the dropdown we're about to open).
$("btn-slash").addEventListener("mousedown", e => {
  e.preventDefault();  // keep focus on user-input
});
$("btn-slash").addEventListener("click", () => {
  const input = $("user-input");
  if (input.value === "" || input.value === "/") {
    input.value = "/";
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 200) + "px";
  }
  SkillAC.toggle();  // Toggle dropdown instead of always opening
  if (SkillAC.visible) {
    $("btn-slash").classList.add("active");
  }
  input.focus();
});
$("image-file-input").addEventListener("change", e => {
  Array.from(e.target.files).forEach(_addAttachmentFile);
  e.target.value = "";
});

const inputArea = document.getElementById("input-area");
inputArea.addEventListener("dragover", e => {
  e.preventDefault();
  inputArea.classList.add("drag-over");
});
inputArea.addEventListener("dragleave", e => {
  if (!inputArea.contains(e.relatedTarget)) inputArea.classList.remove("drag-over");
});
inputArea.addEventListener("drop", e => {
  e.preventDefault();
  inputArea.classList.remove("drag-over");
  const ACCEPTED_ALL = [...ACCEPTED_IMAGE_TYPES, ...ACCEPTED_DOC_TYPES];
  const files = Array.from(e.dataTransfer.files).filter(f => ACCEPTED_ALL.includes(f.type));
  if (files.length === 0) return;
  files.forEach(_addAttachmentFile);
});

$("user-input").addEventListener("paste", e => {
  const items = Array.from(e.clipboardData?.items || []);
  const attachItems = items.filter(it => it.kind === "file" && [...ACCEPTED_IMAGE_TYPES, ...ACCEPTED_DOC_TYPES].includes(it.type));
  if (attachItems.length === 0) return;
  e.preventDefault();
  attachItems.forEach(it => _addAttachmentFile(it.getAsFile()));
});

// Cross-browser IME composition fix:
// Safari fires compositionend BEFORE keydown (violating W3C spec), and the
// gap between compositionend and keydown is ~5ms on Safari. We record the
// timestamp of compositionend and treat any Enter keydown within 20ms as
// still-composing. Chrome is unaffected because e.isComposing is still true.
// Reference: https://bugs.webkit.org/show_bug.cgi?id=165004
let _lastCompositionEndTime = -Infinity;
$("user-input").addEventListener("compositionend", () => {
  _lastCompositionEndTime = Date.now();
});

// Hide skill autocomplete when input loses focus (unless clicking a dropdown item)
$("user-input").addEventListener("blur", () => {
  // Small delay so mousedown on item fires first
  setTimeout(() => SkillAC.hide(), 150);
});

// ── Skill autocomplete ────────────────────────────────────────────────────
const SkillAC = (() => {
  let _visible        = false;
  let _activeIndex    = -1;
  let _items          = [];  // filtered [{ name, description, encrypted, source }]
  let _currentSession = null; // track active session id for live fetch

  /** Called whenever the active session changes — just store the id, no prefetch. */
  function _loadForSession(sessionId) {
    _currentSession = sessionId || null;
  }

  /** Fetch live skill list from server for the current session. */
  async function _fetchSkills() {
    if (!_currentSession) return [];
    try {
      const res  = await fetch(`/api/sessions/${_currentSession}/skills`);
      const data = await res.json();
      return data.skills || [];
    } catch (e) {
      console.error("[SkillAC] fetchSkills failed", e);
      return [];
    }
  }

  /** Return the /xxx prefix if the entire input is a slash command, else null. */
  function _getSlashQuery(value) {
    // Only activate when the whole input starts with / (no leading space)
    const trimmed = value;
    if (!trimmed.startsWith("/")) return null;
    // Only single-word slash token — no spaces allowed after /
    if (/^\/\S*$/.test(trimmed)) return trimmed.slice(1).toLowerCase();
    return null;
  }

  async function _render(query) {
    const all = await _fetchSkills();
    _items = all.filter(s => s.name.toLowerCase().startsWith(query));

    if (_items.length === 0) { _hide(); return; }

    const list = $("skill-autocomplete-list");
    list.innerHTML = "";

    // Header label
    const header = document.createElement("div");
    header.className = "skill-ac-header";
    header.textContent = I18n.t("sidebar.skills");
    list.appendChild(header);

    _items.forEach((skill, idx) => {
      const item = document.createElement("div");
      item.className = "skill-ac-item" + (idx === _activeIndex ? " active" : "");
      item.setAttribute("role", "option");
      item.setAttribute("data-idx", idx);

      const nameEl = document.createElement("span");
      nameEl.className = "skill-ac-name";
      nameEl.textContent = "/" + skill.name;

      // meta: encrypted badge + source type label (subtle)
      const metaEl = document.createElement("span");
      metaEl.className = "skill-ac-meta";
      if (skill.encrypted) {
        const encBadge = document.createElement("span");
        encBadge.className = "skill-ac-enc";
        encBadge.textContent = "🔒";
        metaEl.appendChild(encBadge);
      }
      const sourceLabel = {
        "default":        "built-in",
        "global_clacky":  "user",
        "global_claude":  "user",
        "project_clacky": "project",
        "project_claude": "project",
        "brand":          "brand",
      }[skill.source_type];
      if (sourceLabel) {
        const srcEl = document.createElement("span");
        srcEl.className = "skill-ac-src";
        srcEl.textContent = sourceLabel;
        metaEl.appendChild(srcEl);
      }

      const descEl = document.createElement("span");
      descEl.className = "skill-ac-desc";
      descEl.textContent = skill.description || "";

      item.appendChild(nameEl);
      item.appendChild(metaEl);
      item.appendChild(descEl);

      item.addEventListener("mousedown", e => {
        // mousedown fires before blur — prevent input losing focus
        e.preventDefault();
        _select(idx);
      });

      list.appendChild(item);
    });

    $("skill-autocomplete").style.display = "";
    _visible = true;
  }

  function _hide() {
    $("skill-autocomplete").style.display = "none";
    _visible     = false;
    _activeIndex = -1;
    _items       = [];
    $("btn-slash")?.classList.remove("active");
  }

  function _select(idx) {
    const skill = _items[idx];
    if (!skill) return;
    const input  = $("user-input");
    input.value  = "/" + skill.name + " ";
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 200) + "px";
    _hide();
    input.focus();
  }

  function _moveActive(delta) {
    if (!_visible || _items.length === 0) return;
    _activeIndex = (_activeIndex + delta + _items.length) % _items.length;
    // Re-render to apply active class
    const list  = $("skill-autocomplete-list");
    list.querySelectorAll(".skill-ac-item").forEach((el, i) => {
      el.classList.toggle("active", i === _activeIndex);
      if (i === _activeIndex) el.scrollIntoView({ block: "nearest" });
    });
  }

  /** Open the dropdown showing all skills, used by the / button. */
  async function _openAll() {
    _activeIndex = 0;  // Default to first item
    await _render("");
    $("user-input").focus();
  }

  /** Toggle the dropdown (open if hidden, close if visible). */
  async function _toggle() {
    if (_visible) {
      _hide();
    } else {
      await _openAll();
    }
  }

  return {
    get visible()      { return _visible; },
    get activeIndex()  { return _activeIndex; },

    /** Called on every `input` event — decide whether to show/hide/update. */
    update(value) {
      const query = _getSlashQuery(value);
      if (query === null) { _hide(); return; }
      _activeIndex = 0;  // Always highlight the first match
      _render(query);  // async, fire-and-forget
    },

    /** Open dropdown with all skills (triggered by / button). */
    openAll: _openAll,

    /** Toggle dropdown visibility (used by / button). */
    toggle: _toggle,

    /** Reload session-scoped skill list when the active session changes. */
    loadForSession: _loadForSession,

    /** Handle keyboard nav inside the dropdown. Returns true if event was consumed. */
    handleKey(e) {
      if (!_visible) return false;
      if (e.key === "ArrowDown") { e.preventDefault(); _moveActive(1);  return true; }
      if (e.key === "ArrowUp")   { e.preventDefault(); _moveActive(-1); return true; }
      if (e.key === "Escape")    { e.preventDefault(); _hide();         return true; }
      if (e.key === "Tab") {
        // Tab: select active item if one is highlighted, otherwise select first item
        e.preventDefault();
        const targetIdx = _activeIndex >= 0 ? _activeIndex : 0;
        _select(targetIdx);
        return true;
      }
      if (e.key === "Enter" && !e.isComposing && (Date.now() - _lastCompositionEndTime) > 20) {
        if (_activeIndex >= 0) {
          e.preventDefault();
          _select(_activeIndex);
          return true;
        }
        // No item highlighted — select first item if available
        if (_items.length > 0) {
          e.preventDefault();
          _select(0);
          return true;
        }
        // No items — let Enter fall through to sendMessage
        _hide();
        return false;
      }
      return false;
    },

    hide: _hide,
  };
})();

$("user-input").addEventListener("keydown", e => {
  // Let skill autocomplete consume arrow/enter/escape first
  if (SkillAC.handleKey(e)) return;

  if (e.key === "Enter" && !e.shiftKey && !e.isComposing && (Date.now() - _lastCompositionEndTime) > 20) {
    e.preventDefault();
    sendMessage();
  }
});

$("user-input").addEventListener("input", () => {
  const el = $("user-input");
  el.style.height = "auto";
  el.style.height = Math.min(el.scrollHeight, 200) + "px";
  // Trigger skill autocomplete
  SkillAC.update(el.value);
});

$("btn-settings").addEventListener("click", () => {
  if (Router.current === "settings") {
    Router.navigate("welcome");
  } else {
    Router.navigate("settings");
  }
});

$("tasks-sidebar-item").addEventListener("click", () => Router.navigate("tasks"));
$("skills-sidebar-item").addEventListener("click", () => Router.navigate("skills"));
$("channels-sidebar-item").addEventListener("click", () => Router.navigate("channels"));

$("btn-create-skill").addEventListener("click", () => Skills.createInSession());
$("btn-import-skill").addEventListener("click", () => Skills.toggleImportBar());

// ── Boot ──────────────────────────────────────────────────────────────────
Settings.init();
Channels.init();

// Boot sequence:
//   1. Brand check    — shows a dismissible top banner if license activation is needed.
//                       Never blocks boot; user can activate at any time via the banner.
//   2. Onboard check  — first-run setup (key_setup / soul_setup)
//   3. Normal UI boot — WS + sessions + tasks + skills
//
// key_setup  → hard block: shows full-screen setup-panel (language + API key).
//              On success, setup-panel auto-launches /onboard session then boots UI.
// soul_setup → soft: auto-launches /onboard session and boots UI immediately.
//              No blocking panel shown.

window.bootAfterBrand = async function() {
  const { needsOnboard, phase } = await Onboard.check();
  // key_setup blocks boot entirely; onboard.js calls _bootUI() when done.
  if (needsOnboard && phase === "key_setup") return;

  // soul_setup: Onboard.check() already launched the session and called _bootUI().
  // For any other state, boot normally here.
  if (!needsOnboard) {
    WS.connect();   // triggers session_list → Router.restoreFromHash()
    Tasks.load();
    Skills.load();
  }
};

(async () => {
  // Brand.check() now only shows a top banner when activation is needed;
  // it never returns true to block boot, so we always continue to bootAfterBrand().
  await Brand.check();
  await window.bootAfterBrand();
})();

// ── Image Lightbox ────────────────────────────────────────────────────────────
// Global lightbox: click any .msg-image-thumb to open; click backdrop or ✕ or
// press ESC to close.
(function () {
  let _overlay = null;

  function _open(src, alt) {
    if (_overlay) return;
    _overlay = document.createElement("div");
    _overlay.className = "img-lightbox";
    _overlay.innerHTML =
      `<span class="img-lightbox-close" title="Close">✕</span>` +
      `<img src="${src}" alt="${alt || "image"}">`;

    // Click on backdrop or ✕ → close
    _overlay.addEventListener("click", function (e) {
      if (e.target === _overlay || e.target.classList.contains("img-lightbox-close")) {
        _close();
      }
    });

    document.body.appendChild(_overlay);
  }

  function _close() {
    if (_overlay) { _overlay.remove(); _overlay = null; }
  }

  // ESC key closes lightbox
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") _close();
  });

  // Event delegation: any click on .msg-image-thumb anywhere in the page
  document.addEventListener("click", function (e) {
    if (e.target.classList.contains("msg-image-thumb")) {
      _open(e.target.src, e.target.alt);
    }
  });
})();
