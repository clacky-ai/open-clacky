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
  let _userLicensed   = false;    // whether license is bound to a user (enables upload)
  let _domWired       = false;    // whether one-time DOM listeners have been bound
  let _showSystemSkills = false;  // whether system (source=default) skills are shown

  // ── Uploaded skills registry (persisted in localStorage) ──────────────
  // key: "clacky_uploaded_skills"  value: JSON array of skill name strings
  const UPLOADED_STORAGE_KEY = "clacky_uploaded_skills";

  function _getUploadedSkills() {
    try { return JSON.parse(localStorage.getItem(UPLOADED_STORAGE_KEY) || "[]"); }
    catch (e) { return []; }
  }

  function _markSkillUploaded(skillName) {
    const list = _getUploadedSkills();
    if (!list.includes(skillName)) {
      list.push(skillName);
      localStorage.setItem(UPLOADED_STORAGE_KEY, JSON.stringify(list));
    }
  }

  function _isSkillUploaded(skillName) {
    return _getUploadedSkills().includes(skillName);
  }



  // ── Private helpers ────────────────────────────────────────────────────

  /** Switch tabs inside the skills panel. */
  function _switchTab(tab) {
    _activeTab = tab;
    document.querySelectorAll(".skills-tab").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.tab === tab);
    });
    $("skills-tab-my").style.display    = tab === "my-skills"    ? "" : "none";
    $("skills-tab-brand").style.display = tab === "brand-skills" ? "" : "none";

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

    const card = document.createElement("div");
    card.className = "brand-skill-card";
    card.innerHTML = `
      <div class="brand-skill-card-main">
        <div class="brand-skill-info">
          <div class="brand-skill-title">
            <span class="brand-skill-name">${escapeHtml(name)}</span>
            ${privateBadge}
          </div>
          <div class="brand-skill-desc">${escapeHtml(skill.description || "")}</div>
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

  /** Install or update a brand skill. */
  async function _installBrandSkill(name, btn) {
    const originalText = btn.textContent;
    btn.disabled    = true;
    btn.textContent = I18n.t("skills.brand.btn.installing");

    try {
      const res  = await fetch(`/api/brand/skills/${encodeURIComponent(name)}/install`, { method: "POST" });
      const data = await res.json();

      if (!res.ok || !data.ok) {
        alert(I18n.t("skills.brand.installFailed") + (data.error || I18n.t("skills.brand.unknownError")));
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
      alert(I18n.t("skills.brand.networkError"));
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

  /** Publish a skill to the cloud by calling the server-side auto-package endpoint.
   *  Shows an animated progress bar and transitions through idle → uploading → success/error states.
   *  force: when true, sends ?force=true to overwrite an existing cloud skill.
   */
  async function _publishSkill(skillName, uploadBtn, progressWrap, progressBar, force = false) {
    // ── Transition to "uploading" state ──────────────────────────────────
    uploadBtn.disabled = true;
    uploadBtn.dataset.state = "uploading";
    const btnLabel = uploadBtn.querySelector(".btn-upload-label");
    if (btnLabel) btnLabel.textContent = I18n.t("skills.upload.uploading");

    progressWrap.style.display = "block";
    progressBar.style.width = "0%";

    // Animate progress bar (indeterminate fill) while waiting for server response
    let animPct = 0;
    const animInterval = setInterval(() => {
      // Accelerates to ~85% then slows down to simulate progress
      const remaining = 85 - animPct;
      animPct += Math.max(1, remaining * 0.08);
      if (animPct > 85) animPct = 85;
      progressBar.style.width = animPct + "%";
    }, 150);

    let alreadyExists  = false;  // set when cloud returns "already exists" conflict
    let skipFinalReset = false;  // set when catch block handles its own cleanup + overwrite prompt

    try {
      const url = `/api/my-skills/${encodeURIComponent(skillName)}/publish${force ? "?force=true" : ""}`;
      const res  = await fetch(url, { method: "POST" });
      const data = await res.json();

      clearInterval(animInterval);

      if (!res.ok || !data.ok) {
        // Capture already_exists flag before throwing so we can show overwrite prompt
        alreadyExists = !!data.already_exists;
        throw new Error(data.error || "Publish failed");
      }

      // ── Success: record in localStorage so badge persists across reloads ──
      _markSkillUploaded(skillName);

      // ── Success state ─────────────────────────────────────────────────
      progressBar.style.width = "100%";
      progressBar.dataset.state = "success";
      uploadBtn.dataset.state = "success";
      if (btnLabel) btnLabel.textContent = I18n.t("skills.upload.uploaded");

      // Hold success state briefly, then re-render to show persistent badge
      await new Promise(r => setTimeout(r, 1800));
      await Skills.load();
    } catch (e) {
      clearInterval(animInterval);

      // ── Error state ───────────────────────────────────────────────────
      progressBar.style.width = "100%";
      progressBar.dataset.state = "error";
      uploadBtn.dataset.state = "error";
      if (btnLabel) btnLabel.textContent = I18n.t("skills.upload.failed");

      console.error("[Skills] publish failed", e);

      uploadBtn.title = e.message;
      await new Promise(r => setTimeout(r, 2000));

      // ── Overwrite prompt: if skill already exists in cloud, ask user ──
      if (alreadyExists) {
        // Signal finally to skip its reset — we reset manually here first
        skipFinalReset = true;

        // Reset button so the UI looks clean while the modal is open
        uploadBtn.disabled = false;
        uploadBtn.dataset.state = "";
        uploadBtn.title = I18n.t("skills.upload.publishTip");
        if (btnLabel) btnLabel.textContent = _isSkillUploaded(skillName) ? I18n.t("skills.upload.uploaded") : I18n.t("skills.upload.upload");
        progressWrap.style.display = "none";
        progressBar.style.width = "0%";
        delete progressBar.dataset.state;

        const confirmed = await Modal.confirm(
          I18n.lang() === "zh"
            ? `"${skillName}" 已存在于云端。\n\n是否用当前版本覆盖？`
            : `"${skillName}" already exists in the cloud.\n\nOverwrite with the current version?`
        );
        if (confirmed) {
          // Retry with force=true (PATCH overwrite)
          _publishSkill(skillName, uploadBtn, progressWrap, progressBar, true);
        }
      }
    } finally {
      if (!skipFinalReset) {
        // ── Reset to idle ───────────────────────────────────────────────
        uploadBtn.disabled = false;
        uploadBtn.dataset.state = "";
        uploadBtn.title = I18n.t("skills.upload.publishTip");
        if (btnLabel) {
          // Show "Uploaded" label persistently if this skill was previously uploaded
          btnLabel.textContent = _isSkillUploaded(skillName) ? I18n.t("skills.upload.uploaded") : I18n.t("skills.upload.upload");
        }
        progressWrap.style.display = "none";
        progressBar.style.width = "0%";
        delete progressBar.dataset.state;
      }
    }
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

    // Upload only for non-system, non-invalid skills when user is licensed
    const showUpload = !isSystem && !skill.invalid && _userLicensed;

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
                         : skill.enabled  ? I18n.t("skills.toggle.disable")
                         : I18n.t("skills.toggle.enable");

    card.innerHTML = `
      <div class="skill-card-main">
        <div class="skill-card-info">
          <div class="skill-card-title">
            ${warnIconHtml}
            <span class="skill-name">${escapeHtml(skill.name)}</span>
            <span class="${badgeClass}">${badgeLabel}</span>
            ${skill.invalid ? `<span class="skill-badge skill-badge-invalid">${I18n.t("skills.badge.invalid")}</span>` : ""}
          </div>
          <div class="skill-card-desc">${escapeHtml(skill.description || "")}</div>
        </div>
        <div class="skill-card-actions">
          ${showUpload ? `
          <button class="btn-skill-upload-inline${_isSkillUploaded(skill.name) ? " btn-skill-uploaded" : ""}" title="Publish to cloud" data-state="">
            <svg class="btn-upload-icon" xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
              <polyline points="17 8 12 3 7 8"/>
              <line x1="12" y1="3" x2="12" y2="15"/>
            </svg>
            <span class="btn-upload-label">${_isSkillUploaded(skill.name) ? I18n.t("skills.upload.uploaded") : I18n.t("skills.upload.upload")}</span>
          </button>` : ""}
          <label class="skill-toggle ${toggleDisabled ? "skill-toggle-disabled" : ""}" title="${toggleTitle}">
            <input type="checkbox" class="skill-toggle-input" ${skill.enabled ? "checked" : ""} ${toggleDisabled ? "disabled" : ""}>
            <span class="skill-toggle-track"></span>
          </label>
        </div>
      </div>
      ${errorNoticeHtml}
      <div class="skill-upload-progress-wrap" style="display:none">
        <div class="skill-upload-progress-bar"></div>
      </div>`;

    if (showUpload) {
      const uploadBtn    = card.querySelector(".btn-skill-upload-inline");
      const progressWrap = card.querySelector(".skill-upload-progress-wrap");
      const progressBar  = card.querySelector(".skill-upload-progress-bar");

      // Single click → auto-package and publish to cloud (no file picker)
      uploadBtn.addEventListener("click", () => {
        if (uploadBtn.disabled) return;
        _publishSkill(skill.name, uploadBtn, progressWrap, progressBar);
      });
    }

    if (!isSystem) {
      const checkbox = card.querySelector(".skill-toggle-input");
      checkbox.addEventListener("change", async () => {
        await Skills.toggle(skill.name, checkbox.checked);
      });
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
      container.innerHTML = `<div class="skills-empty">${I18n.t("skills.empty")}</div>`;
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
        console.log("[Skills] load ok, count=", _skills.length, "Router.current=", Router.current);
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
            _brandSkills = [];
            await _loadBrandSkills();
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

        _domWired = true;
      }

      _renderMySkills();
      Skills.renderSection();

      // Restore active tab state immediately
      _switchTab(_activeTab);

      // Async: check brand license status and update Brand Skills tab visibility
      // and user-licensed upload feature.
      fetch("/api/brand/status")
        .then(res => res.json())
        .then(data => {
          const prevLicensed   = _userLicensed;
          const prevActivated  = _brandActivated;

          _brandActivated = data.branded && !data.needs_activation;
          _userLicensed   = !!data.user_licensed;

          // Show the Brand Skills tab for any branded project, even without an active
          // license — the tab itself will show an activation prompt in that case.
          const brandTab = $("tab-brand-skills");
          if (brandTab) brandTab.style.display = data.branded ? "" : "none";

          // Re-render my-skills tab if user_licensed status changed so that the
          // upload buttons appear immediately on first load (they were hidden during
          // the initial synchronous render when _userLicensed was still false).
          if (prevLicensed !== _userLicensed || prevActivated !== _brandActivated) {
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
    async createInSession() {
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
      Sessions.setPendingMessage(session.id, "/skill-creator");
      Sessions.select(session.id);
    },
  };
})();
