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
  "welcome",
  "chat-panel",
  "task-detail-panel",
  "skills-panel",
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
    if (h === "settings")             return { view: "settings", params: {} };
    const m = h.match(/^session\/(.+)$/);
    if (m)                            return { view: "session",  params: { id: m[1] } };
    return { view: "welcome", params: {} };
  }

  // Sidebar items managed by Router (keyed by view name → element id).
  // Router is the single authority for active highlight — modules must NOT
  // add/remove the "active" class on these elements themselves.
  const SIDEBAR_ITEMS = {
    tasks:  "tasks-sidebar-item",
    skills: "skills-sidebar-item",
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

    // ── Clean up previous state ──────────────────────────────────────────
    // Cache messages if leaving a session view
    if (Sessions.activeId) {
      Sessions._cacheActiveAndDeselect();
    }
    // Clear all sidebar highlights and settings button active state
    _clearSidebarActive();
    const btnSettings = $("btn-settings");
    if (btnSettings) btnSettings.classList.remove("active");

    _hideAll();

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
        Sessions._restoreMessagesPublic(id);
        Sessions._setActiveId(id);
        WS.setSubscribedSession(id);
        WS.send({ type: "subscribe", session_id: id });
        Sessions.renderList();
        $("user-input").focus();
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

      case "settings":
        _setHash("settings");
        $("settings-panel").style.display = "";
        if (btnSettings) btnSettings.classList.add("active");
        Settings.open();
        Sessions.renderList();
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
    case "_ws_connected":
      break;

    case "_ws_disconnected":
      break;

    // ── Session list ───────────────────────────────────────────────────
    case "session_list": {
      Sessions.setAll(ev.sessions || []);
      Sessions.renderList();

      // Restore URL hash once on initial connect; ignore subsequent session_list events
      if (!_initialRestoreDone) {
        _initialRestoreDone = true;
        Router.restoreFromHash();
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
      Sessions.appendInfo("Connected to session");
      // If this session was created by Tasks.run(), fire the agent now that
      // we're guaranteed to receive its broadcasts.
      const pendingId = Sessions.takePendingRunTask();
      if (pendingId && pendingId === ev.session_id) {
        WS.send({ type: "run_task", session_id: pendingId });
      }
      break;
    }

    case "session_update": {
      const updated = ev.session;
      if (!updated) break;
      Sessions.patch(updated.id, updated);
      Sessions.renderList();
      if (updated.id === Sessions.activeId) {
        Sessions.updateStatusBar(updated.status);
        // Update chat title in case session was renamed
        $("chat-title").textContent = Sessions.find(updated.id)?.name || "";
      }
      // When a session finishes, refresh tasks and skills
      if (updated.status === "idle") { Tasks.load(); Skills.load(); }
      break;
    }

    case "session_deleted":
      Sessions.remove(ev.session_id);
      if (ev.session_id === Sessions.activeId) Router.navigate("welcome");
      Sessions.renderList();
      break;

    // ── Chat messages ──────────────────────────────────────────────────
    case "assistant_message":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendMsg("assistant", escapeHtml(ev.content));
      break;

    case "tool_call":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      const argStr = typeof ev.args === "object"
        ? JSON.stringify(ev.args, null, 2)
        : String(ev.args || "");
      Sessions.appendMsg(
        "tool",
        `<span class="tool-name">⚙ ${escapeHtml(ev.name)}</span>\n${escapeHtml(argStr)}`
      );
      break;

    case "tool_result":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendMsg("tool", `↩ ${escapeHtml(String(ev.result || "").slice(0, 300))}`);
      break;

    case "tool_error":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendMsg("error", `Tool error: ${escapeHtml(ev.error)}`);
      break;

    case "progress":
      if (ev.session_id !== Sessions.activeId) break;
      if (ev.status === "start") Sessions.showProgress(ev.message || "Thinking…");
      else Sessions.clearProgress();
      break;

    case "complete":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendInfo(`✓ Done — ${ev.iterations} iteration(s), $${(ev.cost || 0).toFixed(4)}`);
      break;

    case "request_confirmation":
      if (ev.session_id !== Sessions.activeId) break;
      showConfirmModal(ev.id, ev.message);
      break;

    case "interrupted":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendInfo("Interrupted.");
      break;

    // ── Info / errors ──────────────────────────────────────────────────
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

// ── Image attachments ─────────────────────────────────────────────────────
const _pendingImages = [];
const MAX_IMAGE_SIZE = 5 * 1024 * 1024;
const ACCEPTED_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];

function _addImageFile(file) {
  if (!ACCEPTED_TYPES.includes(file.type)) {
    alert(`Unsupported image type: ${file.type}\nSupported: PNG, JPEG, GIF, WEBP`);
    return;
  }
  if (file.size > MAX_IMAGE_SIZE) {
    alert(`Image too large: ${file.name} (max 5 MB)`);
    return;
  }
  const reader = new FileReader();
  reader.onload = e => {
    _pendingImages.push({ dataUrl: e.target.result, name: file.name });
    _renderImagePreviews();
  };
  reader.readAsDataURL(file);
}

function _renderImagePreviews() {
  const strip = $("image-preview-strip");
  strip.innerHTML = "";
  if (_pendingImages.length === 0) {
    strip.style.display = "none";
    return;
  }
  strip.style.display = "flex";
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
      _renderImagePreviews();
    });
    item.appendChild(thumbnail);
    item.appendChild(removeBtn);
    strip.appendChild(item);
  });
}

// ── Send message ──────────────────────────────────────────────────────────
let _sending = false;

function sendMessage() {
  if (_sending) return;
  const input   = $("user-input");
  const content = input.value.trim();
  if (!content && _pendingImages.length === 0) return;
  if (!Sessions.activeId) return;

  _sending = true;

  let bubbleHtml = content ? escapeHtml(content) : "";
  if (_pendingImages.length > 0) {
    const thumbs = _pendingImages
      .map(img => `<img src="${img.dataUrl}" alt="${escapeHtml(img.name)}" class="msg-image-thumb">`)
      .join("");
    bubbleHtml = thumbs + (bubbleHtml ? "<br>" + bubbleHtml : "");
  }
  Sessions.appendMsg("user", bubbleHtml);

  const images = _pendingImages.map(img => img.dataUrl);
  _pendingImages.length = 0;
  _renderImagePreviews();

  WS.send({ type: "message", session_id: Sessions.activeId, content, images });
  input.value        = "";
  input.style.height = "auto";
  setTimeout(() => { _sending = false; }, 300);
}

// ── DOM event listeners ───────────────────────────────────────────────────
$("btn-new-session").addEventListener("click", () => Sessions.create());
$("btn-welcome-new").addEventListener("click", () => Sessions.create());
$("btn-send").addEventListener("click", sendMessage);
$("btn-interrupt").addEventListener("click", () =>
  WS.send({ type: "interrupt", session_id: Sessions.activeId })
);

$("btn-attach").addEventListener("click", () => $("image-file-input").click());
$("image-file-input").addEventListener("change", e => {
  Array.from(e.target.files).forEach(_addImageFile);
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
  const files = Array.from(e.dataTransfer.files).filter(f => ACCEPTED_TYPES.includes(f.type));
  if (files.length === 0) return;
  files.forEach(_addImageFile);
});

$("user-input").addEventListener("paste", e => {
  const items = Array.from(e.clipboardData?.items || []);
  const imageItems = items.filter(it => it.kind === "file" && ACCEPTED_TYPES.includes(it.type));
  if (imageItems.length === 0) return;
  e.preventDefault();
  imageItems.forEach(it => _addImageFile(it.getAsFile()));
});

let _composing = false;
$("user-input").addEventListener("compositionstart", () => { _composing = true; });
$("user-input").addEventListener("compositionend",   () => { _composing = false; });

$("user-input").addEventListener("keydown", e => {
  if (e.key === "Enter" && !e.shiftKey && !_composing) {
    e.preventDefault();
    sendMessage();
  }
});

$("user-input").addEventListener("input", () => {
  const el = $("user-input");
  el.style.height = "auto";
  el.style.height = Math.min(el.scrollHeight, 200) + "px";
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

$("btn-create-skill").addEventListener("click", () => Skills.createInSession());

// ── Boot ──────────────────────────────────────────────────────────────────
Settings.init();
WS.connect();   // triggers session_list → Router.restoreFromHash()
Tasks.load();
Skills.load();
