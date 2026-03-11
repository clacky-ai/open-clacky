// ── Skills — skills state, rendering, enable/disable ──────────────────────
//
// Responsibilities:
//   - Single source of truth for skills data
//   - Render the "Skills" entry in the sidebar
//   - Show/render the skills panel with My Skills / Store tabs
//   - Toggle enable/disable via PATCH /api/skills/:name/toggle
//   - Create new skill by opening a session with /skill-add
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
  let _storeSkills = [];          // skills from public store API (empty = not yet loaded)
  let _storeLoaded = false;       // whether store skills have been fetched at least once
  let _activeTab   = "my-skills"; // "my-skills" | "brand-skills" | "store"
  let _brandActivated = false;    // whether a license is currently active
  let _userLicensed   = false;    // whether license is bound to a user (enables upload)
  let _domWired       = false;    // whether one-time DOM listeners have been bound

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

  // ── Store catalog (hardcoded recommended skills) ───────────────────────
  const STORE_SKILLS = [
    {
      name:        "pdf",
      title:       "PDF",
      description: "Read, extract, merge, split, rotate, watermark, encrypt PDFs and run OCR on scanned documents.",
      icon:        "📄",
      repo:        "https://github.com/anthropics/skills/tree/main/skills/pdf"
    },
    {
      name:        "pptx",
      title:       "PowerPoint",
      description: "Create, edit, read and convert .pptx presentation files with beautiful slide design.",
      icon:        "📊",
      repo:        "https://github.com/anthropics/skills/tree/main/skills/pptx"
    },
    {
      name:        "xlsx",
      title:       "Excel / Spreadsheet",
      description: "Open, edit, create and convert .xlsx/.csv spreadsheet files, clean data and build charts.",
      icon:        "📋",
      repo:        "https://github.com/anthropics/skills/tree/main/skills/xlsx"
    },
    {
      name:        "frontend-design",
      title:       "Frontend Design",
      description: "Build distinctive, production-grade web UIs — components, landing pages, dashboards and more.",
      icon:        "🎨",
      repo:        "https://github.com/anthropics/skills/tree/main/skills/frontend-design"
    }
  ];

  // ── Private helpers ────────────────────────────────────────────────────

  /** Switch tabs inside the skills panel. */
  function _switchTab(tab) {
    _activeTab = tab;
    document.querySelectorAll(".skills-tab").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.tab === tab);
    });
    $("skills-tab-my").style.display    = tab === "my-skills"    ? "" : "none";
    $("skills-tab-brand").style.display = tab === "brand-skills" ? "" : "none";
    $("skills-tab-store").style.display = tab === "store"        ? "" : "none";

    // Lazy-load brand skills when the tab is first opened
    if (tab === "brand-skills" && _brandSkills.length === 0) {
      _loadBrandSkills();
    }

    // Lazy-load store skills when the tab is first opened
    if (tab === "store" && !_storeLoaded) {
      _loadStoreSkills();
    }
  }

  /** Fetch public store skills from the server and re-render the store tab.
   *  Falls back to the hardcoded STORE_SKILLS list when the API is unavailable.
   */
  async function _loadStoreSkills() {
    const grid = $("skills-store-grid");
    if (!grid) return;
    grid.innerHTML = '<div class="brand-skills-loading">Loading\u2026</div>';

    try {
      const res  = await fetch("/api/store/skills");
      const data = await res.json();

      if (!res.ok || !data.ok) {
        // API returned an error — fall back to hardcoded catalog
        _storeSkills = STORE_SKILLS.map(s => ({
          slug:        s.name,
          name:        s.title,
          description: s.description,
          icon:        s.icon,
          repo:        s.repo
        }));
      } else {
        _storeSkills = data.skills || [];
        // If server returned empty list, fall back to hardcoded catalog
        if (_storeSkills.length === 0) {
          _storeSkills = STORE_SKILLS.map(s => ({
            slug:        s.name,
            name:        s.title,
            description: s.description,
            icon:        s.icon,
            repo:        s.repo
          }));
        }
      }
    } catch (e) {
      // Network error — fall back to hardcoded catalog
      console.error("[Skills] store skills load failed, using fallback", e);
      _storeSkills = STORE_SKILLS.map(s => ({
        slug:        s.name,
        name:        s.title,
        description: s.description,
        icon:        s.icon,
        repo:        s.repo
      }));
    }

    _storeLoaded = true;
    _renderStore();
  }

  /** Fetch brand skills from the server and re-render the tab. */
  async function _loadBrandSkills() {
    const container = $("brand-skills-list");
    if (!container) return;
    container.innerHTML = '<div class="brand-skills-loading">Loading\u2026</div>';

    try {
      const res  = await fetch("/api/brand/skills");
      const data = await res.json();

      if (!res.ok || !data.ok) {
        container.innerHTML = '<div class="brand-skills-error">' + escapeHtml(data.error || "Failed to load brand skills.") + "</div>";
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
      container.innerHTML = '<div class="brand-skills-empty">No brand skills available for your license.</div>';
      return;
    }

    _brandSkills.forEach(skill => {
      const card = _renderBrandSkillCard(skill);
      container.appendChild(card);
    });
  }

  /** Render a single brand skill card. */
  function _renderBrandSkillCard(skill) {
    const slug             = skill.slug || skill.name;
    const installedVersion = skill.installed_version;
    const latestVersion    = (skill.latest_version || {}).version || skill.version;
    const needsUpdate      = skill.needs_update;

    // Determine action badge
    let statusHtml = "";
    if (!installedVersion) {
      statusHtml = `<button class="btn-brand-install" data-slug="${escapeHtml(slug)}">Install</button>`;
    } else if (needsUpdate) {
      statusHtml = `
        <span class="brand-skill-version installed">v${escapeHtml(installedVersion)}</span>
        <span class="brand-skill-update-arrow">→</span>
        <span class="brand-skill-version latest">v${escapeHtml(latestVersion)}</span>
        <button class="btn-brand-update" data-slug="${escapeHtml(slug)}">Update</button>`;
    } else {
      // Show whichever version is newer: local dev builds may be ahead of the server
      const displayVersion = installedVersion || latestVersion;
      statusHtml = `<span class="brand-skill-version installed">v${escapeHtml(displayVersion)} ✓</span>`;
    }

    // All brand skills are private — always show the private badge
    const privateBadge = '<span class="brand-skill-badge-private" title="Private — licensed to your organization">🔒 Private</span>';

    const card = document.createElement("div");
    card.className = "brand-skill-card";
    card.innerHTML = `
      <div class="brand-skill-card-main">
        <div class="brand-skill-info">
          <div class="brand-skill-title">
            <span class="brand-skill-name">${escapeHtml(skill.name || slug)}</span>
            ${privateBadge}
          </div>
          <div class="brand-skill-desc">${escapeHtml(skill.description || "")}</div>
        </div>
        <div class="brand-skill-actions">${statusHtml}</div>
      </div>`;

    // Bind install/update button
    const installBtn = card.querySelector(".btn-brand-install");
    const updateBtn  = card.querySelector(".btn-brand-update");
    if (installBtn) installBtn.addEventListener("click", () => _installBrandSkill(slug, installBtn));
    if (updateBtn)  updateBtn.addEventListener("click",  () => _installBrandSkill(slug, updateBtn));

    return card;
  }

  /** Install or update a brand skill. */
  async function _installBrandSkill(slug, btn) {
    const originalText = btn.textContent;
    btn.disabled    = true;
    btn.textContent = "Installing…";

    try {
      const res  = await fetch(`/api/brand/skills/${encodeURIComponent(slug)}/install`, { method: "POST" });
      const data = await res.json();

      if (!res.ok || !data.ok) {
        alert("Install failed: " + (data.error || "unknown error"));
        btn.disabled    = false;
        btn.textContent = originalText;
        return;
      }

      // Update local state to reflect installed version
      const skill = _brandSkills.find(s => s.slug === slug);
      if (skill) {
        skill.installed_version = data.version;
        skill.needs_update      = false;
      }

      // Re-render brand skills tab
      _renderBrandSkills();

      // Also reload My Skills — the new skill may appear there now
      await Skills.load();
    } catch (e) {
      alert("Network error during install.");
      btn.disabled    = false;
      btn.textContent = originalText;
    }
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
    if (btnLabel) btnLabel.textContent = "Uploading…";

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
      if (btnLabel) btnLabel.textContent = "Uploaded!";

      // Hold success state briefly, then re-render to show persistent badge
      await new Promise(r => setTimeout(r, 1800));
      await Skills.load();
    } catch (e) {
      clearInterval(animInterval);

      // ── Error state ───────────────────────────────────────────────────
      progressBar.style.width = "100%";
      progressBar.dataset.state = "error";
      uploadBtn.dataset.state = "error";
      if (btnLabel) btnLabel.textContent = "Failed";

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
        uploadBtn.title = "Publish to cloud";
        if (btnLabel) btnLabel.textContent = _isSkillUploaded(skillName) ? "Uploaded" : "Upload";
        progressWrap.style.display = "none";
        progressBar.style.width = "0%";
        delete progressBar.dataset.state;

        const confirmed = await Modal.confirm(
          `"${skillName}" already exists in the cloud.\n\nOverwrite with the current version?`
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
        uploadBtn.title = "Publish to cloud";
        if (btnLabel) {
          // Show "Uploaded" label persistently if this skill was previously uploaded
          btnLabel.textContent = _isSkillUploaded(skillName) ? "Uploaded" : "Upload";
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
    card.className = "skill-card";

    // "default" = built-in gem skills; "brand" = encrypted brand/system skills
    const isSystem   = skill.source === "default" || skill.source === "brand";
    const badgeClass = isSystem ? "skill-badge skill-badge-system" : "skill-badge skill-badge-custom";
    const badgeLabel = isSystem ? "System" : "Custom";

    // Show the Upload button only for non-system skills when user is licensed
    const showUpload = !isSystem && _userLicensed;

    card.innerHTML = `
      <div class="skill-card-main">
        <div class="skill-card-info">
          <div class="skill-card-title">
            <span class="skill-name">${escapeHtml(skill.name)}</span>
            <span class="${badgeClass}">${badgeLabel}</span>
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
            <span class="btn-upload-label">${_isSkillUploaded(skill.name) ? "Uploaded" : "Upload"}</span>
          </button>` : ""}
          <label class="skill-toggle ${isSystem ? "skill-toggle-disabled" : ""}" title="${isSystem ? "System skills cannot be disabled" : (skill.enabled ? "Disable skill" : "Enable skill")}">
            <input type="checkbox" class="skill-toggle-input" ${skill.enabled ? "checked" : ""} ${isSystem ? "disabled" : ""}>
            <span class="skill-toggle-track"></span>
          </label>
        </div>
      </div>
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

    if (_skills.length === 0) {
      container.innerHTML = '<div class="skills-empty">No skills loaded.</div>';
    } else {
      // System skills first, then custom
      const sorted = [
        ..._skills.filter(s => s.source === "default"),
        ..._skills.filter(s => s.source !== "default")
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

  /** Handle skill ZIP upload — triggered by the hidden file input. */
  /** Upload a skill ZIP directly to the cloud.
   *  @param {File}    file  - The ZIP file selected by the user
   *  @param {boolean} force - true = overwrite existing skill (PATCH)
   */
  async function _handleSkillUpload(file, force = false) {
    if (!file) return;

    const uploadBtn = $("btn-upload-skill");
    const statusEl  = $("upload-skill-status");

    if (uploadBtn) { uploadBtn.disabled = true; uploadBtn.textContent = "Uploading…"; }
    if (statusEl)  { statusEl.textContent = ""; statusEl.className = "upload-skill-status"; }

    const formData = new FormData();
    formData.append("skill_file", file, file.name);

    let alreadyExists  = false;  // set when cloud returns "already exists" conflict
    let skipFinalReset = false;  // set when catch block handles overwrite prompt

    try {
      const url  = `/api/my-skills/upload${force ? "?force=true" : ""}`;
      const res  = await fetch(url, { method: "POST", body: formData });
      const data = await res.json();

      if (!res.ok || !data.ok) {
        alreadyExists = !!data.already_exists;
        throw new Error(data.error || "Upload failed");
      }

      // Success
      if (statusEl) {
        statusEl.textContent = `✓ Skill "${data.name}" uploaded to cloud successfully!`;
        statusEl.className   = "upload-skill-status upload-ok";
      }
      // Clear status after 3 seconds
      setTimeout(() => { if (statusEl) { statusEl.textContent = ""; statusEl.className = "upload-skill-status"; } }, 3000);
    } catch (e) {
      if (statusEl) {
        statusEl.textContent = e.message.startsWith("Upload failed") || e.message.startsWith("ZIP")
          ? e.message
          : "Network error during upload.";
        statusEl.className = "upload-skill-status upload-error";
      }
      console.error("[Skills] upload failed", e);

      // Overwrite prompt: if skill already exists in cloud, ask user
      if (alreadyExists) {
        skipFinalReset = true;

        // Reset button cleanly while modal is open
        if (uploadBtn) { uploadBtn.disabled = false; uploadBtn.textContent = "Upload Skill"; }
        const fileInput = $("skill-upload-input");

        // Brief pause so user sees the error before the modal appears
        await new Promise(r => setTimeout(r, 1500));
        if (statusEl) { statusEl.textContent = ""; statusEl.className = "upload-skill-status"; }

        const skillName = file.name.replace(/\.zip$/i, "");
        const confirmed = await Modal.confirm(
          `"${skillName}" already exists in the cloud.\n\nOverwrite with the current version?`
        );
        if (confirmed) {
          // Retry with force=true (PATCH overwrite)
          _handleSkillUpload(file, true);
        } else {
          // User cancelled — reset file input
          if (fileInput) fileInput.value = "";
        }
      }
    } finally {
      if (!skipFinalReset) {
        if (uploadBtn) { uploadBtn.disabled = false; uploadBtn.textContent = "Upload Skill"; }
        // Reset file input so the same file can be re-uploaded if needed
        const fileInput = $("skill-upload-input");
        if (fileInput) fileInput.value = "";
      }
    }
  }

  /** Render Store tab content.
   *  Uses _storeSkills when populated (from API), otherwise falls back to
   *  the hardcoded STORE_SKILLS catalog so the tab is never empty.
   */
  function _renderStore() {
    const grid = $("skills-store-grid");
    if (!grid) return;
    grid.innerHTML = "";

    // Use dynamic API data when available, otherwise use the hardcoded fallback
    const catalog = _storeLoaded && _storeSkills.length > 0
      ? _storeSkills
      : STORE_SKILLS.map(s => ({
          slug:        s.name,
          name:        s.title,
          description: s.description,
          icon:        s.icon,
          repo:        s.repo
        }));

    catalog.forEach(item => {
      // Support both API shape ({ slug, name, ... }) and legacy hardcoded shape ({ name, title, ... })
      const slug        = item.slug  || item.name;
      const title       = item.name  || item.title;
      const description = item.description || "";
      const icon        = item.icon  || "📦";
      const repo        = item.repo  || "";

      const installed = _skills.some(s => s.name === slug);

      const card = document.createElement("div");
      card.className = "store-card";
      card.innerHTML = `
        <div class="store-card-icon">${escapeHtml(icon)}</div>
        <div class="store-card-body">
          <div class="store-card-title">${escapeHtml(title)}</div>
          <div class="store-card-desc">${escapeHtml(description)}</div>
        </div>
        <div class="store-card-actions">
          ${installed
            ? '<span class="store-badge-installed">✓ Installed</span>'
            : `<button class="btn-store-install" data-name="${escapeHtml(slug)}" data-title="${escapeHtml(title)}">Install</button>`
          }
        </div>`;

      if (!installed) {
        card.querySelector(".btn-store-install").addEventListener("click", () => {
          Skills.installFromStore(slug, title, repo);
        });
      }

      grid.appendChild(card);
    });
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
          _renderStore();
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

        // Upload button: triggers hidden file input
        const uploadBtn = $("btn-upload-skill");
        if (uploadBtn) {
          uploadBtn.addEventListener("click", () => {
            const fileInput = $("skill-upload-input");
            if (fileInput) fileInput.click();
          });
        }

        // Hidden file input: fires when user selects a ZIP
        const fileInput = $("skill-upload-input");
        if (fileInput) {
          fileInput.addEventListener("change", (e) => {
            const file = e.target.files && e.target.files[0];
            if (file) _handleSkillUpload(file);
          });
        }

        _domWired = true;
      }

      _renderMySkills();
      _renderStore();
      Skills.renderSection();

      // Restore active tab state immediately
      _switchTab(_activeTab);

      // Async: check brand license status and update Brand Skills tab visibility
      // and user-licensed upload feature.
      fetch("/api/brand/status")
        .then(res => res.json())
        .then(data => {
          _brandActivated = data.branded && !data.needs_activation;
          _userLicensed   = !!data.user_licensed;

          const brandTab = $("tab-brand-skills");
          if (brandTab) brandTab.style.display = _brandActivated ? "" : "none";

          // Show/hide the Upload Skill button based on user_licensed status
          const uploadArea = $("my-skills-upload-area");
          if (uploadArea) uploadArea.style.display = _userLicensed ? "" : "none";

          // If brand tab was active but license is gone now, fall back to my-skills
          if (_activeTab === "brand-skills" && !_brandActivated) {
            _activeTab = "my-skills";
            _switchTab(_activeTab);
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
      const total = _skills.length;
      // Don't show "No skills" when the skills panel is active
      const isActive = Router.current === "skills";
      if (total === 0) {
        labelEl.textContent = isActive ? "Skills" : "No skills";
      } else {
        labelEl.textContent = `${total} skill${total !== 1 ? "s" : ""}`;
      }
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
        if (!res.ok) { alert("Error: " + (data.error || "unknown")); return; }
        await Skills.load();
      } catch (e) {
        console.error("[Skills] toggle failed", e);
      }
    },

    /** Install a skill from the Store by opening a session and sending /skill-add.
     *  repo: optional URL from the store API — falls back to the default GitHub path.
     */
    async installFromStore(name, title, repo) {
      const maxN = Sessions.all.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: "Session " + (maxN + 1) })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error creating session: " + (data.error || "unknown")); return; }

      const session = data.session;
      if (!session) return;

      Sessions.add(session);
      Sessions.renderList();
      Sessions.select(session.id);  // Router.navigate("session", { id }) via Sessions.select

      // Use the repo URL from the store API when available; otherwise fall back to
      // the default GitHub path so hardcoded STORE_SKILLS entries still work.
      const repoUrl = repo || `https://github.com/anthropics/skills/tree/main/skills/${encodeURIComponent(name)}`;
      const msg = `/skill-add Install the "${title}" skill from ${repoUrl}`;
      Sessions.appendMsg("user", escapeHtml(msg));
      WS.send({ type: "message", session_id: session.id, content: msg });
    },

    /** Create a new custom skill by opening a session and sending /skill-add. */
    async createInSession() {
      const maxN = Sessions.all.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: "Session " + (maxN + 1) })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error creating session: " + (data.error || "unknown")); return; }

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
      Sessions.setPendingMessage(session.id, "/skill-add");
      Sessions.select(session.id);
    },
  };
})();
