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
  let _activeTab   = "my-skills"; // "my-skills" | "brand-skills" | "store"
  let _brandActivated = false;    // whether a license is currently active
  let _domWired       = false;    // whether one-time DOM listeners have been bound

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
      statusHtml = `<span class="brand-skill-version installed">v${escapeHtml(installedVersion)} ✓</span>`;
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

  /** Render a single skill card in My Skills tab. */
  function _renderSkillCard(skill) {
    const card = document.createElement("div");
    card.className = "skill-card";

    const isSystem   = skill.source === "default";
    const badgeClass = isSystem ? "skill-badge skill-badge-system" : "skill-badge skill-badge-custom";
    const badgeLabel = isSystem ? "System" : "Custom";

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
          <label class="skill-toggle ${isSystem ? "skill-toggle-disabled" : ""}" title="${isSystem ? "System skills cannot be disabled" : (skill.enabled ? "Disable skill" : "Enable skill")}">
            <input type="checkbox" class="skill-toggle-input" ${skill.enabled ? "checked" : ""} ${isSystem ? "disabled" : ""}>
            <span class="skill-toggle-track"></span>
          </label>
        </div>
      </div>`;

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
    container.innerHTML = "";

    if (_skills.length === 0) {
      container.innerHTML = '<div class="skills-empty">No skills loaded.</div>';
      return;
    }

    // System skills first, then custom
    const sorted = [
      ..._skills.filter(s => s.source === "default"),
      ..._skills.filter(s => s.source !== "default")
    ];
    sorted.forEach(skill => container.appendChild(_renderSkillCard(skill)));
  }

  /** Render Store tab content. */
  function _renderStore() {
    const grid = $("skills-store-grid");
    grid.innerHTML = "";

    STORE_SKILLS.forEach(item => {
      const installed = _skills.some(s => s.name === item.name);

      const card = document.createElement("div");
      card.className = "store-card";
      card.innerHTML = `
        <div class="store-card-icon">${item.icon}</div>
        <div class="store-card-body">
          <div class="store-card-title">${escapeHtml(item.title)}</div>
          <div class="store-card-desc">${escapeHtml(item.description)}</div>
        </div>
        <div class="store-card-actions">
          ${installed
            ? '<span class="store-badge-installed">✓ Installed</span>'
            : `<button class="btn-store-install" data-name="${escapeHtml(item.name)}" data-title="${escapeHtml(item.title)}">Install</button>`
          }
        </div>`;

      if (!installed) {
        card.querySelector(".btn-store-install").addEventListener("click", () => {
          Skills.installFromStore(item.name, item.title);
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
        Skills.renderSection();
        if (Router.current === "skills") {
          _renderMySkills();
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

        _domWired = true;
      }

      _renderMySkills();
      _renderStore();
      Skills.renderSection();

      // Restore active tab state immediately
      _switchTab(_activeTab);

      // Async: check brand license status and update Brand Skills tab visibility.
      // The tab starts visible (see HTML); we hide it only when confirmed not branded.
      fetch("/api/brand/status")
        .then(res => res.json())
        .then(data => {
          _brandActivated = data.branded && !data.needs_activation;

          const brandTab = $("tab-brand-skills");
          if (brandTab) brandTab.style.display = _brandActivated ? "" : "none";

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

    /** Install a skill from the Store by opening a session and sending /skill-add. */
    async installFromStore(name, title) {
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

      const msg = `/skill-add Install the "${title}" skill from https://github.com/anthropics/skills/tree/main/skills/${encodeURIComponent(name)}`;
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
