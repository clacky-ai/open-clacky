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
  let _skills     = [];   // [{ name, description, source, enabled }]
  let _activeTab  = "my-skills";  // "my-skills" | "store"

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
    $("skills-tab-my").style.display    = tab === "my-skills" ? "" : "none";
    $("skills-tab-store").style.display = tab === "store"     ? "" : "none";
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
      _renderMySkills();
      _renderStore();
      Skills.renderSection();
      // Wire tab buttons
      document.querySelectorAll(".skills-tab").forEach(btn => {
        btn.onclick = () => _switchTab(btn.dataset.tab);
      });
      // Restore active tab state
      _switchTab(_activeTab);
    },

    // ── Sidebar rendering ─────────────────────────────────────────────────

    renderSection() {
      // Sidebar item is static in HTML — just update the label text.
      const labelEl = $("skills-sidebar-label");
      if (!labelEl) return;
      const total = _skills.length;
      labelEl.textContent = total === 0
        ? "No skills"
        : `${total} skill${total !== 1 ? "s" : ""}`;
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

      Sessions.add(session);
      Sessions.renderList();
      Sessions.select(session.id);  // Router.navigate("session", { id }) via Sessions.select

      const msg = "/skill-add";
      Sessions.appendMsg("user", escapeHtml(msg));
      WS.send({ type: "message", session_id: session.id, content: msg });
    },
  };
})();
