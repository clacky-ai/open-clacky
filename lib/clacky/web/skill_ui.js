// ── skill_ui.js — Skill UI Extension loader ───────────────────────────────
//
// Fetches installed skill UI extensions from GET /api/ui-extensions on boot, then:
//   1. Dynamically injects sidebar entries into #ui-section
//   2. Dynamically injects panel containers into #main
//   3. Loads each extension's index.js via a <script> tag
//
// Panel IDs follow the convention: ui-panel-{id}
// Sidebar item IDs: ui-sidebar-{id}
//
// Skill UI extensions communicate with the host app via the SkillBridge API
// exposed on window.SkillBridge.
// ─────────────────────────────────────────────────────────────────────────

const SkillUI = (() => {
  // Installed skill UI extension descriptors returned by /api/ui-extensions
  let _extensions = [];

  // ── i18n helper ───────────────────────────────────────────────────────
  //
  // Resolve a field that may be either:
  //   - a plain string:  "Coding Agent"
  //   - an i18n object:  { en: "Coding Agent", zh: "编程助手" }
  //
  // Falls back to "en", then to the raw value, then to the fallback arg.
  //
  // Usage: _t(ext.name)  or  _t(ext.sidebar_divider, "")
  // ─────────────────────────────────────────────────────────────────────
  function _t(field, fallback = "") {
    if (!field) return fallback;
    if (typeof field === "string") return field;
    if (typeof field === "object") {
      const lang = (typeof I18n !== "undefined") ? I18n.lang() : "en";
      return field[lang] ?? field["en"] ?? fallback;
    }
    return fallback;
  }

  // ── SkillBridge ───────────────────────────────────────────────────────
  //
  // Public API exposed to skill UI scripts so they can interact with the host
  // app without touching internals directly.
  //
  // Available inside skill_ui.js as: SkillBridge.navigate(...)
  //                                  SkillBridge.onNavigate(...)
  //                                  SkillBridge.getActiveSession()
  // ─────────────────────────────────────────────────────────────────────
  const SkillBridge = {
    /**
     * Navigate to a skill UI panel.
     * @param {string} skillId - The skill id (e.g. "coding-agent")
     */
    navigate(skillId) {
      if (typeof Router !== "undefined") {
        Router.navigate("ui", { id: skillId });
      }
    },

    /**
     * Register a callback that fires whenever the active view changes.
     * @param {Function} fn - Called with (view, params)
     */
    onNavigate(fn) {
      _navListeners.push(fn);
    },

    /**
     * Returns the currently active session object, or null.
     */
    getActiveSession() {
      if (typeof Sessions !== "undefined") {
        return Sessions.find(Sessions.activeId) || null;
      }
      return null;
    },

    /**
     * Make an authenticated fetch to the local server API.
     * @param {string} path - e.g. "/api/sessions"
     * @param {object} opts - fetch options
     */
    async fetch(path, opts = {}) {
      const res = await fetch(path, {
        headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
        ...opts,
      });
      return res;
    },

    /**
     * Show a simple info message in the current panel (uses Sessions.appendInfo if available).
     * @param {string} message
     */
    info(message) {
      if (typeof Sessions !== "undefined") {
        Sessions.appendInfo(message);
      }
    },

    /**
     * Register a callback that fires once when the given skill UI's panel.html is fully
     * injected into the DOM. If the panel is already ready, the callback fires on the
     * next microtask.
     *
     * @param {string} skillId - e.g. "coding-agent"
     * @param {Function} fn - called with no arguments when panel DOM is ready
     */
    onPanelReady(skillId, fn) {
      const panelId = `ui-panel-${skillId}`;
      const panel = document.getElementById(panelId);
      // If panel element already has children, html has already been injected
      if (panel && panel.children.length > 0) {
        Promise.resolve().then(fn);
        return;
      }
      if (!_panelReadyListeners[skillId]) {
        _panelReadyListeners[skillId] = [];
      }
      _panelReadyListeners[skillId].push(fn);
    },
  };

  // Navigation change listeners registered by skill UI extensions
  const _navListeners = [];

  // Panel-ready listeners: called once when a skill UI's panel.html is fully injected into DOM.
  // Map of skillId → [callback, ...]
  const _panelReadyListeners = {};

  // Called by Router._apply() after each view change (wired up in app.js)
  function _notifyNavListeners(view, params) {
    _navListeners.forEach(fn => {
      try { fn(view, params); } catch (e) { console.error("[SkillUI] onNavigate error:", e); }
    });
  }

  // ── Sidebar injection ─────────────────────────────────────────────────

  // Ensure the #ui-section container exists in the sidebar.
  // It is created once and appended to #sidebar-list.
  function _ensureSkillUiSection() {
    if (document.getElementById("ui-section")) return;

    const section = document.createElement("div");
    section.id = "ui-section";

    const list = document.getElementById("sidebar-list");
    if (list) list.appendChild(section);
  }

  // Inject a sidebar entry for one skill UI extension.
  function _injectSidebarEntry(ext) {
    _ensureSkillUiSection();

    const section = document.getElementById("ui-section");
    if (!section) return;

    // Check if already injected (idempotent)
    if (document.getElementById(`ui-sidebar-${ext.id}`)) return;

    // If the extension declares a sidebar_divider, inject it before the entry.
    const dividerText = _t(ext.sidebar_divider);
    if (dividerText) {
      const divider = document.createElement("div");
      divider.className = "sidebar-divider";
      // Store skill id so we can re-translate on language change
      divider.dataset.uiDivider = ext.id;
      divider.innerHTML = `<span>${dividerText}</span>`;
      section.appendChild(divider);
    }

    // If the extension has a custom sidebar.html, fetch and inject it.
    // Otherwise render a default entry.
    if (ext.has_sidebar_html) {
      fetch(`/api/ui-extensions/${ext.id}/assets/sidebar.html`)
        .then(r => r.text())
        .then(html => {
          const wrapper = document.createElement("div");
          wrapper.id        = `ui-sidebar-${ext.id}`;
          wrapper.className = "ui-sidebar-entry";
          wrapper.innerHTML = html;

          // Wire up click → navigate to skill UI panel
          wrapper.addEventListener("click", () => {
            if (typeof Router !== "undefined") {
              Router.navigate("ui", { id: ext.id });
            }
          });

          section.appendChild(wrapper);
          // Notify skill UI scripts that sidebar is ready
          document.dispatchEvent(new CustomEvent(`ui:sidebar-ready:${ext.id}`));
        })
        .catch(e => console.error(`[SkillUI] Failed to load sidebar.html for ${ext.id}:`, e));
    } else {
      // Default sidebar entry — use _t() to resolve i18n name
      const wrapper = document.createElement("div");
      wrapper.id        = `ui-sidebar-${ext.id}`;
      wrapper.className = "task-item task-item-summary ui-sidebar-entry";
      wrapper.innerHTML = `
        <div class="task-row">
          <span class="task-icon">${ext.icon || "🧩"}</span>
          <div class="task-info">
            <span class="task-name">${_t(ext.name, ext.id)}</span>
          </div>
        </div>
      `;
      wrapper.addEventListener("click", () => {
        if (typeof Router !== "undefined") {
          Router.navigate("ui", { id: ext.id });
        }
      });
      section.appendChild(wrapper);
    }
  }

  // ── Panel injection ───────────────────────────────────────────────────

  // Inject a panel container for one skill UI extension into #main.
  // Returns a Promise that resolves once the panel HTML (if any) is injected.
  function _injectPanel(ext) {
    const panelId = `ui-panel-${ext.id}`;
    if (document.getElementById(panelId)) return Promise.resolve();

    const main = document.getElementById("main");
    if (!main) return Promise.resolve();

    const panel = document.createElement("div");
    panel.id            = panelId;
    panel.className     = "ui-panel";
    panel.style.display = "none";

    main.appendChild(panel);

    if (ext.has_panel_html) {
      return fetch(`/api/ui-extensions/${ext.id}/assets/panel.html`)
        .then(r => r.text())
        .then(html => {
          panel.innerHTML = html;
          // Notify any listeners waiting for this skill UI's panel to be ready
          const skillId = ext.id;
          if (_panelReadyListeners[skillId]) {
            _panelReadyListeners[skillId].forEach(fn => {
              try { fn(); } catch (e) { console.error(`[SkillUI] onPanelReady error for ${skillId}:`, e); }
            });
            delete _panelReadyListeners[skillId];
          }
        })
        .catch(e => console.error(`[SkillUI] Failed to load panel.html for ${ext.id}:`, e));
    } else {
      // Default empty panel placeholder — use _t() to resolve i18n fields
      panel.innerHTML = `
        <div class="ui-panel-placeholder">
          <span>${ext.icon || "🧩"}</span>
          <h2>${_t(ext.name, ext.id)}</h2>
          <p>${_t(ext.description)}</p>
        </div>
      `;
      return Promise.resolve();
    }
  }

  // ── Skill UI JS loader ────────────────────────────────────────────────

  // Dynamically load a skill UI extension's index.js.
  // The script runs in the page context and can access window.SkillBridge.
  function _loadSkillUiScript(ext) {
    if (!ext.has_index_js) return;

    const script = document.createElement("script");
    script.src   = `/api/ui-extensions/${ext.id}/assets/index.js`;
    script.async   = true;
    script.onerror = () => console.error(`[SkillUI] Failed to load ${filename} for ${ext.id}`);
    document.head.appendChild(script);
  }

  // ── Language change — re-translate sidebar dividers ───────────────────
  //
  // Sidebar divider text is rendered once on load. When the user switches
  // language in Settings, we re-translate all dividers via data-ui-divider.

  document.addEventListener("i18n:langchange", () => {
    document.querySelectorAll("[data-ui-divider]").forEach(divider => {
      const skillId = divider.dataset.uiDivider;
      const ext     = _extensions.find(e => e.id === skillId);
      if (!ext) return;
      const text = _t(ext.sidebar_divider);
      if (text) {
        const span = divider.querySelector("span");
        if (span) span.textContent = text;
      }
    });
  });

  // ── Boot ──────────────────────────────────────────────────────────────

  // Fetch skill UI extension list from server and bootstrap all extensions.
  // Returns a Promise that resolves once all panel HTML fetches are done,
  // so callers (app.js) can wait before running Router.restoreFromHash().
  async function init() {
    try {
      const res  = await fetch("/api/ui-extensions");
      const data = await res.json();
      _extensions = data.ui_extensions || [];

      if (_extensions.length === 0) return;  // No skill UI extensions installed

      // Expose SkillBridge globally so skill UI scripts can access it
      window.SkillBridge = SkillBridge;

      // Inject sidebars and panels; collect panel-html fetch promises so we
      // can await them before the router restores from hash.
      const panelFetches = [];
      _extensions.forEach(ext => {
        if (ext.sidebar !== false) {
          _injectSidebarEntry(ext);
        }
        panelFetches.push(_injectPanel(ext));
        _loadSkillUiScript(ext);
      });

      // Wait for all panel HTML to land in the DOM before resolving.
      await Promise.all(panelFetches);
    } catch (e) {
      console.error("[SkillUI] Failed to initialize skill UI extensions:", e);
    }
  }

  // ── Public API ────────────────────────────────────────────────────────

  return {
    init,

    /** All loaded skill UI extension descriptors. */
    get all() { return _extensions; },

    /** Find a skill UI extension by id. */
    find: id => _extensions.find(e => e.id === id) || null,

    /**
     * Get the panel DOM element for a skill UI extension.
     * @param {string} id - Skill id
     */
    getPanel: id => document.getElementById(`ui-panel-${id}`),

    /**
     * Get the sidebar DOM element for a skill UI extension.
     * @param {string} id - Skill id
     */
    getSidebarItem: id => document.getElementById(`ui-sidebar-${id}`),

    /**
     * Called by Router after each view change to notify skill UI extensions.
     * Wired up in app.js.
     */
    notifyNavListeners: _notifyNavListeners,

    /** Expose SkillBridge for external use */
    Bridge: SkillBridge,
  };
})();
