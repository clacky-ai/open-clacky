// ── Version — version check and upgrade flow ───────────────────────────────
//
// Badge states:
//   (none)        → up-to-date, muted version text
//   has-update    → amber pulsing dot: new version available
//   is-upgrading  → spinning ring: gem install in progress
//   needs-restart → orange bouncing dot: upgrade done, waiting for restart
//   upgrade-done  → green check: restarted & reconnected successfully
//
// Flow:
//   1. Page load → checkVersion() → badge shows version number
//   2. needs_update: badge shows amber pulsing dot
//   3. Click badge → fixed popover (confirm state)
//   4. Click "Upgrade" → popover → progress state (live log)
//   5. upgrade_complete (success) → badge: needs-restart; popover: restart button
//   6. Click "Restart" → /api/restart → popover: reconnecting spinner
//      → poll /api/version until server back → badge: upgrade-done (green ✓) → reload
// ─────────────────────────────────────────────────────────────────────────

const Version = (() => {
  // ── State ──────────────────────────────────────────────────────────────
  let _current        = null;
  let _latest         = null;
  let _needsUpdate    = false;
  let _upgrading      = false;
  let _needsRestart   = false;   // upgrade done, waiting for restart
  let _reconnecting   = false;   // restart sent, polling for server to come back
  let _upgradeDone    = false;   // restarted and reconnected successfully
  let _popoverOpen    = false;
  let _reconnectTimer = null;
  let _logLines       = [];

  // ── DOM helpers ────────────────────────────────────────────────────────
  const $  = id => document.getElementById(id);
  const el = (tag, attrs = {}, ...children) => {
    const e = document.createElement(tag);
    Object.entries(attrs).forEach(([k, v]) => {
      if (k === "className") e.className = v;
      else if (k === "innerHTML") e.innerHTML = v;
      else e.setAttribute(k, v);
    });
    children.forEach(c => c && e.appendChild(typeof c === "string" ? document.createTextNode(c) : c));
    return e;
  };

  // ── Version check ──────────────────────────────────────────────────────
  async function checkVersion() {
    try {
      const res  = await fetch("/api/version");
      if (!res.ok) return;
      const data = await res.json();
      _current     = data.current;
      _latest      = data.latest;
      _needsUpdate = !!data.needs_update;
      _renderBadge();
    } catch (e) {
      console.warn("[Version] check failed:", e);
    }
  }

  // ── Badge render ───────────────────────────────────────────────────────
  function _renderBadge() {
    const badge         = $("version-badge");
    const text          = $("version-text");
    const dot           = $("version-update-dot");
    const restartDot    = $("version-restart-dot");
    const check         = $("version-done-check");
    const spinner       = $("version-spinner");
    if (!badge || !text) return;

    text.textContent = _current ? `v${_current}` : "";

    // Reset all indicators
    if (dot)        dot.style.display        = "none";
    if (restartDot) restartDot.style.display = "none";
    if (check)      check.style.display      = "none";
    if (spinner)    spinner.style.display    = "none";
    badge.className = "version-badge";

    if (_upgrading) {
      // Spinning ring: gem install running
      badge.classList.add("is-upgrading");
      badge.title = I18n.t("upgrade.tooltip.upgrading");
      if (spinner) spinner.style.display = "inline-block";
    } else if (_needsRestart) {
      // Orange bouncing dot: upgrade done, please restart
      badge.classList.add("needs-restart");
      badge.title = I18n.t("upgrade.tooltip.needs_restart");
      if (restartDot) restartDot.style.display = "inline-block";
    } else if (_upgradeDone) {
      // Green check: restarted successfully
      badge.classList.add("upgrade-done");
      badge.title = I18n.t("upgrade.tooltip.done");
      if (check) check.style.display = "inline-block";
    } else if (_needsUpdate) {
      // Amber pulsing dot: new version available
      badge.classList.add("has-update");
      badge.title = I18n.t("upgrade.tooltip.new", { latest: _latest });
      if (dot) dot.style.display = "inline-block";
    } else {
      badge.title = I18n.t("upgrade.tooltip.ok", { current: _current });
    }

    badge.style.display = "flex";
  }

  // ── Popover (fixed, positioned above badge) ────────────────────────────
  function _getOrCreatePopover() {
    let pop = $("version-upgrade-popover");
    if (pop) return pop;

    pop = el("div", { id: "version-upgrade-popover", className: "vup" });
    document.body.appendChild(pop);
    return pop;
  }

  function _positionPopover() {
    const badge = $("version-badge");
    const pop   = $("version-upgrade-popover");
    if (!badge || !pop) return;

    const rect = badge.getBoundingClientRect();
    // Appear above the badge, right-aligned to sidebar edge
    pop.style.left   = rect.left + "px";
    pop.style.bottom = (window.innerHeight - rect.top + 8) + "px";
    pop.style.top    = "auto";
  }

  function _openPopover() {
    if (_popoverOpen) { _positionPopover(); return; }
    _popoverOpen = true;

    const pop = _getOrCreatePopover();
    pop.innerHTML = "";

    if (_reconnecting) {
      _renderReconnectState(pop);
    } else if (_upgrading) {
      _renderProgressState(pop);
    } else if (_needsRestart) {
      _renderDoneState(pop);
    } else if (_upgradeDone) {
      _renderDoneState(pop);
    } else {
      _renderConfirmState(pop);
    }

    pop.style.display = "block";
    _positionPopover();

    // Animate in
    requestAnimationFrame(() => pop.classList.add("vup--visible"));
  }

  function _closePopover() {
    // Don't allow closing while upgrading or waiting for server to come back
    if (_upgrading || _reconnecting) return;
    const pop = $("version-upgrade-popover");
    if (!pop) return;
    pop.classList.remove("vup--visible");
    setTimeout(() => {
      pop.style.display = "none";
      _popoverOpen = false;
    }, 180);
  }

  // ── Popover states ─────────────────────────────────────────────────────

  /** State 1: confirm upgrade */
  function _renderConfirmState(pop) {
    pop.innerHTML = `
      <p class="vup-desc">${I18n.t("upgrade.desc")}</p>
      <p class="vup-versions">v${_current} <span class="vup-arrow">→</span> v${_latest}</p>
      <div class="vup-actions">
        <button id="vup-btn-upgrade" class="vup-btn-primary">${I18n.t("upgrade.btn.upgrade")}</button>
        <button id="vup-btn-cancel"  class="vup-btn-cancel">${I18n.t("upgrade.btn.cancel")}</button>
      </div>
    `;
    $("vup-btn-upgrade").addEventListener("click", () => _startUpgrade(pop));
    $("vup-btn-cancel").addEventListener("click", _closePopover);
  }

  /** State 2: upgrading — show live log */
  function _renderProgressState(pop) {
    pop.innerHTML = `
      <div class="vup-progress-header">
        <span class="vup-installing-dot"></span>
        <span class="vup-installing-label">${I18n.t("upgrade.installing")}</span>
      </div>
      <pre id="vup-log" class="vup-log"></pre>
    `;
    // Replay any logs already received
    const logEl = $("vup-log");
    if (logEl && _logLines.length) {
      logEl.textContent = _logLines.join("\n");
      logEl.scrollTop = logEl.scrollHeight;
    }
  }

  /** State 3: done — show restart button */
  function _renderDoneState(pop) {
    pop.innerHTML = `
      <div class="vup-done-header">
        <span class="vup-done-icon">✓</span>
        <span>${I18n.t("upgrade.done")}</span>
      </div>
      <button id="vup-btn-restart" class="vup-btn-restart">${I18n.t("upgrade.btn.restart")}</button>
    `;
    $("vup-btn-restart").addEventListener("click", _startRestart);
  }

  /** State 4: reconnecting after restart */
  function _renderReconnectState(pop) {
    pop.innerHTML = `
      <div class="vup-reconnect">
        <div class="vup-reconnect-spinner"></div>
        <p class="vup-reconnect-msg">${I18n.t("upgrade.reconnecting")}</p>
      </div>
    `;
  }

  // ── Upgrade ────────────────────────────────────────────────────────────
  async function _startUpgrade(pop) {
    if (_upgrading || _upgradeDone) return;
    _upgrading  = true;
    _logLines   = [];
    _renderBadge();
    _renderProgressState(pop);

    try {
      await fetch("/api/version/upgrade", { method: "POST" });
    } catch (e) {
      console.warn("[Version] upgrade request failed:", e);
      _upgrading = false;
      _renderBadge();
    }
  }

  // ── Restart ────────────────────────────────────────────────────────────
  async function _startRestart() {
    _reconnecting = true;

    // Ensure popover is open and showing the reconnect spinner
    const pop = _getOrCreatePopover();
    _renderReconnectState(pop);
    if (!_popoverOpen) {
      _popoverOpen = true;
      pop.style.display = "block";
      _positionPopover();
      requestAnimationFrame(() => pop.classList.add("vup--visible"));
    }

    try {
      fetch("/api/restart", { method: "POST" }).catch(() => {});
    } catch (_) {}

    _waitForReconnect();
  }

  function _waitForReconnect() {
    if (_reconnectTimer) clearInterval(_reconnectTimer);
    setTimeout(() => {
      _reconnectTimer = setInterval(async () => {
        try {
          const res = await fetch("/api/version", { cache: "no-store" });
          if (res.ok) {
            clearInterval(_reconnectTimer);
            _reconnectTimer = null;
            // Server is back — close popover, badge → green check, then reload
            _reconnecting = false;
            _needsRestart = false;
            _upgradeDone  = true;
            _renderBadge();
            _closePopover();
            setTimeout(() => window.location.reload(), 800);
          }
        } catch (_) { /* server not yet up */ }
      }, 2000);
    }, 2500);
  }

  // ── WebSocket events ───────────────────────────────────────────────────
  function _handleWsEvent(event) {
    if (event.type === "upgrade_log") {
      const line = event.line || "";
      _logLines.push(line);
      // Append to live log if popover is open
      const logEl = $("vup-log");
      if (logEl) {
        logEl.textContent += (logEl.textContent ? "\n" : "") + line;
        logEl.scrollTop = logEl.scrollHeight;
      }
    } else if (event.type === "upgrade_complete") {
      _upgrading    = false;
      _needsUpdate  = false;
      if (event.success) {
        _needsRestart = true;   // badge: orange bouncing dot
        _upgradeDone  = false;
      }
      _renderBadge();
      // Morph popover to done/error state
      const pop = $("version-upgrade-popover");
      if (pop && _popoverOpen) {
        if (event.success) {
          _renderDoneState(pop);
        } else {
          pop.innerHTML = `<p class="vup-error">${I18n.t("upgrade.failed")}</p>`;
        }
      }
    }
  }

  // ── Init ───────────────────────────────────────────────────────────────
  function init() {
    const badge = $("version-badge");
    if (badge) {
      badge.addEventListener("click", e => {
        if (!_current) return;
        // Up-to-date: no action, let the click fall through to settings btn
        if (!_needsUpdate && !_upgrading && !_needsRestart && !_reconnecting && !_upgradeDone) return;

        // Actionable: stop propagation so settings panel doesn't open
        e.stopPropagation();

        // During reconnect, badge click just keeps popover visible (no toggle)
        if (_reconnecting) { if (!_popoverOpen) _openPopover(); return; }

        if (_popoverOpen) {
          _closePopover();
        } else {
          _openPopover();
        }
      });
    }

    // Close on outside click — but not while upgrading or reconnecting
    document.addEventListener("click", e => {
      if (!e.target.closest("#version-badge") && !e.target.closest("#version-upgrade-popover")) {
        if (_popoverOpen && !_upgrading && !_reconnecting) _closePopover();
      }
    });

    // Reposition on window resize
    window.addEventListener("resize", () => {
      if (_popoverOpen) _positionPopover();
    });

    if (typeof WS !== "undefined") {
      WS.onEvent(_handleWsEvent);
    }

    checkVersion();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  return { checkVersion };
})();
