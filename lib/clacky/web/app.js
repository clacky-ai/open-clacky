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
// Moved to ws-dispatcher.js.

// ── Image & file attachments ──────────────────────────────────────────────
// Moved to sessions.js (Composer section — _initComposer() in Sessions.init()).
// All state (_pendingImages/_pendingFiles), helpers (_addAttachmentFile/etc.),
// preview rendering, and sendMessage() now live there as private members.

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

// ── New session controls ───────────────────────────────────────────────────
// Moved to sessions.js (_initNewSessionControls, called from Sessions.init()).

// ── Session search bar ─────────────────────────────────────────────────────
// Moved to sessions.js (_initSearch in Sessions.init()).

// ── Theme / session-scoped message panel bindings ──────────────────────────

// Theme toggle in header
if ($("theme-toggle-header")) {
  $("theme-toggle-header").addEventListener("click", () => Theme.toggle());
}
// btn-delete-session, #messages scroll-to-top (load history), and btn-interrupt
// moved to sessions.js (_initMessageHistory in Sessions.init()).

// btn-send, btn-attach, image-file-input change, input-area drag/drop, and
// user-input paste handlers moved to sessions.js (_initComposer).


// ── Skill autocomplete + composer bindings ───────────────────────────────
// Moved to skills.js (SkillAC IIFE, initialized from SkillAC.init()).


// ── Boot ──────────────────────────────────────────────────────────────────
Sidebar.init();
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

// Session Info Bar (model switcher + working-directory switcher) moved to sessions.js

