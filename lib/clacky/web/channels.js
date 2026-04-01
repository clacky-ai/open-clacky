// channels.js — Channels panel (Agent-First design)
//
// Design principle: no configuration forms here.
// This page shows platform status only. All setup is done via Agent with browser automation.
// "Auto Setup" opens a chat session with /channel-setup pre-filled — the Agent will use
// browser automation to complete the entire setup on the platform's web console.
// "Test" runs /channel-setup doctor via the Agent and streams results.

const Channels = (() => {

  // Platform display metadata (use accessor to pick up runtime language)
  function PLATFORM_META() {
    return {
      feishu: {
        logo:      "飞",
        logoClass: "channel-logo-feishu",
        name:      "Feishu / Lark",
        desc:      I18n.t("channels.feishu.desc"),
        setupCmd:  "/channel-setup setup feishu",
        testCmd:   "/channel-setup doctor",
      },
      wecom: {
        logo:      "微",
        logoClass: "channel-logo-wecom",
        name:      "WeCom (企业微信)",
        desc:      I18n.t("channels.wecom.desc"),
        setupCmd:  "/channel-setup setup wecom",
        testCmd:   "/channel-setup doctor",
      },
      weixin: {
        logo:      "信",
        logoClass: "channel-logo-weixin",
        name:      "Weixin (微信)",
        desc:      I18n.t("channels.weixin.desc"),
        setupCmd:  "/channel-setup setup weixin",
        testCmd:   "/channel-setup doctor",
      },
    };
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  async function onPanelShow() {
    await _load();
  }

  // ── Data Loading ─────────────────────────────────────────────────────────────

  async function _load() {
    const container = $("channels-list");
    if (!container) return;
    container.innerHTML = `<div class="channel-loading">${I18n.t("channels.loading")}</div>`;

    try {
      const res  = await fetch("/api/channels");
      const data = await res.json();
      _render(data.channels || []);
    } catch (e) {
      container.innerHTML = `<div class="channel-error">${I18n.t("channels.loadError", { msg: _esc(e.message) })}</div>`;
    }
  }

  // ── Rendering ─────────────────────────────────────────────────────────────────

  function _render(channels) {
    const container = $("channels-list");
    if (!container) return;
    container.innerHTML = "";

    // Merge server data with display metadata, show all known platforms
    const meta = PLATFORM_META();
    const platformIds = Object.keys(meta);
    platformIds.forEach(pid => {
      const serverData = channels.find(c => c.platform == pid) || {};
      container.appendChild(_renderCard(pid, serverData, meta[pid]));
    });
  }

  function _renderCard(platform, data, meta) {
    const enabled = !!data.enabled;
    const running = !!data.running;

    const card = document.createElement("div");
    card.className = "channel-card";
    card.id = `channel-card-${platform}`;

    card.innerHTML = `
      <div class="channel-card-header">
        <div class="channel-card-identity">
          <span class="channel-logo ${_esc(meta.logoClass)}">${_esc(meta.logo)}</span>
          <div>
            <div class="channel-card-name">${_esc(meta.name)}</div>
            <div class="channel-card-desc">${_esc(meta.desc)}</div>
          </div>
        </div>
        <span class="channel-status-badge" id="channel-badge-${_esc(platform)}">${_badgeHtml(enabled, running)}</span>
      </div>

      <div class="channel-card-body">
        ${_statusHint(enabled, running)}
      </div>

      <div class="channel-card-footer">
        <div class="channel-card-actions">
          <button class="btn-channel-test btn-secondary" id="btn-test-${_esc(platform)}">
            <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
              <polyline points="22 4 12 14.01 9 11.01"/>
            </svg>
            ${I18n.t("channels.btn.test")}
          </button>
          <button class="btn-channel-configure btn-primary" id="btn-configure-${_esc(platform)}">
            <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>
            </svg>
            ${enabled ? I18n.t("channels.btn.reconfigure") : I18n.t("channels.btn.setup")}
          </button>
        </div>
      </div>
    `;

    // Bind events
    card.querySelector(`#btn-test-${platform}`)?.addEventListener("click", () => _runTest(platform));
    card.querySelector(`#btn-configure-${platform}`)?.addEventListener("click", () => _openSetup(platform));

    return card;
  }

  // ── Badge & status hint helpers ───────────────────────────────────────────────

  function _badgeHtml(enabled, running) {
    if (running)       return `<span class="badge-running">● ${I18n.t("channels.badge.running")}</span>`;
    if (enabled)       return `<span class="badge-enabled">● ${I18n.t("channels.badge.enabled")}</span>`;
    return             `<span class="badge-disabled">○ ${I18n.t("channels.badge.notConfigured")}</span>`;
  }

  function _statusHint(enabled, running) {
    if (running) {
      return `<p class="channel-status-hint hint-ok">✓ ${I18n.t("channels.hint.running")}</p>`;
    }
    if (enabled) {
      return `<p class="channel-status-hint hint-warn">⚠ ${I18n.t("channels.hint.enabledNotRunning")}</p>`;
    }
    return `<p class="channel-status-hint hint-idle">${I18n.t("channels.hint.notConfigured")}</p>`;
  }

  // ── Actions ───────────────────────────────────────────────────────────────────

  // Run E2E test: open a session and send /channel-setup doctor
  async function _runTest(platform) {
    const meta = PLATFORM_META()[platform];
    await _sendToAgent(meta.testCmd, `Channel E2E Test — ${meta.name}`);
  }

  // Open setup: open a session and send /channel-setup setup <platform>
  async function _openSetup(platform) {
    const meta = PLATFORM_META()[platform];
    await _sendToAgent(meta.setupCmd, `Channel Setup — ${meta.name}`);
  }

  // Create a session, add it to the list, navigate to it, and send the given command.
  // Follows the same pattern as Skills.createInSession().
  async function _sendToAgent(command, sessionName) {
    try {
      // Pick a session name in "Session N" style, consistent with other modules
      const maxN = Sessions.all.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const name = sessionName || ("Session " + (maxN + 1));

      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name, source: "setup" }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || I18n.t("channels.sessionError"));
      const session = data.session;
      if (!session) throw new Error(I18n.t("channels.noSession"));

      // Register in Sessions, refresh sidebar, queue command, then navigate
      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, command);
      Sessions.select(session.id);
    } catch (e) {
      alert("Error: " + e.message);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  function _esc(str) {
    return String(str || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  return {
    onPanelShow,
    init() {}, // no static DOM to bind; events bound per-render
  };
})();
