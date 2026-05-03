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
  "trash-panel",
  "profile-panel",
  "settings-panel",
  "creator-panel",
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
    if (h === "trash")                return { view: "trash",    params: {} };
    if (h === "profile")              return { view: "profile",  params: {} };
    // Legacy: #memories redirects to #profile (memories are now merged into
    // the profile panel). Kept so bookmarks / external links don't 404.
    if (h === "memories")             return { view: "profile",  params: {} };
    if (h === "settings")             return { view: "settings", params: {} };
    if (h === "creator")              return { view: "creator",  params: {} };
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
    trash:    "trash-sidebar-item",
    profile:  "profile-sidebar-item",
    creator:  "creator-sidebar-item",
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
        Sessions.updateChatHeader(s);
        Sessions.updateStatusBar(s.status);
        Sessions.updateInfoBar(s);
        Sessions._restoreMessagesPublic(id);
        Sessions._setActiveId(id);
        // Immediately re-attach saved progress UI (timer + spinner) so it appears
        // instantly without waiting for the async history fetch or WS replay.
        Sessions._attachProgressUI(id);
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

      case "trash":
        _setHash("trash");
        $("trash-panel").style.display = "flex";
        Trash.onPanelShow();
        Sessions.renderList();
        break;

      case "profile":
        _setHash("profile");
        $("profile-panel").style.display = "flex";
        Profile.onPanelShow();
        Sessions.renderList();
        break;

      case "creator":
        _setHash("creator");
        $("creator-panel").style.display = "flex";
        Creator.onPanelShow();
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

  /** Show a text input prompt dialog. Returns a Promise<string|null>. */
  function prompt(message, defaultValue = "") {
    return new Promise(resolve => {
      $("prompt-modal-message").textContent = message;
      const input = $("prompt-modal-input");
      input.value = defaultValue;
      $("prompt-modal-overlay").style.display = "flex";
      
      // Auto-focus and select all text
      setTimeout(() => {
        input.focus();
        input.select();
      }, 50);

      const cleanup = (result) => {
        $("prompt-modal-overlay").style.display = "none";
        $("prompt-modal-ok").onclick = null;
        $("prompt-modal-cancel").onclick = null;
        input.onkeydown = null;
        resolve(result);
      };

      $("prompt-modal-ok").onclick = () => cleanup(input.value.trim() || null);
      $("prompt-modal-cancel").onclick = () => cleanup(null);
      
      // Support Enter to confirm, Escape to cancel
      input.onkeydown = (e) => {
        if (e.key === "Enter") cleanup(input.value.trim() || null);
        if (e.key === "Escape") cleanup(null);
      };
    });
  }

  return { confirm, prompt };
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
  console.log("[DEBUG] WS event received:", ev.type, ev);
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
      Sessions.clearAllProgress();
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
        if (ev.cost    !== undefined) patch.total_cost     = ev.cost;
        if (ev.tasks   !== undefined) patch.total_tasks    = ev.tasks;
        if (ev.status  !== undefined) patch.status         = ev.status;
        // Latency pushed by Agent after each LLM call (see update_sessionbar).
        // Stored under latest_latency — same field name the HTTP /api/sessions
        // list returns, so updateInfoBar doesn't need to branch on the source.
        if (ev.latency !== undefined) patch.latest_latency = ev.latency;
      }
      if (!sid) break;
      Sessions.patch(sid, patch);
      Sessions.renderList();
      if (sid === Sessions.activeId) {
        const current = Sessions.find(sid);
        if (patch.status !== undefined) Sessions.updateStatusBar(patch.status);
        Sessions.updateInfoBar(current);
        // Update chat title/subtitle in case session was renamed or working_dir changed
        Sessions.updateChatHeader(current);
      }
      // When a session finishes, refresh tasks and skills, and clear any progress state
      if (patch.status === "idle") {
        Tasks.load();
        Skills.load();
        // Clear progress state for this session (even if not currently active)
        Sessions.clearProgress(sid);
      }
      break;
    }

    case "session_renamed": {
      Sessions.patch(ev.session_id, { name: ev.name });
      Sessions.renderList();
      // Title is now shown only in the sidebar; chat-header element was removed.
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
      console.log("[DEBUG] progress event:", ev);
      if (ev.session_id !== Sessions.activeId) break;
      if (ev.phase === "active" || ev.status === "start") {
        const progress_type = ev.progress_type || "thinking";
        const metadata = ev.metadata || {};
        console.log("[DEBUG] calling showProgress:", { message: ev.message, progress_type, metadata, started_at: ev.started_at });
        Sessions.showProgress(ev.message, progress_type, metadata, ev.started_at || null);
      } else {
        console.log("[DEBUG] calling clearProgress:", ev.message);
        Sessions.clearProgress(ev.message);
      }
      break;

    case "complete":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.collapseToolGroup();
      {
        const costSource = ev.cost_source;
        const costDisplay = (!costSource || costSource === "estimated")
          ? "N/A"
          : `$${(ev.cost || 0).toFixed(4)}`;
        Sessions.appendInfo(`✓ ${I18n.t("chat.done", { n: ev.iterations, cost: costDisplay })}`);
      }
      break;

    case "request_feedback":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.showFeedbackRequest(ev.question, ev.context, ev.options);
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
    case "info":
      Sessions.appendInfo(ev.message);
      break;

    case "warning":
      // Optimize retry messages for better UX
      const friendlyWarning = _transformRetryWarning(ev.message);
      if (friendlyWarning) {
        Sessions.appendInfo(friendlyWarning);
      }
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
  "application/gzip",
  "application/x-gzip",
  "application/x-tar",
  "application/x-compressed-tar",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document", // .docx
  "application/msword",                                                        // .doc
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",        // .xlsx
  "application/vnd.ms-excel",                                                  // .xls
  "application/vnd.openxmlformats-officedocument.presentationml.presentation", // .pptx
  "application/vnd.ms-powerpoint",                                             // .ppt
  "text/csv",                                                                  // .csv
  "application/csv",                                                           // .csv (some browsers)
  "text/markdown",                                                             // .md
  "text/x-markdown",                                                           // .md (some browsers)
  "text/plain",                                                                // .md / .txt (many browsers report this)
];

// Extension-based fallback for files whose MIME type is missing or unreliable.
// Browsers frequently report "" or "application/octet-stream" for .md / .tar.gz.
const ACCEPTED_DOC_EXTENSIONS = [
  ".pdf", ".zip",
  ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
  ".csv",
  ".md", ".markdown", ".txt", ".log",
  ".tar", ".gz", ".tgz", ".tar.gz", ".rar", ".7z"
];

function _hasAcceptedDocExt(filename) {
  const lower = (filename || "").toLowerCase();
  return ACCEPTED_DOC_EXTENSIONS.some(ext => lower.endsWith(ext));
}

function _isAcceptedDoc(file) {
  if (!file) return false;
  if (file.type && ACCEPTED_DOC_TYPES.includes(file.type)) return true;
  return _hasAcceptedDocExt(file.name);
}

function _isAcceptedImage(file) {
  if (!file) return false;
  return ACCEPTED_IMAGE_TYPES.includes(file.type);
}

function _isAcceptedFile(file) {
  return _isAcceptedImage(file) || _isAcceptedDoc(file);
}

function _docTypeIcon(mimeType, filename) {
  const lower = (filename || "").toLowerCase();
  if (mimeType === "application/pdf" || lower.endsWith(".pdf")) return "📄";
  if (mimeType === "application/zip" || mimeType === "application/x-zip-compressed" || lower.endsWith(".zip")) return "🗜️";
  if (mimeType === "application/gzip" || mimeType === "application/x-gzip" ||
      mimeType === "application/x-tar" || mimeType === "application/x-compressed-tar" ||
      lower.endsWith(".tar") || lower.endsWith(".gz") || lower.endsWith(".tgz") || lower.endsWith(".tar.gz") ||
      lower.endsWith(".rar") || lower.endsWith(".7z")) return "🗜️";
  if ((mimeType && mimeType.includes("wordprocessingml")) || mimeType === "application/msword" ||
      lower.endsWith(".doc") || lower.endsWith(".docx")) return "📝";
  if ((mimeType && mimeType.includes("spreadsheetml")) || mimeType === "application/vnd.ms-excel" ||
      lower.endsWith(".xls") || lower.endsWith(".xlsx")) return "📊";
  if ((mimeType && mimeType.includes("presentationml")) || mimeType === "application/vnd.ms-powerpoint" ||
      lower.endsWith(".ppt") || lower.endsWith(".pptx")) return "📋";
  if (mimeType === "text/csv" || mimeType === "application/csv" || lower.endsWith(".csv")) return "📊";
  if (mimeType === "text/markdown" || mimeType === "text/x-markdown" ||
      lower.endsWith(".md") || lower.endsWith(".markdown")) return "📝";
  if (mimeType === "text/plain" || lower.endsWith(".txt") || lower.endsWith(".log")) return "📄";
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
  // Route by content category. Images must match known image MIME types
  // (MIME is reliable for images). Documents fall back to extension-based
  // detection because browsers frequently report "" or "application/octet-stream"
  // for .md / .tar.gz files.
  if (_isAcceptedImage(file)) {
    _addImageFile(file);
  } else if (_isAcceptedDoc(file)) {
    _addGenericFile(file);
  } else {
    // Unknown type — surface a helpful error instead of silently rejecting.
    alert(`Unsupported file: ${file.name}\nSupported: images (PNG/JPG/GIF/WEBP), PDF, Office (DOC/XLS/PPT), ZIP, TAR, TAR.GZ, MD, TXT, CSV`);
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
    icon.textContent = _docTypeIcon(f.mime_type, f.name);

    const info = document.createElement("div");
    info.className = "pdf-preview-info";

    const name = document.createElement("div");
    name.className = "pdf-preview-name";
    name.textContent = f.name;

    const typeLabel = document.createElement("div");
    typeLabel.className = "pdf-preview-type";
    const _lowerName = (f.name || "").toLowerCase();
    typeLabel.textContent = _lowerName.endsWith(".tar.gz")
      ? "TAR.GZ"
      : (f.name.split(".").pop() || "file").toUpperCase();

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

// Mobile floating back button (visible only on mobile via CSS): tap to go back to welcome.
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
// Main button: quick create (like before)
// Arrow button: show dropdown with "Advanced Options..." to open modal
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
// Dropdown item: Advanced Options → open modal
document.addEventListener("click", (e) => {
  if (e.target && e.target.id === "btn-new-session-modal") {
    e.stopPropagation();
    $("new-session-dropdown").hidden = true;
    Sessions.openNewSessionModal();
  }
});
// Close dropdown when clicking elsewhere
document.addEventListener("click", () => {
  const dd = $("new-session-dropdown");
  if (dd && !dd.hidden) dd.hidden = true;
});

$("btn-welcome-new").addEventListener("click", () => Sessions.create("general"));

// ── New Session Modal event handlers ───────────────────────────────────────
if ($("new-session-modal-close")) {
  $("new-session-modal-close").addEventListener("click", () => Sessions.closeNewSessionModal());
}
if ($("new-session-cancel")) {
  $("new-session-cancel").addEventListener("click", () => Sessions.closeNewSessionModal());
}
if ($("new-session-create")) {
  $("new-session-create").addEventListener("click", () => Sessions.createFromModal());
}
// Close modal when clicking overlay
if ($("new-session-modal")) {
  $("new-session-modal").addEventListener("click", (e) => {
    if (e.target.id === "new-session-modal") {
      Sessions.closeNewSessionModal();
    }
  });
}
// Browse button (placeholder - actual file browsing would need native integration)
if ($("new-session-browse-btn")) {
  $("new-session-browse-btn").addEventListener("click", () => {
    alert("Tip: Enter your desired path directly, e.g., ~/clacky_workspace/my-project");
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
// btn-delete-session was removed with chat-header; deletion is now triggered from
// the bottom session-info-bar actions dropdown (see Sessions._showActionsMenu).
const _btnDeleteSession = $("btn-delete-session");
if (_btnDeleteSession) {
  _btnDeleteSession.addEventListener("click", () => {
    if (Sessions.activeId) Sessions.deleteSession(Sessions.activeId);
  });
}

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
  const files = Array.from(e.dataTransfer.files).filter(_isAcceptedFile);
  if (files.length === 0) return;
  files.forEach(_addAttachmentFile);
});

$("user-input").addEventListener("paste", e => {
  const items = Array.from(e.clipboardData?.items || []);
  // Paste filter: any file-kind item that's an image, or a document whose
  // type/name passes our doc filter. Must check name via getAsFile() for
  // markdown/tar.gz (browsers often leave item.type empty for these).
  const attachItems = items.filter(it => {
    if (it.kind !== "file") return false;
    if (ACCEPTED_IMAGE_TYPES.includes(it.type)) return true;
    if (ACCEPTED_DOC_TYPES.includes(it.type))   return true;
    // Last resort: check filename extension on the actual File object.
    const f = it.getAsFile && it.getAsFile();
    return f ? _hasAcceptedDocExt(f.name) : false;
  });
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

// ── Skill autocomplete ────────────────────────────────────────────────────
const SkillAC = (() => {
  let _visible        = false;
  let _activeIndex    = -1;
  let _items          = [];  // filtered [{ name, description, encrypted, source }]
  let _currentSession = null; // track active session id for live fetch
  
  // Load from localStorage, default to false (hide system skills)
  let _showSystemSkills = localStorage.getItem("skill-ac-show-system") === "true";

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
    // Full-width slash / dunhao are already replaced in the input event handler,
    // but guard here too in case value is passed programmatically.
    let trimmed = value.replace(/^[／、]/, "/");

    // Only activate when the whole input starts with / (no leading space)
    if (!trimmed.startsWith("/")) return null;
    // Only single-word slash token — no spaces allowed after /
    if (/^\/\S*$/.test(trimmed)) return trimmed.slice(1).toLowerCase();
    return null;
  }

  /**
   * Score how well a skill matches the query string.
   * Only matches against name and name_zh — description is intentionally excluded.
   * All matches are contiguous substring matches (no fuzzy/subsequence).
   * Returns 0 if no match (should be filtered out).
   *
   * Scoring tiers:
   *   100 — name or name_zh exact match
   *    80 — name or name_zh starts-with
   *    60 — name or name_zh contains
   *     0 — no match
   */
  function _scoreMatch(skill, query) {
    if (!query) return 50; // empty query → show all with neutral score

    const q    = query.toLowerCase();
    const name = (skill.name || "").toLowerCase();
    const zh   = (skill.name_zh || "").toLowerCase();

    // Exact match
    if (name === q || zh === q) return 100;

    // Prefix match
    if (name.startsWith(q) || zh.startsWith(q)) return 80;

    // Contains match (contiguous substring)
    if (name.includes(q) || zh.includes(q)) return 60;

    return 0;
  }

  /**
   * Wrap the matching substring in <mark> for highlighting.
   * Returns an array of DOM nodes (text + mark nodes).
   */
  function _highlight(text, query) {
    if (!query) return [document.createTextNode(text)];
    const idx = text.toLowerCase().indexOf(query.toLowerCase());
    if (idx === -1) return [document.createTextNode(text)];

    const nodes = [];
    if (idx > 0) nodes.push(document.createTextNode(text.slice(0, idx)));
    const mark = document.createElement("span");
    mark.className = "skill-ac-highlight";
    mark.textContent = text.slice(idx, idx + query.length);
    nodes.push(mark);
    if (idx + query.length < text.length) {
      nodes.push(document.createTextNode(text.slice(idx + query.length)));
    }
    return nodes;
  }

  async function _render(query) {
    const all = await _fetchSkills();

    // Score and filter
    let scored = all
      .map(s => ({ skill: s, score: _scoreMatch(s, query) }))
      .filter(({ score }) => score > 0);

    if (!_showSystemSkills) {
      scored = scored.filter(({ skill }) => skill.source_type !== "default");
    }

    // Sort by score descending, stable secondary sort by name
    scored.sort((a, b) => b.score - a.score || a.skill.name.localeCompare(b.skill.name));

    _items = scored.map(({ skill }) => skill);

    const list = $("skill-autocomplete-list");
    list.innerHTML = "";

    if (_items.length === 0) {
      // Show empty state instead of hiding the dropdown
      const emptyEl = document.createElement("div");
      emptyEl.className = "skill-ac-empty";
      emptyEl.textContent = I18n.t("skills.ac.empty");
      list.appendChild(emptyEl);
      $("skill-autocomplete").style.display = "";
      _visible = true;
      _createOverlay();
      return;
    }

    _items.forEach((skill, idx) => {
      const item = document.createElement("div");
      item.className = "skill-ac-item" + (idx === _activeIndex ? " active" : "");
      item.setAttribute("role", "option");
      item.setAttribute("data-idx", idx);

      const nameEl = document.createElement("span");
      nameEl.className = "skill-ac-name";

      const currentLangForName = I18n.lang();
      const showZhFirst = currentLangForName === "zh" && skill.name_zh;

      if (showZhFirst) {
        // Chinese UI: /中文名 first (with slash), then english id (no slash) after
        const zhEl = document.createElement("span");
        zhEl.className = "skill-ac-name-zh";
        zhEl.appendChild(document.createTextNode("/"));
        _highlight(skill.name_zh, query).forEach(function(n) { zhEl.appendChild(n); });
        nameEl.appendChild(zhEl);

        const nameTextEl = document.createElement("span");
        nameTextEl.className = "skill-ac-name-id";
        _highlight(skill.name, query).forEach(function(n) { nameTextEl.appendChild(n); });
        nameEl.appendChild(nameTextEl);
      } else {
        // English UI (or no zh name): show /id only, no zh name
        const nameTextEl = document.createElement("span");
        nameTextEl.appendChild(document.createTextNode("/"));
        _highlight(skill.name, query).forEach(function(n) { nameTextEl.appendChild(n); });
        nameEl.appendChild(nameTextEl);
      }

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
      // Choose description based on current language
      const description = (currentLangForName === "zh" && skill.description_zh)
                          ? skill.description_zh
                          : skill.description || "";
      descEl.textContent = description;

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
    _createOverlay();
  }

  function _hide() {
    $("skill-autocomplete").style.display = "none";
    _visible     = false;
    _activeIndex = -1;
    _items       = [];
    $("btn-slash")?.classList.remove("active");
    _removeOverlay();
  }
  
  function _createOverlay() {
    // Remove existing overlay if any
    _removeOverlay();
    
    const overlay = document.createElement("div");
    overlay.id = "skill-ac-overlay";
    overlay.style.cssText = "position: fixed; top: 0; left: 0; right: 0; bottom: 0; z-index: 999; background: transparent;";
    
    // Click overlay to close dropdown
    overlay.addEventListener("click", () => {
      _hide();
    });
    
    document.body.appendChild(overlay);
  }
  
  function _removeOverlay() {
    const overlay = document.getElementById("skill-ac-overlay");
    if (overlay) overlay.remove();
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

    /** Initialize event listeners (call once on page load). */
    init() {
      const chk = $("chk-ac-show-system-skills");
      
      if (chk) {
        // Restore state from localStorage
        chk.checked = _showSystemSkills;
        
        chk.addEventListener("change", async () => {
          _showSystemSkills = chk.checked;
          // Persist to localStorage
          localStorage.setItem("skill-ac-show-system", _showSystemSkills ? "true" : "false");
          
          // If dropdown is visible, re-fetch and re-render
          if (_visible) {
            const input = $("user-input");
            const query = _getSlashQuery(input.value);
            if (query !== null) {
              await _render(query);
            }
          }
        });
      }
    },

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

    /** Hide the dropdown. */
    hide: _hide,

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

  // Replace full-width slash ／ or Chinese dunhao 、 with ASCII / in-place
  if (/^[／、]/.test(el.value)) {
    const pos = el.selectionStart;
    el.value = el.value.replace(/^[／、]/, "/");
    el.setSelectionRange(pos, pos);
  }

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
$("trash-sidebar-item").addEventListener("click", () => Router.navigate("trash"));
$("profile-sidebar-item").addEventListener("click", () => Router.navigate("profile"));
// memories-sidebar-item is retained as a hidden legacy placeholder — no click handler.
// creator-sidebar-item is only present when user_licensed — guard with ?
document.getElementById("creator-sidebar-item")?.addEventListener("click", () => Router.navigate("creator"));

$("btn-create-skill").addEventListener("click", () => Skills.createInSession());
$("btn-import-skill").addEventListener("click", () => Skills.toggleImportBar());

// ── Boot ──────────────────────────────────────────────────────────────────
Settings.init();
Channels.init();
Sessions.init();

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

  // Show creator sidebar entry if user_licensed
  Creator.updateSidebarVisibility();

  // Initialize skill autocomplete
  SkillAC.init();

  // soul_setup: Onboard.check() already launched the session and called _bootUI().
  // For any other state, boot normally here.
  if (!needsOnboard) {
    // Auth already checked at app boot — safe to make API calls
    WS.connect();
    Tasks.load();
    Skills.load();
  }
};

(async () => {
  // Auth check MUST run first — all API calls depend on it
  const authOk = await Auth.check();
  if (!authOk) {
    // User cancelled auth prompt — stop boot
    return;
  }

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

// ── Session Info Bar Model Switcher ───────────────────────────────────────
(function() {
  let _isOpen = false;
  // Cache of the most recent benchmark results, keyed by model_id. Kept at
  // closure scope so the numbers survive closing & reopening the dropdown —
  // the user shouldn't have to re-run the test just to peek at results. We
  // intentionally do NOT persist this to disk: latency is a point-in-time
  // measurement, and yesterday's numbers are misleading.
  let _benchCache = {};        // { [model_id]: { ttft_ms, ok, error, ts } }
  let _benchInFlight = false;  // prevent double-click spam

  // Toggle model dropdown when clicking on model name
  document.addEventListener("click", async (e) => {
    const modelEl = e.target.closest("#sib-model");
    if (modelEl) {
      e.stopPropagation();
      const dropdown = $("sib-model-dropdown");
      if (!dropdown) return;

      if (_isOpen) {
        dropdown.style.display = "none";
        _isOpen = false;
      } else {
        await _populateModelDropdown(modelEl.dataset.sessionId, modelEl.textContent.trim());
        
        // Calculate position relative to the model element (fixed positioning)
        const rect = modelEl.getBoundingClientRect();
        dropdown.style.left = `${rect.left + rect.width / 2}px`;
        dropdown.style.top = `${rect.top - 6}px`; // 6px above the element
        dropdown.style.transform = "translate(-50%, -100%)"; // Center horizontally, move up by its own height
        
        dropdown.style.display = "block";
        _isOpen = true;
      }
      return;
    }

    // Close dropdown when clicking outside
    if (_isOpen && !e.target.closest(".sib-model-dropdown")) {
      const dropdown = $("sib-model-dropdown");
      if (dropdown) dropdown.style.display = "none";
      _isOpen = false;
    }
  });

  // Populate dropdown with available models
  async function _populateModelDropdown(sessionId, currentModel) {
    const dropdown = $("sib-model-dropdown");
    if (!dropdown) return;

    try {
      console.log("[Model Switcher] Fetching /api/config...");
      const res = await fetch("/api/config");
      const data = await res.json();
      console.log("[Model Switcher] Received data:", data);
      const models = data.models || [];
      console.log("[Model Switcher] Models count:", models.length);

      if (models.length === 0) {
        dropdown.innerHTML = '<div style="padding:12px;text-align:center;color:var(--color-text-secondary);font-size:11px;">No models configured</div>';
        return;
      }

      dropdown.innerHTML = "";

      // ── Benchmark floating button (top-right of dropdown) ──────────────
      // Tiny ⚡ button pinned to the dropdown's top-right corner. Runs one
      // concurrent request per model and back-fills each row's latency cell.
      // We deliberately avoid a full-width banner — it ate visual space that
      // the model list needs, and most users open the dropdown to SWITCH,
      // not to benchmark. The floating button is discoverable but unobtrusive.
      const bench = document.createElement("div");
      bench.className = "sib-model-bench";
      const btnLabel   = (typeof I18n !== "undefined") ? I18n.t("sib.bench.btn")     : "Benchmark";
      const btnTooltip = (typeof I18n !== "undefined") ? I18n.t("sib.bench.tooltip") : "Test response latency for every configured model";
      bench.innerHTML = `
        <button type="button" class="sib-bench-btn" title="${btnTooltip}">⚡ <span class="sib-bench-label">${btnLabel}</span></button>
        <span class="sib-bench-hint"></span>
      `;
      dropdown.appendChild(bench);

      const benchBtn   = bench.querySelector(".sib-bench-btn");
      const benchLabel = bench.querySelector(".sib-bench-label");
      const benchHint  = bench.querySelector(".sib-bench-hint");
      benchBtn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        _runBenchmark(sessionId, dropdown, benchBtn, benchLabel, benchHint);
      });

      // ── Model rows ─────────────────────────────────────────────────────
      models.forEach(m => {
        console.log("[Model Switcher] Adding model:", m.model, "id:", m.id, "current:", currentModel);
        const opt = document.createElement("div");
        opt.className = "sib-model-option";
        opt.dataset.modelId = m.id;
        if (m.model === currentModel) opt.classList.add("current");

        const left = document.createElement("span");
        left.className = "sib-model-name";
        left.textContent = m.model;
        opt.appendChild(left);

        const right = document.createElement("span");
        right.className = "sib-model-right";

        if (m.type === "default") {
          const badge = document.createElement("span");
          badge.className = `model-badge ${m.type}`;
          badge.textContent = m.type;
          right.appendChild(badge);
        }

        // Latency cell — populated from _benchCache on open, updated live
        // when a benchmark run completes. Empty slot keeps row heights stable
        // so the list doesn't visually jump mid-benchmark.
        const lat = document.createElement("span");
        lat.className = "sib-model-latency";
        _fillLatencyCell(lat, _benchCache[m.id]);
        right.appendChild(lat);

        opt.appendChild(right);

        // Switch by id (stable across reorders/edits). Keep model name for UI update.
        opt.addEventListener("click", () => _switchModel(sessionId, m.id, m.model));
        dropdown.appendChild(opt);
      });
      console.log("[Model Switcher] Dropdown populated, children count:", dropdown.children.length);
    } catch (e) {
      console.error("Failed to load models:", e);
      dropdown.innerHTML = '<div style="padding:12px;text-align:center;color:var(--color-error);font-size:11px;">Error loading models</div>';
    }
  }

  // Render one latency cell based on a cached result.
  //   undefined    → empty slot (never tested / in-flight starts from here)
  //   { ok:true }  → "812ms" in green/amber/red per threshold
  //   { ok:false } → "✕" with error in tooltip
  //   { pending:true } → "…" spinner-ish marker
  function _fillLatencyCell(el, entry) {
    el.className = "sib-model-latency";
    el.textContent = "";
    el.removeAttribute("title");
    if (!entry) return;
    if (entry.pending) {
      el.textContent = "…";
      el.classList.add("is-pending");
      return;
    }
    if (!entry.ok) {
      el.textContent = "✕";
      el.classList.add("is-err");
      el.title = entry.error || "failed";
      return;
    }
    const ms = entry.ttft_ms;
    // Same thresholds as the sib-signal status bar — keep them aligned so
    // "3 bars in the status bar" ≈ "green number in the picker".
    // We measure full non-streaming response time (not real TTFT), so ≤60s is
    // normal, ≤120s is slow, beyond is bad. ≤2s still gets the "feels instant"
    // green treatment like the 4-bar signal.
    let cls = "is-bad";
    if      (ms <= 2000)   cls = "is-ok";
    else if (ms <= 60000)  cls = "is-ok";
    else if (ms <= 120000) cls = "is-warn";
    el.classList.add(cls);
    el.textContent = ms >= 1000 ? (ms / 1000).toFixed(1) + "s" : ms + "ms";
    if (typeof I18n !== "undefined") {
      el.title = I18n.t("sib.bench.latencyTooltip", {
        ttft: el.textContent,
        time: new Date(entry.ts).toLocaleTimeString(),
      });
    } else {
      el.title = `TTFT ${el.textContent} · tested ${new Date(entry.ts).toLocaleTimeString()}`;
    }
  }

  async function _runBenchmark(sessionId, dropdown, btn, label, hint) {
    if (_benchInFlight) return;
    _benchInFlight = true;
    btn.disabled = true;
    const origLabel = label.textContent;
    const _t = (key, vars) => (typeof I18n !== "undefined") ? I18n.t(key, vars) : key;
    label.textContent = _t("sib.bench.running");
    hint.textContent = "";

    // Mark every row as pending so the user sees instant feedback instead of
    // a silent button. _fillLatencyCell handles the visual treatment.
    dropdown.querySelectorAll(".sib-model-option").forEach(opt => {
      const id = opt.dataset.modelId;
      if (!id) return;
      _benchCache[id] = { pending: true };
      _fillLatencyCell(opt.querySelector(".sib-model-latency"), _benchCache[id]);
    });

    const t0 = performance.now();
    try {
      const res = await fetch(`/api/sessions/${sessionId}/benchmark`, { method: "POST" });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "benchmark failed");

      const now = Date.now();
      (data.results || []).forEach(r => {
        _benchCache[r.model_id] = {
          ok: !!r.ok,
          ttft_ms: r.ttft_ms,
          error: r.error,
          ts: now,
        };
        const opt = dropdown.querySelector(`.sib-model-option[data-model-id="${CSS.escape(r.model_id)}"]`);
        if (opt) _fillLatencyCell(opt.querySelector(".sib-model-latency"), _benchCache[r.model_id]);
      });

      const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
      hint.textContent = _t("sib.bench.done", { t: elapsed });
    } catch (e) {
      console.error("Benchmark failed:", e);
      hint.textContent = _t("sib.bench.failed", { msg: e.message });
      // Clear pending markers so rows don't stay stuck on "…"
      dropdown.querySelectorAll(".sib-model-option").forEach(opt => {
        const id = opt.dataset.modelId;
        if (id && _benchCache[id]?.pending) {
          _benchCache[id] = undefined;
          _fillLatencyCell(opt.querySelector(".sib-model-latency"), undefined);
        }
      });
    } finally {
      _benchInFlight = false;
      btn.disabled = false;
      label.textContent = origLabel;
    }
  }

  // Switch session model via API
  // modelId — stable runtime id (required by backend)
  // modelName — display name, used for optimistic UI update
  async function _switchModel(sessionId, modelId, modelName) {
    const dropdown = $("sib-model-dropdown");
    if (dropdown) {
      dropdown.style.display = "none";
      _isOpen = false;
    }

    try {
      const res = await fetch(`/api/sessions/${sessionId}/model`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model_id: modelId })
      });

      const data = await res.json();

      if (!res.ok) {
        throw new Error(data.error || "Unknown error");
      }

      // Update UI optimistically (will be confirmed by session_update broadcast)
      const sibModel = $("sib-model");
      if (sibModel) sibModel.textContent = modelName;

      console.log(`Switched session ${sessionId} to model ${modelName} (${modelId})`);
    } catch (e) {
      console.error("Failed to switch model:", e);
      alert("Failed to switch model: " + e.message);
    }
  }
})();

// ── Session Info Bar Working Directory Switcher ───────────────────────────
(function() {
  // Handle click on working directory
  document.addEventListener("click", async (e) => {
    const dirEl = e.target.closest("#sib-dir");
    if (dirEl) {
      e.stopPropagation();
      const sessionId = dirEl.dataset.sessionId;
      const currentDir = dirEl.title.replace(" (click to change)", "");
      
      const newDir = await Modal.prompt("Change working directory:", currentDir);
      if (newDir && newDir !== currentDir) {
        _changeWorkingDirectory(sessionId, newDir);
      }
    }

    // Handle click on session ID — toggles a small actions dropdown with
    // items like "Download session files (for debugging)". Designed to be
    // extensible (more session-level actions can be added here later).
    const sibIdEl = e.target.closest("#sib-id");
    if (sibIdEl) {
      e.stopPropagation();
      const sessionId = sibIdEl.dataset.sessionId;
      if (!sessionId) return;
      _toggleSessionActionsDropdown(sibIdEl, sessionId);
      return;
    }

    // Handle click on an item inside the actions dropdown.
    const actionItem = e.target.closest(".sib-actions-item");
    if (actionItem) {
      e.stopPropagation();
      const action = actionItem.dataset.action;
      const sessionId = actionItem.dataset.sessionId;
      _closeSessionActionsDropdown();
      if (action === "download" && sessionId) {
        _downloadSessionBundle(sessionId, actionItem);
      }
      return;
    }

    // Click outside — close the actions dropdown if open.
    if (!e.target.closest("#sib-actions-dropdown")) {
      _closeSessionActionsDropdown();
    }
  });

  // Close dropdown on Escape.
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") _closeSessionActionsDropdown();
  });

  function _closeSessionActionsDropdown() {
    const dd = $("sib-actions-dropdown");
    if (dd && dd.style.display !== "none") dd.style.display = "none";
  }

  function _toggleSessionActionsDropdown(anchorEl, sessionId) {
    const dd = $("sib-actions-dropdown");
    if (!dd) return;

    // If already open for this session, close it (toggle behaviour).
    if (dd.style.display !== "none" && dd.dataset.sessionId === sessionId) {
      dd.style.display = "none";
      return;
    }

    _populateSessionActionsDropdown(dd, sessionId);
    dd.dataset.sessionId = sessionId;

    // Position the dropdown above the session ID element (same pattern as
    // the model switcher — fixed positioning, centered horizontally).
    const rect = anchorEl.getBoundingClientRect();
    dd.style.left = `${rect.left + rect.width / 2}px`;
    dd.style.top = `${rect.top - 6}px`;
    dd.style.transform = "translate(-50%, -100%)";
    dd.style.display = "block";
  }

  function _populateSessionActionsDropdown(dd, sessionId) {
    const t = (key, fallback) => (window.I18n && I18n.t(key)) || fallback;
    dd.innerHTML = "";

    // Download item
    const item = document.createElement("div");
    item.className = "sib-actions-item";
    item.setAttribute("role", "menuitem");
    item.dataset.action = "download";
    item.dataset.sessionId = sessionId;

    const icon = document.createElement("span");
    icon.className = "sib-actions-icon";
    icon.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>`;

    const label = document.createElement("span");
    label.className = "sib-actions-label";
    label.textContent = t("sessions.actions.download", "Download session files");

    const hint = document.createElement("span");
    hint.className = "sib-actions-hint";
    hint.textContent = t("sessions.actions.downloadHint", "for debugging");

    item.appendChild(icon);
    item.appendChild(label);
    item.appendChild(hint);
    dd.appendChild(item);
  }

  async function _downloadSessionBundle(sessionId, btnEl) {
    // btnEl may be a <button> (legacy) or a menu item <div> — guard accordingly.
    const wasDisabled = btnEl && btnEl.disabled;
    if (btnEl) {
      try { btnEl.disabled = true; } catch (_) {}
      btnEl.classList && btnEl.classList.add("is-loading");
    }
    try {
      const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/export`);
      if (!res.ok) {
        let msg = `HTTP ${res.status}`;
        try { const data = await res.json(); if (data.error) msg = data.error; } catch (_) {}
        alert((window.I18n && I18n.t("sessions.export.failed")) || "Failed to download session: " + msg);
        return;
      }
      const blob = await res.blob();

      // Derive filename from Content-Disposition header, fall back to short id.
      let filename = `clacky-session-${sessionId.slice(0, 8)}.zip`;
      const cd = res.headers.get("Content-Disposition") || "";
      const m = cd.match(/filename="?([^"]+)"?/i);
      if (m) filename = m[1];

      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      // Revoke on next tick so the browser has a chance to start the download.
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (err) {
      console.error("Session export failed:", err);
      alert(((window.I18n && I18n.t("sessions.export.failed")) || "Failed to download session") + ": " + err.message);
    } finally {
      if (btnEl) {
        try { btnEl.disabled = wasDisabled; } catch (_) {}
        btnEl.classList && btnEl.classList.remove("is-loading");
      }
    }
  }

  // Change working directory via backend API
  async function _changeWorkingDirectory(sessionId, newDir) {
    try {
      const res = await fetch(`/api/sessions/${sessionId}/working_dir`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ working_dir: newDir })
      });
      
      const data = await res.json();
      
      if (!res.ok) {
        throw new Error(data.error || "Unknown error");
      }
      
      // Update UI optimistically (will be confirmed by session_update broadcast)
      const sibDir = $("sib-dir");
      if (sibDir) {
        sibDir.textContent = newDir;
        sibDir.title = newDir + " (click to change)";
      }
      
      console.log(`Changed session ${sessionId} directory to ${newDir}`);
    } catch (e) {
      console.error("Failed to change directory:", e);
      alert("Failed to change directory: " + e.message);
    }
  }
})();
