// ── Skills — skills state, rendering, enable/disable ──────────────────────
//
// Responsibilities:
//   - Single source of truth for skills data
//   - Render the "Skills" entry in the sidebar
//   - Show/render the skills panel with My Skills / Brand Skills tabs
//   - Toggle enable/disable via PATCH /api/skills/:name/toggle
//   - Create new skill by opening a session with /skill-creator
//
// Panel switching is delegated to Router — Skills only manages data + rendering.
//
// Depends on: WS (ws.js), Sessions (sessions.js), Router (app.js),
//             global $ / escapeHtml helpers
// ─────────────────────────────────────────────────────────────────────────

const Skills = (() => {
  // ── Private state ──────────────────────────────────────────────────────
  let _skills      = [];          // [{ name, description, source, enabled }]
  let _brandSkills = [];          // skills from cloud license API
  let _activeTab   = "my-skills"; // "my-skills" | "brand-skills"
  let _brandActivated = false;    // whether a license is currently active
  let _domWired       = false;    // whether one-time DOM listeners have been bound
  let _showSystemSkills = false;  // whether system (source=default) skills are shown

  // ── Private helpers ────────────────────────────────────────────────────

  /** Switch tabs inside the skills panel. */
  function _switchTab(tab) {
    _activeTab = tab;
    document.querySelectorAll(".skills-tab").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.tab === tab);
    });
    $("skills-tab-my").style.display    = tab === "my-skills"    ? "" : "none";
    $("skills-tab-brand").style.display = tab === "brand-skills" ? "" : "none";

    // Toggle visibility of tab-specific controls in the tab bar
    const showSystemLabel = $("label-show-system");
    const refreshBtn      = $("btn-refresh-brand-skills");
    if (showSystemLabel) showSystemLabel.style.display = tab === "my-skills"    ? "" : "none";
    if (refreshBtn)      refreshBtn.style.display      = tab === "brand-skills" ? "" : "none";

    // Lazy-load brand skills when the tab is first opened
    if (tab === "brand-skills" && _brandSkills.length === 0) {
      _loadBrandSkills();
    }
  }

  /** Fetch brand skills from the server and re-render the tab. */
  async function _loadBrandSkills() {
    const container = $("brand-skills-list");
    if (!container) return;
    container.innerHTML = `<div class="brand-skills-loading">${I18n.t("skills.loading")}</div>`;

    try {
      const res  = await fetch("/api/brand/skills");
      const data = await res.json();

      if (res.status === 403 || (data.ok === false && (data.error || "").toLowerCase().includes("not activated"))) {
        // License not activated — show a friendly prompt instead of an error
        const btn = document.createElement("button");
        btn.className   = "brand-skills-activate-btn";
        btn.textContent = I18n.t("skills.brand.activateBtn");
        btn.addEventListener("click", () => {
          // Reuse the same behaviour as the top banner: navigate to Settings,
          // scroll to the license section, flash it, and focus the input.
          if (typeof Brand !== "undefined" && Brand.goToLicenseInput) {
            Brand.goToLicenseInput();
          } else {
            Router.navigate("settings");
          }
        });

        const wrapper = document.createElement("div");
        wrapper.className = "brand-skills-unlicensed";
        wrapper.innerHTML = `
          <div class="brand-skills-unlicensed-icon">🔒</div>
          <div class="brand-skills-unlicensed-msg">${I18n.t("skills.brand.needsActivation")}</div>`;
        wrapper.appendChild(btn);
        container.innerHTML = "";
        container.appendChild(wrapper);
        return;
      }

      if (!res.ok || !data.ok) {
        container.innerHTML = '<div class="brand-skills-error">' + escapeHtml(data.error || I18n.t("skills.brand.loadFailed")) + "</div>";
        return;
      }

      _brandSkills = data.skills || [];

      // Soft warning: remote API unavailable but local skills returned
      const warningBanner = $("brand-skills-warning");
      if (data.warning) {
        if (warningBanner) {
          warningBanner.textContent = data.warning;
          warningBanner.style.display = "";
        }
      } else {
        if (warningBanner) warningBanner.style.display = "none";
      }

      _renderBrandSkills();
    } catch (e) {
      container.innerHTML = '<div class="brand-skills-error">Network error \u2014 please try again.</div>';
      console.error("[Skills] brand skills load failed", e);
    }
  }

  /** Render all brand skills into the brand-skills tab. */
  function _renderBrandSkills() {
    const container = $("brand-skills-list");
    if (!container) return;
    container.innerHTML = "";

    if (_brandSkills.length === 0) {
      container.innerHTML = `<div class="brand-skills-empty">${I18n.t("skills.brand.empty")}</div>`;
      return;
    }

    _brandSkills.forEach(skill => {
      const card = _renderBrandSkillCard(skill);
      container.appendChild(card);
    });
  }

  /** Render a single brand skill card. */
  function _renderBrandSkillCard(skill) {
    const name             = skill.name;
    const installedVersion = skill.installed_version;
    const latestVersion    = (skill.latest_version || {}).version || skill.version;
    const needsUpdate      = skill.needs_update;

    // Determine action badge
    let statusHtml = "";
    if (!installedVersion) {
      const versionBadge = latestVersion
        ? `<span class="brand-skill-version latest">v${escapeHtml(latestVersion)}</span>` : "";
      statusHtml = `${versionBadge}<button class="btn-brand-install" data-name="${escapeHtml(name)}">${I18n.t("skills.brand.btn.install")}</button>`;
    } else if (needsUpdate) {
      statusHtml = `
        <span class="brand-skill-version installed">v${escapeHtml(installedVersion)}</span>
        <span class="brand-skill-update-arrow">→</span>
        <span class="brand-skill-version latest">v${escapeHtml(latestVersion)}</span>
        <button class="btn-brand-update" data-name="${escapeHtml(name)}">${I18n.t("skills.brand.btn.update")}</button>`;
    } else {
      // Installed and up-to-date — show version badge + "Use" button
      const displayVersion = installedVersion || latestVersion;
      statusHtml = `
        <span class="brand-skill-version installed">v${escapeHtml(displayVersion)} ✓</span>
        <button class="btn-brand-use" data-name="${escapeHtml(name)}">${I18n.t("skills.brand.btn.use")}</button>`;
    }

    // All brand skills are private — always show the private badge
    const privateBadge = `<span class="brand-skill-badge-private" title="${I18n.t("skills.brand.privateTip")}">🔒 ${I18n.t("skills.brand.private")}</span>`;

    // Choose description based on current language
    const currentLang = I18n.lang();
    const description = (currentLang === "zh" && skill.description_zh)
                        ? skill.description_zh
                        : skill.description || "";

    const card = document.createElement("div");
    card.className = "brand-skill-card";
    card.innerHTML = `
      <div class="brand-skill-card-main">
        <div class="brand-skill-info">
          <div class="brand-skill-title">
            <span class="brand-skill-name">${escapeHtml((currentLang === "zh" && skill.name_zh) ? skill.name_zh : name)}</span>
            ${privateBadge}
          </div>
          <div class="brand-skill-desc">${escapeHtml(description)}</div>
        </div>
        <div class="brand-skill-actions">${statusHtml}</div>
      </div>`;

    // Bind install/update/use buttons
    const installBtn = card.querySelector(".btn-brand-install");
    const updateBtn  = card.querySelector(".btn-brand-update");
    const useBtn     = card.querySelector(".btn-brand-use");
    if (installBtn) installBtn.addEventListener("click", () => _installBrandSkill(name, installBtn));
    if (updateBtn)  updateBtn.addEventListener("click",  () => _installBrandSkill(name, updateBtn));
    if (useBtn)     useBtn.addEventListener("click",     () => _useInstalledSkill(name));

    return card;
  }

  /** Show a temporary inline error message below `btn`, auto-dismiss after 5 s. */
  function _showBrandInstallError(btn, message) {
    // Remove any existing error tip on this button's parent
    const existing = btn.parentElement.querySelector(".brand-install-error");
    if (existing) existing.remove();

    const tip = document.createElement("div");
    tip.className   = "brand-install-error";
    tip.textContent = message;
    btn.parentElement.appendChild(tip);
    setTimeout(() => tip.remove(), 5000);
  }

  /** Return a user-friendly message for install/update errors. */
  function _friendlyInstallError(rawError) {
    if (!rawError) return I18n.t("skills.brand.unknownError");
    const lower = rawError.toLowerCase();
    if (lower.includes("timeout") || lower.includes("network error") ||
        lower.includes("execution expired") || lower.includes("failed to open")) {
      return I18n.t("skills.brand.networkRetry");
    }
    return I18n.t("skills.brand.installFailed") + rawError;
  }

  /** Install or update a brand skill. */
  async function _installBrandSkill(name, btn) {
    const originalText = btn.textContent;
    btn.disabled    = true;
    btn.textContent = I18n.t("skills.brand.btn.installing");

    try {
      const res  = await fetch(`/api/brand/skills/${encodeURIComponent(name)}/install`, { method: "POST" });
      const data = await res.json();

      if (!res.ok || !data.ok) {
        _showBrandInstallError(btn, _friendlyInstallError(data.error));
        btn.disabled    = false;
        btn.textContent = originalText;
        return;
      }

      // Update local state to reflect installed version
      const skill = _brandSkills.find(s => s.name === name);
      if (skill) {
        skill.installed_version = data.version;
        skill.needs_update      = false;
      }

      // Re-render brand skills tab
      _renderBrandSkills();

      // Also reload My Skills — the new skill may appear there now
      await Skills.load();
    } catch (e) {
      _showBrandInstallError(btn, I18n.t("skills.brand.networkRetry"));
      btn.disabled    = false;
      btn.textContent = originalText;
    }
  }

  /** Open a new session and trigger a brand skill by sending "/{name}" as the first message. */
  async function _useInstalledSkill(name) {
    const maxN = Sessions.all.reduce((max, s) => {
      const m = s.name.match(/^Session (\d+)$/);
      return m ? Math.max(max, parseInt(m[1], 10)) : max;
    }, 0);
    const res = await fetch("/api/sessions", {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify({ name: "Session " + (maxN + 1), source: "manual" })
    });
    const data = await res.json();
    if (!res.ok) { alert(I18n.t("tasks.sessionError") + (data.error || "unknown")); return; }

    const session = data.session;
    if (!session) return;

    if (!WS.ready) {
      WS.connect();
      Skills.load();
    }

    Sessions.add(session);
    Sessions.renderList();
    Sessions.setPendingMessage(session.id, "/" + name);
    Sessions.select(session.id);
  }

  /** Render a single skill card in My Skills tab. */
  function _renderSkillCard(skill) {
    const card = document.createElement("div");
    // invalid = unrecoverable (can't be used at all); warning = auto-corrected but fully usable
    card.className = "skill-card" + (skill.invalid ? " skill-card-invalid" : "");

    // "default" = built-in gem skills; "brand" = encrypted brand/system skills
    const isSystem   = skill.source === "default" || skill.source === "brand";
    const badgeClass = isSystem ? "skill-badge skill-badge-system" : "skill-badge skill-badge-custom";
    const badgeLabel = isSystem ? I18n.t("skills.badge.system") : I18n.t("skills.badge.custom");

    // Build warning icon for skills with auto-corrected issues (still fully usable)
    // Build error notice for truly invalid skills (can't be used)
    let warnIconHtml = "";
    let errorNoticeHtml = "";
    if (skill.invalid) {
      const reason = skill.invalid_reason || I18n.t("skills.invalid.reason");
      errorNoticeHtml = `<div class="skill-notice skill-notice-error">⚠ ${escapeHtml(reason)}</div>`;
    } else if (skill.warnings && skill.warnings.length > 0) {
      const reason    = skill.warnings.join("\n");
      const tooltip   = I18n.t("skills.warning.tooltip", { reason });
      warnIconHtml = `<span class="skill-warn-icon" data-tooltip="${escapeHtml(tooltip)}">⚠</span>`;
    }

    // toggle is only disabled for system skills or truly invalid ones; warning skills are fine
    const toggleDisabled = isSystem || skill.invalid;
    const toggleTitle    = isSystem     ? I18n.t("skills.systemDisabledTip")
                         : skill.invalid ? I18n.t("skills.invalid.toggleTip")
                         : skill.enabled  ? I18n.t("skills.toggle.disableDesc")
                         : I18n.t("skills.toggle.enableDesc");

    // Choose description based on current language
    const currentLang = I18n.lang();
    const description = (currentLang === "zh" && skill.description_zh)
                        ? skill.description_zh
                        : skill.description || "";

    // Show "Use" button for all skills except invalid ones
    const useButtonHtml = skill.invalid
      ? ""
      : `<button class="btn-skill-use" data-name="${escapeHtml(skill.name)}">${I18n.t("skills.btn.use")}</button>`;

    card.innerHTML = `
      <div class="skill-card-main">
        <div class="skill-card-info">
          <div class="skill-card-title">
            ${warnIconHtml}
            <span class="skill-name">${escapeHtml((currentLang === "zh" && skill.name_zh) ? skill.name_zh : skill.name)}</span>
            <span class="${badgeClass}">${badgeLabel}</span>
            ${skill.invalid ? `<span class="skill-badge skill-badge-invalid">${I18n.t("skills.badge.invalid")}</span>` : ""}
          </div>
          <div class="skill-card-desc">${escapeHtml(description)}</div>
        </div>
        <div class="skill-card-actions">
          <label class="skill-toggle ${toggleDisabled ? "skill-toggle-disabled" : ""}" data-tooltip="${escapeHtml(toggleTitle)}">
            <input type="checkbox" class="skill-toggle-input" ${skill.enabled ? "checked" : ""} ${toggleDisabled ? "disabled" : ""}>
            <span class="skill-toggle-track"></span>
          </label>
          ${useButtonHtml}
        </div>
      </div>
      ${errorNoticeHtml}`;

    // Bind toggle event
    if (!isSystem) {
      const checkbox = card.querySelector(".skill-toggle-input");
      checkbox.addEventListener("change", async () => {
        await Skills.toggle(skill.name, checkbox.checked);
      });
    }

    // Bind "Use" button event
    const useBtn = card.querySelector(".btn-skill-use");
    if (useBtn) {
      useBtn.addEventListener("click", () => _useInstalledSkill(skill.name));
    }

    return card;
  }

  /** Render My Skills tab content. */
  function _renderMySkills() {
    const container = $("skills-list");
    console.log("[Skills] _renderMySkills, container=", container, "_skills.length=", _skills.length);
    if (!container) { console.error("[Skills] skills-list not found!"); return; }
    container.innerHTML = "";

    // Optionally hide system (source=default) skills
    const visible = _showSystemSkills
      ? _skills
      : _skills.filter(s => s.source !== "default");

    if (visible.length === 0) {
      const emptyText     = I18n.t("skills.empty");
      const createBtnText = I18n.t("skills.empty.createBtn");

      const emptyWrapper = document.createElement("div");
      emptyWrapper.className = "skills-empty";

      const emptyTextEl = document.createElement("div");
      emptyTextEl.className   = "skills-empty-text";
      emptyTextEl.textContent = emptyText;

      const createBtn = document.createElement("div");
      createBtn.className = "skills-empty-create-btn";
      createBtn.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M12 2a10 10 0 1 0 10 10A10 10 0 0 0 12 2z"/><path d="M12 8v8"/><path d="M8 12h8"/>
        </svg>
        <span>${escapeHtml(createBtnText)}</span>
        <svg class="skills-empty-create-arrow" xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M5 12h14"/><path d="M12 5l7 7-7 7"/>
        </svg>`;
      createBtn.addEventListener("click", () => Skills.createInSession("/skill-creator"));

      emptyWrapper.appendChild(emptyTextEl);
      emptyWrapper.appendChild(createBtn);
      container.appendChild(emptyWrapper);
    } else {
      // System skills first, then custom
      const sorted = [
        ...visible.filter(s => s.source === "default"),
        ...visible.filter(s => s.source !== "default")
      ];
      sorted.forEach((skill, i) => {
        try {
          container.appendChild(_renderSkillCard(skill));
        } catch (e) {
          console.error("[Skills] _renderSkillCard failed for skill", i, skill.name, e);
        }
      });
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {

    // ── Data ─────────────────────────────────────────────────────────────

    /** Return current skills list (read-only snapshot). */
    get all() { return _skills.slice(); },

    /** Fetch skills from server; re-render sidebar + panel if open. */
    async load() {
      try {
        const res  = await fetch("/api/skills");
        const data = await res.json();
        _skills = data.skills || [];
        Skills.renderSection();
        if (Router.current === "skills") {
          try {
            _renderMySkills();
          } catch (renderErr) {
            console.error("[Skills] _renderMySkills failed", renderErr);
          }
        }
      } catch (e) {
        console.error("[Skills] load failed", e);
      }
    },

    // ── Router interface ──────────────────────────────────────────────────

    /** Called by Router when the skills panel becomes active. */
    onPanelShow() {
      // ── One-time DOM wiring ──────────────────────────────────────────────
      // Bind tab clicks here (not in the IIFE) because $ and the DOM elements
      // are only guaranteed to exist after app.js has loaded and the panel
      // has been shown at least once. Guard with _domWired so we only do this
      // once no matter how many times the user navigates to the Skills panel.
      if (!_domWired) {
        document.querySelectorAll(".skills-tab").forEach(btn => {
          btn.addEventListener("click", () => _switchTab(btn.dataset.tab));
        });

        const refreshBtn = $("btn-refresh-brand-skills");
        if (refreshBtn) {
          refreshBtn.addEventListener("click", async () => {
            // Add spinning animation
            const icon = refreshBtn.querySelector("svg");
            if (icon) {
              icon.classList.add("spinning");
            }
            refreshBtn.disabled = true;
            
            _brandSkills = [];
            await _loadBrandSkills();
            
            // Remove spinning animation
            if (icon) {
              icon.classList.remove("spinning");
            }
            refreshBtn.disabled = false;
          });
        }

        // Wire the "show system skills" checkbox
        const chkSystem = $("chk-show-system-skills");
        if (chkSystem) {
          chkSystem.checked = _showSystemSkills;
          chkSystem.addEventListener("change", () => {
            _showSystemSkills = chkSystem.checked;
            _renderMySkills();
          });
        }

        // Re-render skill cards when the user switches language
        document.addEventListener("langchange", () => {
          _renderMySkills();
          _renderBrandSkills();
        });

        _domWired = true;
      }

      _renderMySkills();
      Skills.renderSection();

      // Restore active tab state immediately
      _switchTab(_activeTab);

      // Async: check brand license status and update Brand Skills tab visibility.
      fetch("/api/brand/status")
        .then(res => res.json())
        .then(data => {
          const prevActivated  = _brandActivated;

          _brandActivated = data.branded && !data.needs_activation;

          // Show the Brand Skills tab for any branded project, even without an active
          // license — the tab itself will show an activation prompt in that case.
          const brandTab = $("tab-brand-skills");
          if (brandTab) brandTab.style.display = data.branded ? "" : "none";

          // Re-render my-skills tab if brand activated status changed.
          if (prevActivated !== _brandActivated) {
            _renderMySkills();
          }
        })
        .catch(() => {
          // On network error, keep whatever is currently shown
        });
    },

    // ── Sidebar rendering ─────────────────────────────────────────────────

    renderSection() {
      // Sidebar item is static in HTML — just update the label text.
      const labelEl = $("skills-sidebar-label");
      if (!labelEl) return;
      labelEl.textContent = I18n.t("sidebar.skills");
    },

    // ── Actions ───────────────────────────────────────────────────────────

    /** Toggle enable/disable for a skill. */
    async toggle(name, enabled) {
      try {
        const res = await fetch(`/api/skills/${encodeURIComponent(name)}/toggle`, {
          method:  "PATCH",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ enabled })
        });
        const data = await res.json();
        if (!res.ok) { alert(I18n.t("skills.toggleError") + (data.error || "unknown")); return; }
        await Skills.load();
      } catch (e) {
        console.error("[Skills] toggle failed", e);
      }
    },

    /** Switch the Skills panel to the brand-skills tab.
     *  Called externally (e.g. from settings.js after license activation) to
     *  guide the user directly to the Brand Skills download page.
     *  Ensures DOM is wired and forces a fresh load of brand skills.
     */
    openBrandSkillsTab() {
      // Make sure the panel DOM listeners are wired before switching tabs
      Skills.onPanelShow();
      // Force reload brand skills (activation may have just happened)
      _brandSkills = [];
      _switchTab("brand-skills");
    },

    /** Reset the skills panel back to My Skills tab and clear brand data.
     *  Called after license unbind so the user is not left on Brand Skills tab.
     */
    resetAfterUnbind() {
      _brandSkills    = [];
      _brandActivated = false;
      _activeTab      = "my-skills";
      // Hide the Brand Skills tab since there is no active license
      const brandTab = $("tab-brand-skills");
      if (brandTab) brandTab.style.display = "none";
      // If the panel is currently visible, switch to My Skills immediately
      const panel = $("skills-panel");
      if (panel && panel.style.display !== "none") {
        _switchTab("my-skills");
      }
    },

    // ── Import bar ────────────────────────────────────────────────────────

    /** Toggle the inline import bar below the My Skills header.
     *  Switches to "my-skills" tab first so the bar is visible.
     *  Wires confirm / cancel / Enter key handlers on first call.
     */
    toggleImportBar() {
      // Always switch to My Skills tab so the import bar appears in context
      _switchTab("my-skills");

      const bar    = $("skill-import-bar");
      const input  = $("skill-import-input");
      const confirmBtn = $("btn-skill-import-confirm");
      const cancelBtn  = $("btn-skill-import-cancel");
      if (!bar) return;

      const isOpen = bar.style.display !== "none";

      if (isOpen) {
        // Close the bar
        bar.style.display = "none";
        if (input) input.value = "";
        return;
      }

      // Open the bar
      bar.style.display = "";
      if (input) {
        input.focus();
        input.placeholder = I18n.t("skills.import.placeholder");
      }

      // Wire one-time listeners (guard with dataset flag)
      if (!bar.dataset.wired) {
        bar.dataset.wired = "1";

        // Confirm button
        confirmBtn.addEventListener("click", () => Skills._doImportFromBar());

        // Enter key in input
        input.addEventListener("keydown", (e) => {
          if (e.key === "Enter") { e.preventDefault(); Skills._doImportFromBar(); }
        });

        // Cancel button
        cancelBtn.addEventListener("click", () => {
          bar.style.display = "none";
          input.value = "";
        });

        // Browse button — open system file picker, upload zip, fill path into input
        const browseBtn  = $("btn-skill-import-browse");
        const fileInput  = $("skill-import-file");
        if (browseBtn && fileInput) {
          browseBtn.addEventListener("click", () => fileInput.click());
          fileInput.addEventListener("change", async () => {
            const file = fileInput.files[0];
            if (!file) return;

            // Show filename immediately so the user sees feedback
            input.value = file.name;
            input.placeholder = "";
            browseBtn.disabled = true;
            browseBtn.style.opacity = "0.5";

            try {
              const form = new FormData();
              form.append("file", file);
              const res  = await fetch("/api/upload", { method: "POST", body: form });
              const data = await res.json();
              if (res.ok && data.path) {
                // Fill the server-side temp path — /skill-add will read it directly
                input.value = data.path;
              } else {
                input.value = "";
                alert(data.error || "Upload failed");
              }
            } catch (e) {
              input.value = "";
              console.error("[Skills] upload error", e);
            } finally {
              browseBtn.disabled = false;
              browseBtn.style.opacity = "";
              // Reset file input so the same file can be picked again if needed
              fileInput.value = "";
            }
          });
        }
      }
    },

    /** Execute import: validate URL, open a session and send /skill-add <url>. */
    async _doImportFromBar() {
      const input = $("skill-import-input");
      const bar   = $("skill-import-bar");
      const url   = (input ? input.value : "").trim();

      if (!url) {
        input && input.focus();
        return;
      }

      // Validate: accept http(s) URLs or absolute local paths (from upload)
      const isUrl       = /^https?:\/\//i.test(url);
      const isLocalPath = url.startsWith("/") || url.startsWith("~");
      if (!isUrl && !isLocalPath) {
        input.classList.add("skill-import-input-error");
        setTimeout(() => input.classList.remove("skill-import-input-error"), 1200);
        input.focus();
        return;
      }

      // Close the bar immediately — the session takes over from here
      if (bar) bar.style.display = "none";
      if (input) input.value = "";

      // Create a new session and queue the /skill-add command
      try {
        const maxN = Sessions.all.reduce((max, s) => {
          const m = s.name.match(/^Session (\d+)$/);
          return m ? Math.max(max, parseInt(m[1], 10)) : max;
        }, 0);
        const res  = await fetch("/api/sessions", {
          method:  "POST",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ name: "Session " + (maxN + 1), source: "manual" })
        });
        const data = await res.json();
        if (!res.ok) { alert(I18n.t("tasks.sessionError") + (data.error || "unknown")); return; }

        const session = data.session;
        if (!session) return;

        if (!WS.ready) { WS.connect(); Tasks.load(); }

        Sessions.add(session);
        Sessions.renderList();
        Sessions.setPendingMessage(session.id, `/skill-add ${url}`);
        Sessions.select(session.id);
      } catch (e) {
        console.error("[Skills] import failed", e);
        alert(I18n.lang() === "zh" ? "导入技能时网络错误。" : "Network error while importing skill.");
      }
    },

    /** Create a new custom skill by opening a session and sending /skill-creator. */
    async createInSession(message) {
      const maxN = Sessions.all.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: "Session " + (maxN + 1), source: "manual" })
      });
      const data = await res.json();
      if (!res.ok) { alert(I18n.t("tasks.sessionError") + (data.error || "unknown")); return; }

      const session = data.session;
      if (!session) return;

      // If WS is not yet connected (e.g. called during onboarding), boot the UI
      // first so WS connects, then use setPendingMessage so the command is sent
      // once the socket is ready.
      if (!WS.ready) {
        WS.connect();
        Tasks.load();
      }

      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, message || "/skill-creator");
      Sessions.select(session.id);
    },
  };
})();
