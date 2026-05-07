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

      // Soft warning: remote API unavailable but local skills returned.
      // Prefer the server-provided warning_code for proper i18n; fall back to
      // the raw `warning` string (legacy / non-codified messages).
      const warningBanner = $("brand-skills-warning");
      const warningText = data.warning_code
        ? I18n.t("skills.brand.warning." + data.warning_code)
        : data.warning;
      if (warningText) {
        if (warningBanner) {
          warningBanner.textContent = warningText;
          // Let i18n re-render pick this up on language switch.
          if (data.warning_code) {
            warningBanner.setAttribute("data-i18n", "skills.brand.warning." + data.warning_code);
          } else {
            warningBanner.removeAttribute("data-i18n");
          }
          warningBanner.style.display = "";
        }
      } else {
        if (warningBanner) {
          warningBanner.style.display = "none";
          warningBanner.removeAttribute("data-i18n");
        }
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

// ─────────────────────────────────────────────────────────────────────────
// SkillAC — slash-command skill autocomplete dropdown + composer bindings
//
// Handles the "/xxx" slash-command autocomplete UI above the message input,
// plus all composer keyboard/composition/input DOM bindings that depend on it
// (Enter to send, / button, IME composition guard).
//
// Moved verbatim from app.js; structural changes only:
//   - `_lastCompositionEndTime` moved into the IIFE closure (was module-level)
//   - The bare DOM bindings (btn-slash, user-input keydown/input/compositionend,
//     btn-create-skill, btn-import-skill) are wrapped in a private
//     `_initDOMBindings()` function called at the end of `init()`.
//
// Depends on: Sessions (sendMessage), Skills (createInSession, toggleImportBar),
//             I18n, global $ helper.
// ─────────────────────────────────────────────────────────────────────────
const SkillAC = (() => {
  let _initialized    = false;
  let _visible        = false;
  let _activeIndex    = -1;
  let _items          = [];  // filtered [{ name, description, encrypted, source }]
  let _currentSession = null; // track active session id for live fetch

  // Load from localStorage, default to false (hide system skills)
  let _showSystemSkills = localStorage.getItem("skill-ac-show-system") === "true";

  // Cross-browser IME composition fix:
  // Safari fires compositionend BEFORE keydown (violating W3C spec), and the
  // gap between compositionend and keydown is ~5ms on Safari. We record the
  // timestamp of compositionend and treat any Enter keydown within 20ms as
  // still-composing. Chrome is unaffected because e.isComposing is still true.
  // Reference: https://bugs.webkit.org/show_bug.cgi?id=165004
  let _lastCompositionEndTime = -Infinity;

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

  // ── DOM bindings: composer keyboard/composition/input + slash button + ────
  // ── skill-panel create/import buttons. Called once from init().           ──
  function _initDOMBindings() {
    // / button: set input to "/" and open skill autocomplete.
    // mousedown + preventDefault prevents the textarea from losing focus
    // (which would trigger the blur→hide timer and immediately close
    //  the dropdown we're about to open).
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
      _toggle();  // Toggle dropdown instead of always opening
      if (_visible) {
        $("btn-slash").classList.add("active");
      }
      input.focus();
    });

    // IME composition guard: record timestamp of compositionend so the
    // Enter keydown handler can detect Safari's out-of-order firing.
    $("user-input").addEventListener("compositionend", () => {
      _lastCompositionEndTime = Date.now();
    });

    // Main composer keydown: SkillAC consumes nav keys first, then Enter → send.
    $("user-input").addEventListener("keydown", e => {
      // Let skill autocomplete consume arrow/enter/escape first
      if (_handleKey(e)) return;

      if (e.key === "Enter" && !e.shiftKey && !e.isComposing && (Date.now() - _lastCompositionEndTime) > 20) {
        e.preventDefault();
        Sessions.sendMessage();
      }
    });

    // Composer input: auto-grow textarea, normalize full-width slash, drive AC.
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
      _update(el.value);
    });

    // Skills panel action buttons (domain belongs to Skills, but the
    // bindings live here because this is where all composer/skill-related
    // DOM wiring was historically colocated).
    $("btn-create-skill").addEventListener("click", () => Skills.createInSession());
    $("btn-import-skill").addEventListener("click", () => Skills.toggleImportBar());
  }

  // Update handler — driven from the input event above. Exposed on the
  // public API for programmatic use too.
  function _update(value) {
    const query = _getSlashQuery(value);
    if (query === null) { _hide(); return; }
    _activeIndex = 0;  // Always highlight the first match
    _render(query);  // async, fire-and-forget
  }

  // Keyboard handler for the dropdown. Returns true if the event was consumed.
  function _handleKey(e) {
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
  }

  return {
    get visible()      { return _visible; },
    get activeIndex()  { return _activeIndex; },

    /** Initialize event listeners (call once on page load). */
    init() {
      if (_initialized) return;
      _initialized = true;

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

      // Wire up all composer/slash DOM bindings.
      _initDOMBindings();
    },

    /** Called on every `input` event — decide whether to show/hide/update. */
    update: _update,

    /** Open dropdown with all skills (triggered by / button). */
    openAll: _openAll,

    /** Toggle dropdown visibility (used by / button). */
    toggle: _toggle,

    /** Hide the dropdown. */
    hide: _hide,

    /** Reload session-scoped skill list when the active session changes. */
    loadForSession: _loadForSession,

    /** Handle keyboard nav inside the dropdown. Returns true if event was consumed. */
    handleKey: _handleKey,
  };
})();
