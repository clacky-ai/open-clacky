// channels.js — Channels panel (Agent-First design)
//
// Design principle: no configuration forms here.
// This page shows platform status only. All setup is done via Agent with browser automation.
// "Auto Setup" opens a chat session with /channel-manager pre-filled — the Agent will use
// browser automation to complete the entire setup on the platform's web console.
// "Test" runs /channel-manager doctor via the Agent and streams results.

const Channels = (() => {

  // Platform display metadata (use accessor to pick up runtime language)
  // SVG sources: dashboard-icons (Lark, multi-color brand mark),
  // TDesign icons (WeCom/WeChat, single-color), simpleicons (Discord/Telegram),
  // ant-design/ant-design-icons outlined (DingTalk).
  function PLATFORM_META() {
    return {
      feishu: {
        logo:      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="62.16 94.5 407.87 324.19" aria-hidden="true"><path d="M274.18 264.785q.515-.517 1.03-1.027c.685-.688 1.372-1.258 2.056-1.945l1.37-1.372 4.118-4.113 5.598-5.601 4.8-4.797 4.575-4.457 4.796-4.688 4.344-4.344 6.059-6.054c1.14-1.145 2.285-2.29 3.543-3.317 2.168-2.054 4.457-4 6.855-5.828 2.172-1.715 4.344-3.312 6.516-4.914 3.082-2.172 6.398-4.344 9.71-6.285 3.204-1.941 6.63-3.656 10.06-5.371 3.199-1.602 6.515-2.973 9.827-4.23 1.829-.684 3.774-1.372 5.602-2.055.914-.344 1.941-.688 2.856-.914-8.57-33.715-24.227-64.575-45.258-90.86-4.114-5.14-10.399-8.113-17.028-8.113H130.754c-3.203 0-4.457 4-1.945 5.941 59.543 43.66 109.144 99.887 145.03 164.801 0-.226.227-.34.34-.457m0 0" fill="#00d6b9"/><path d="M204.79 418.691c90.288 0 169.03-49.828 210.058-123.543 1.488-2.628 2.859-5.257 4.23-7.882q-3.087 6-6.86 11.312l-2.741 3.77c-1.141 1.488-2.399 2.972-3.657 4.457-1.03 1.144-2.058 2.285-3.086 3.316-2.058 2.172-4.343 4.227-6.629 6.172a53 53 0 0 1-3.886 3.2c-1.598 1.144-3.086 2.284-4.684 3.429-1.031.683-2.058 1.371-3.086 1.941-1.144.684-2.172 1.258-3.316 1.942a131 131 0 0 1-6.969 3.543c-2.059.918-4.117 1.828-6.289 2.515-2.285.801-4.57 1.602-6.969 2.285-3.543.914-7.086 1.715-10.742 2.286-2.629.457-5.258.687-8 .914-2.86.23-5.601.23-8.457.23-3.086 0-6.289-.23-9.488-.57a83 83 0 0 1-7.086-1.031c-2.055-.34-4.113-.801-6.168-1.258-1.031-.227-2.176-.57-3.203-.797-2.973-.8-6.055-1.602-9.028-2.516-1.488-.457-2.972-.914-4.457-1.258-2.172-.683-4.457-1.37-6.629-2.058-1.828-.57-3.656-1.14-5.37-1.711q-2.573-.86-5.145-1.715c-1.14-.344-2.285-.8-3.543-1.144-1.371-.457-2.856-1.028-4.227-1.485-1.027-.344-2.058-.687-2.972-1.027-1.942-.688-4-1.488-5.942-2.172-1.144-.457-2.285-.914-3.43-1.258-1.484-.57-3.085-1.144-4.57-1.828-1.601-.687-3.203-1.258-4.8-1.945-1.028-.457-2.06-.797-3.087-1.258-1.257-.57-2.628-1.027-3.886-1.598-1.028-.457-1.942-.8-2.969-1.258l-3.086-1.37c-.914-.344-1.832-.801-2.746-1.145a44 44 0 0 1-2.512-1.14c-.8-.345-1.715-.802-2.515-1.145-.914-.344-1.715-.801-2.512-1.141-1.031-.457-2.172-1.031-3.203-1.484-1.14-.575-2.285-1.032-3.426-1.602-1.258-.574-2.402-1.144-3.66-1.715-1.027-.457-2.055-1.027-3.082-1.484-54.172-26.973-102.172-63.086-143.09-106.746-2.055-2.172-5.71-.684-5.71 2.289l.112 154.398v12.57c0 7.317 3.543 14.06 9.598 18.172 38.172 24.801 83.773 39.543 132.914 39.543m0 0" fill="#3370ff"/><path d="M414.84 295.188c0 .113-.113.113-.113.226zl.8-1.489c-.343.457-.574 1.028-.8 1.488m3.793-7.05.226-.457.114-.23q-.17.513-.34.687m0 0" fill="#133c9a"/><path d="M470.035 201.121c-18.285-9.031-38.86-14.059-60.687-14.059-12.914 0-25.485 1.829-37.371 5.141-1.372.344-2.743.8-4.114 1.258-.914.344-1.941.574-2.855.914-1.945.688-3.774 1.375-5.602 2.059-3.316 1.257-6.629 2.742-9.828 4.23-3.43 1.598-6.742 3.426-10.058 5.371a128 128 0 0 0-9.715 6.285c-2.285 1.602-4.457 3.2-6.512 4.914a154 154 0 0 0-6.86 5.828c-1.14 1.141-2.398 2.172-3.542 3.313l-6.055 6.059-4.344 4.343-4.8 4.684-4.57 4.46-4.802 4.798-11.086 11.086c-.687.687-1.37 1.37-2.058 1.945l-1.028 1.027c-.457.457-1.027 1.028-1.601 1.485-.57.57-1.14 1.031-1.711 1.601a244.4 244.4 0 0 1-49.828 35.313c1.027.457 2.168 1.027 3.199 1.488.8.34 1.715.797 2.512 1.14.8.344 1.715.801 2.515 1.145.801.344 1.602.684 2.516 1.14.914.345 1.828.802 2.742 1.145l3.086 1.371c1.027.457 1.942.801 2.969 1.258 1.258.57 2.629 1.028 3.887 1.598 1.03.46 2.058.8 3.086 1.258 1.601.687 3.199 1.258 4.8 1.945 1.485.57 3.086 1.14 4.57 1.828 1.145.457 2.286.914 3.43 1.258 1.946.684 4 1.484 5.946 2.172a81 81 0 0 1 2.968 1.027c1.371.457 2.856 1.028 4.23 1.485 1.141.343 2.286.8 3.544 1.14q2.567.86 5.14 1.719c1.829.57 3.657 1.14 5.372 1.71 2.171.688 4.457 1.376 6.628 2.06 1.489.457 2.973.914 4.457 1.257 2.973.914 5.942 1.715 9.032 2.512 1.027.344 2.168.574 3.199.8 2.055.458 4.113.915 6.172 1.259 2.398.457 4.683.8 7.082 1.03 3.203.34 6.402.571 9.488.571 2.856 0 5.715 0 8.457-.23 2.63-.227 5.371-.457 8-.914 3.656-.57 7.2-1.371 10.742-2.286 2.399-.683 4.688-1.37 6.973-2.285 2.172-.8 4.227-1.601 6.285-2.515 2.399-1.028 4.684-2.285 6.973-3.543 1.14-.57 2.168-1.258 3.312-1.942 1.028-.687 2.059-1.257 3.086-1.945 1.602-1.027 3.2-2.168 4.684-3.426a52 52 0 0 0 3.887-3.203c2.289-1.941 4.457-4 6.628-6.168 1.032-1.031 2.06-2.172 3.086-3.316 1.258-1.485 2.516-2.969 3.657-4.457.918-1.258 1.828-2.512 2.742-3.77 2.515-3.543 4.8-7.316 6.86-11.199l2.284-4.688 21.145-42.171v.113c6.742-14.742 16.226-28.113 27.656-39.426m0 0" fill="#133c9a"/></svg>`,
        logoClass: "channel-logo-feishu",
        name:      "Feishu / Lark",
        desc:      I18n.t("channels.feishu.desc"),
        setupCmd:  "/channel-manager setup feishu",
        testCmd:   "/channel-manager doctor",
      },
      wecom: {
        logo:      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true"><path fill="#fff" d="m17.326 8.158l-.003-.007a6.6 6.6 0 0 0-1.178-1.674c-1.266-1.307-3.067-2.19-5.102-2.417a9.3 9.3 0 0 0-2.124 0h-.001c-2.061.228-3.882 1.107-5.14 2.405a6.7 6.7 0 0 0-1.194 1.682A5.7 5.7 0 0 0 2 10.657c0 1.106.332 2.218.988 3.201l.006.01c.391.594 1.092 1.39 1.637 1.83l.983.793l-.208.875l.527-.267l.708-.358l.761.225c.467.137.955.227 1.517.29h.005q.515.06 1.026.059c.355 0 .724-.02 1.095-.06a9 9 0 0 0 1.346-.258c.095.7.43 1.337.932 1.81c-.658.208-1.352.358-2.061.436c-.442.048-.883.072-1.312.072q-.627 0-1.253-.072a10.7 10.7 0 0 1-1.861-.36l-2.84 1.438s-.29.131-.44.131c-.418 0-.702-.285-.702-.704c0-.252.067-.598.128-.84l.394-1.653c-.728-.586-1.563-1.544-2.052-2.287A7.76 7.76 0 0 1 0 10.658a7.7 7.7 0 0 1 .787-3.39a8.7 8.7 0 0 1 1.551-2.19c1.61-1.665 3.878-2.73 6.359-3.006a11.3 11.3 0 0 1 2.565 0c2.47.275 4.712 1.353 6.323 3.017a8.6 8.6 0 0 1 1.539 2.192c.466.945.769 1.937.769 2.978a3.06 3.06 0 0 0-2-.005c-.001-.644-.189-1.329-.564-2.09zm4.125 6.977l-.024-.024l-.024-.018l-.024-.018l-.096-.095a4.24 4.24 0 0 1-1.169-2.192q0-.038-.006-.075l-.006-.056l-.035-.144a1.3 1.3 0 0 0-.358-.61a1.386 1.386 0 0 0-1.957 0a1.4 1.4 0 0 0 0 1.963c.191.191.418.311.668.371c.024.012.06.012.084.012q.019 0 .041.006q.023.005.042.006a4.24 4.24 0 0 1 2.231 1.186c.048.048.096.095.131.143a.323.323 0 0 0 .466 0a.35.35 0 0 0 .036-.455m-1.05 4.37l-.025.025c-.119.096-.31.096-.453-.036a.326.326 0 0 1 0-.467c.047-.036.094-.083.141-.13l.002-.002a4.27 4.27 0 0 0 1.187-2.28q.005-.024.006-.043c0-.024 0-.06.012-.084a1.386 1.386 0 0 1 2.326-.67a1.4 1.4 0 0 1 0 1.964c-.167.18-.382.299-.608.359l-.143.036l-.057.005q-.035.006-.075.007a4.2 4.2 0 0 0-2.183 1.173l-.095.096q-.009.01-.018.024t-.018.024m-4.392-1.053l.024.024l.024.018q.015.009.024.018l.096.096a4.25 4.25 0 0 1 1.169 2.19q0 .04.006.076q.005.03.006.057l.035.143c.06.228.18.443.358.611c.537.539 1.42.539 1.957 0a1.4 1.4 0 0 0 0-1.964a1.4 1.4 0 0 0-.668-.371c-.024-.012-.06-.012-.084-.012q-.018 0-.041-.006l-.042-.006a4.25 4.25 0 0 1-2.231-1.185a1.4 1.4 0 0 1-.131-.144a.323.323 0 0 0-.466 0a.325.325 0 0 0-.036.455m1.039-4.358l.024-.024a.32.32 0 0 1 .453.035a.326.326 0 0 1 0 .467c-.047.036-.094.083-.141.13l-.002.002a4.27 4.27 0 0 0-1.187 2.281l-.006.042c0 .024 0 .06-.012.084a1.386 1.386 0 0 1-2.326.67a1.4 1.4 0 0 1 0-1.963c.166-.18.381-.3.608-.36l.143-.035q.026 0 .056-.006q.037-.005.075-.006a4.2 4.2 0 0 0 2.183-1.174l.096-.095l.018-.025z"/></svg>`,
        logoClass: "channel-logo-wecom",
        name:      "WeCom",
        desc:      I18n.t("channels.wecom.desc"),
        setupCmd:  "/channel-manager setup wecom",
        testCmd:   "/channel-manager doctor",
      },
      weixin: {
        logo:      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true"><path fill="#fff" d="M8.796 17.027H8.75c-1.153 0-2.254-.188-3.262-.53L2.65 17.92l.352-2.712C1.162 13.855 0 11.861 0 9.64c0-4.083 3.918-7.39 8.75-7.39c4.174 0 7.665 2.468 8.54 5.77a9 9 0 0 0-.6-.02c-4.364 0-8.19 3.037-8.19 7.11c0 .67.104 1.312.296 1.917M6 8a1 1 0 1 0 0-2a1 1 0 0 0 0 2m5.5.007a1 1 0 1 0 0-2a1 1 0 0 0 0 2"/><path fill="#fff" d="M21.874 19.52C23.187 18.405 24 16.863 24 15.16C24 11.758 20.754 9 16.75 9S9.5 11.758 9.5 15.161s3.246 6.161 7.25 6.161c.95 0 1.856-.155 2.686-.437l2.438 1.407zm-7.564-5.362a1 1 0 1 1 0-2a1 1 0 0 1 0 2m4.88 0a1 1 0 1 1 0-2a1 1 0 0 1 0 2"/></svg>`,
        logoClass: "channel-logo-weixin",
        name:      "Weixin",
        desc:      I18n.t("channels.weixin.desc"),
        setupCmd:  "/channel-manager setup weixin",
        testCmd:   "/channel-manager doctor",
      },
      dingtalk: {
        logo:      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" aria-hidden="true"><path fill="#fff" d="M573.7 252.5C422.5 197.4 201.3 96.7 201.3 96.7c-15.7-4.1-17.9 11.1-17.9 11.1c-5 61.1 33.6 160.5 53.6 182.8c19.9 22.3 319.1 113.7 319.1 113.7S326 357.9 270.5 341.9c-55.6-16-37.9 17.8-37.9 17.8c11.4 61.7 64.9 131.8 107.2 138.4c42.2 6.6 220.1 4 220.1 4s-35.5 4.1-93.2 11.9c-42.7 5.8-97 12.5-111.1 17.8c-33.1 12.5 24 62.6 24 62.6c84.7 76.8 129.7 50.5 129.7 50.5c33.3-10.7 61.4-18.5 85.2-24.2L565 743.1h84.6L603 928l205.3-271.9H700.8l22.3-38.7c.3.5.4.8.4.8S799.8 496.1 829 433.8l.6-1h-.1c5-10.8 8.6-19.7 10-25.8c17-71.3-114.5-99.4-265.8-154.5"/></svg>`,
        logoClass: "channel-logo-dingtalk",
        name:      "DingTalk",
        desc:      I18n.t("channels.dingtalk.desc"),
        setupCmd:  "/channel-manager setup dingtalk",
        testCmd:   "/channel-manager doctor",
      },
      discord: {
        logo:      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true"><path fill="#fff" d="M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z"/></svg>`,
        logoClass: "channel-logo-discord",
        name:      "Discord",
        desc:      I18n.t("channels.discord.desc"),
        setupCmd:  "/channel-manager setup discord",
        testCmd:   "/channel-manager doctor",
      },
      telegram: {
        logo:      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true"><path fill="#fff" d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z"/></svg>`,
        logoClass: "channel-logo-telegram",
        name:      "Telegram",
        desc:      I18n.t("channels.telegram.desc"),
        setupCmd:  "/channel-manager setup telegram",
        testCmd:   "/channel-manager doctor",
      },
    };
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  async function onPanelShow() {
    await _load();
  }

  // ── Data Loading ─────────────────────────────────────────────────────────────

  async function _load({ silent = false } = {}) {
    const container = $("channels-list");
    if (!container) return;
    if (!silent) {
      container.innerHTML = `<div class="channel-loading">${I18n.t("channels.loading")}</div>`;
    }

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
    const enabled   = !!data.enabled;
    const running   = !!data.running;
    const hasConfig = !!data.has_config;

    const card = document.createElement("div");
    card.className = "channel-card";
    card.id = `channel-card-${platform}`;

    card.innerHTML = `
      <div class="channel-card-header">
        <div class="channel-card-identity">
          <span class="channel-logo ${_esc(meta.logoClass)}">${meta.logo}</span>
          <div>
            <div class="channel-card-name">${_esc(meta.name)}</div>
            <div class="channel-card-desc">${_esc(meta.desc)}</div>
          </div>
        </div>
        <div class="channel-card-status">
          ${hasConfig ? _toggleHtml(platform, enabled) : ""}
          <span class="channel-status-badge" id="channel-badge-${_esc(platform)}">${_badgeHtml(enabled, running, hasConfig)}</span>
        </div>
      </div>

      <div class="channel-card-body">
        ${_statusHint(enabled, running, hasConfig)}
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
            ${hasConfig ? I18n.t("channels.btn.reconfigure") : I18n.t("channels.btn.setup")}
          </button>
        </div>
      </div>
    `;

    // Bind events
    card.querySelector(`#btn-test-${platform}`)?.addEventListener("click", () => _runTest(platform));
    card.querySelector(`#btn-configure-${platform}`)?.addEventListener("click", () => _openSetup(platform));
    card.querySelector(`#toggle-${platform}`)?.addEventListener("change", (ev) => _onToggle(platform, ev.target));

    return card;
  }

  function _toggleHtml(platform, enabled) {
    const aria = I18n.t(enabled ? "channels.toggle.on" : "channels.toggle.off");
    return `
      <label class="toggle-switch" title="${_esc(aria)}">
        <input type="checkbox" id="toggle-${_esc(platform)}" ${enabled ? "checked" : ""} aria-label="${_esc(aria)}">
        <span class="toggle-slider"></span>
      </label>
    `;
  }

  // ── Badge & status hint helpers ───────────────────────────────────────────────

  function _badgeHtml(enabled, running, hasConfig) {
    if (running)   return `<span class="badge-running">● ${I18n.t("channels.badge.running")}</span>`;
    if (enabled)   return `<span class="badge-enabled">● ${I18n.t("channels.badge.enabled")}</span>`;
    if (hasConfig) return `<span class="badge-disabled">○ ${I18n.t("channels.badge.disabled")}</span>`;
    return         `<span class="badge-disabled">○ ${I18n.t("channels.badge.notConfigured")}</span>`;
  }

  function _statusHint(enabled, running, hasConfig) {
    if (running) {
      return `<p class="channel-status-hint hint-ok">✓ ${I18n.t("channels.hint.running")}</p>`;
    }
    if (enabled) {
      return `<p class="channel-status-hint hint-warn">⚠ ${I18n.t("channels.hint.enabledNotRunning")}</p>`;
    }
    if (hasConfig) {
      return `<p class="channel-status-hint hint-idle">${I18n.t("channels.hint.disabled")}</p>`;
    }
    return `<p class="channel-status-hint hint-idle">${I18n.t("channels.hint.notConfigured")}</p>`;
  }

  // ── Toggle handler ───────────────────────────────────────────────────────────

  async function _onToggle(platform, checkbox) {
    const desired = checkbox.checked;
    checkbox.disabled = true;
    try {
      const res = await fetch(`/api/channels/${encodeURIComponent(platform)}/enabled`, {
        method:  "PATCH",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ enabled: desired }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "toggle failed");
      await _load({ silent: true });
    } catch (e) {
      checkbox.checked = !desired;
      alert("Error: " + e.message);
    } finally {
      checkbox.disabled = false;
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────────

  // Run E2E test: open a session and send /channel-manager doctor
  async function _runTest(platform) {
    const meta = PLATFORM_META()[platform];
    await _sendToAgent(meta.testCmd, `Channel E2E Test — ${meta.name}`);
  }

  // Open setup: open a session and send /channel-manager setup <platform>
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
