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
  "onboard-panel",
  "brand-panel",
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

    // ── Clean up previous state ──────────────────────────────────────────
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

      case "onboard":
        // No hash — keep URL clean during onboarding
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
        Sessions.appendMsg("user", escapeHtml(pendingMsg.content));
        WS.send({ type: "message", session_id: pendingMsg.session_id, content: pendingMsg.content });
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
    case "history_user_message":
      // Emitted only during history replay — never from live WS.
      // Rendered by Sessions._fetchHistory; nothing to do here.
      break;

    case "assistant_message":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendMsg("assistant", escapeHtml(ev.content));
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
      Sessions.collapseToolGroup();
      Sessions.appendInfo(`✓ Done — ${ev.iterations} iteration(s), $${(ev.cost || 0).toFixed(4)}`);
      break;

    case "request_confirmation":
      if (ev.session_id !== Sessions.activeId) break;
      showConfirmModal(ev.id, ev.message);
      break;

    case "interrupted":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.collapseToolGroup();
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
// Sidebar toggle
if ($("btn-toggle-sidebar")) {
  $("btn-toggle-sidebar").addEventListener("click", () => {
    const sidebar = $("sidebar");
    sidebar.classList.toggle("hidden");
  });
}

// New session buttons (both old and new inline button)
if ($("btn-new-session")) {
  $("btn-new-session").addEventListener("click", () => Sessions.create());
}
if ($("btn-new-session-inline")) {
  $("btn-new-session-inline").addEventListener("click", () => Sessions.create());
}
$("btn-welcome-new").addEventListener("click", () => Sessions.create());

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

// Note: do NOT use a manual _composing flag + compositionstart/compositionend.
// IMEs like Sogou fire keydown(Enter) in the same tick as compositionend, so
// the flag would already be false when the Enter keydown arrives — causing an
// accidental send. e.isComposing is set by the browser on the event object
// itself and remains true for the keydown that terminates a composition,
// which is exactly what we need.

// Hide skill autocomplete when input loses focus (unless clicking a dropdown item)
$("user-input").addEventListener("blur", () => {
  // Small delay so mousedown on item fires first
  setTimeout(() => SkillAC.hide(), 150);
});

// ── Skill autocomplete ────────────────────────────────────────────────────
const SkillAC = (() => {
  let _visible        = false;
  let _activeIndex    = -1;
  let _items          = [];  // filtered [{ name, description }]
  let _sessionSkills  = [];  // skills allowed for the active session's profile

  /** Fetch session-specific skill list from the server and cache it.
   *  Called whenever the active session changes. */
  async function _loadForSession(sessionId) {
    if (!sessionId) { _sessionSkills = []; return; }
    try {
      const res  = await fetch(`/api/sessions/${sessionId}/skills`);
      const data = await res.json();
      _sessionSkills = data.skills || [];
    } catch (e) {
      console.error("[SkillAC] loadForSession failed", e);
      _sessionSkills = [];
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

  function _render(query) {
    // Use session-scoped skill list when available; fall back to global Skills list
    const all = _sessionSkills.length > 0 ? _sessionSkills : Skills.all;
    _items = all.filter(s => s.name.toLowerCase().startsWith(query));

    if (_items.length === 0) { _hide(); return; }

    const list = $("skill-autocomplete-list");
    list.innerHTML = "";

    // Header label
    const header = document.createElement("div");
    header.className = "skill-ac-header";
    header.textContent = "Skills";
    list.appendChild(header);

    _items.forEach((skill, idx) => {
      const item = document.createElement("div");
      item.className = "skill-ac-item" + (idx === _activeIndex ? " active" : "");
      item.setAttribute("role", "option");
      item.setAttribute("data-idx", idx);

      const nameEl = document.createElement("span");
      nameEl.className = "skill-ac-name";
      nameEl.textContent = "/" + skill.name;

      const descEl = document.createElement("span");
      descEl.className = "skill-ac-desc";
      descEl.textContent = skill.description || "";

      item.appendChild(nameEl);
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
  function _openAll() {
    _activeIndex = -1;  // No default selection, only highlight on hover
    _render("");
    $("user-input").focus();
  }

  /** Toggle the dropdown (open if hidden, close if visible). */
  function _toggle() {
    if (_visible) {
      _hide();
    } else {
      _openAll();
    }
  }

  return {
    get visible()      { return _visible; },
    get activeIndex()  { return _activeIndex; },

    /** Called on every `input` event — decide whether to show/hide/update. */
    update(value) {
      const query = _getSlashQuery(value);
      if (query === null) { _hide(); return; }
      // No default selection when typing, only highlight on hover/arrow keys
      _activeIndex = -1;
      _render(query);
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
      if (e.key === "Enter" && !e.isComposing) {
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

  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
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

// ── Boot ──────────────────────────────────────────────────────────────────
Settings.init();
Channels.init();

// Boot sequence:
//   1. Onboard check  — first-run key setup / soul setup
//   2. Brand check    — license activation for white-label installs
//   3. Normal UI boot — WS + sessions + tasks + skills
//
// Each step defers normal boot until it completes or is skipped.
(async () => {
  const needsOnboard = await Onboard.check();
  if (needsOnboard) return;

  const needsBrandActivation = await Brand.check();
  if (needsBrandActivation) return;

  WS.connect();   // triggers session_list → Router.restoreFromHash()
  Tasks.load();
  Skills.load();
})();
