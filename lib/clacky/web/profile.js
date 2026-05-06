// profile.js — Assistant Memory panel
//
// Three tabs, all read-only views with single-action buttons that delegate to
// the agent via slash-commands:
//
//   🧬 Soul      — SOUL.md rendered. Button opens /onboard scope:soul.
//   👤 User      — USER.md rendered. Button opens /onboard scope:user.
//   🧠 Memories  — list of ~/.clacky/memories/*.md, sorted by updated_at desc.
//                  Per-card "Curate" opens /onboard path:<abs>.
//                  Per-card "Delete" calls DELETE /api/memories/:filename
//                  (with a confirm); the file lands in File Recall.
//
// The single `onboard` skill handles all three slash-command shapes: with no
// args it runs the full first-run ceremony; with `scope:` or `path:` it runs
// the corresponding light curate flow.
//
// Philosophy: the agent's inner state is never hand-edited. The UI shows it
// and offers curation buttons that start agent-led flows.
//
// Load order: after app.js modules (I18n, Sessions, Onboard), before boot.

const Profile = (() => {
  let _wired   = false;
  let _activeTab = "soul";
  let _data    = { user: null, soul: null, memories: [] };

  function $(id) { return document.getElementById(id); }

  function _t(key, args) {
    return (I18n && I18n.t) ? I18n.t(key, args) : key;
  }

  // ── Minimal safe Markdown renderer ──────────────────────────────────
  // Handles:  # H1 / ## H2 / ### H3, **bold**, *em*, `code`,
  //           - / * bullets, numbered lists, blank-line paragraphs.
  // Everything is HTML-escaped first, so raw user Markdown can never
  // inject script/style/event attributes.

  function _escapeHtml(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function _renderInline(text) {
    // Inline: **bold**, *em*, `code`. Text is already HTML-escaped by caller.
    return text
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(^|[^*])\*([^*\s][^*]*?)\*(?!\*)/g, "$1<em>$2</em>");
  }

  function _renderMarkdown(raw) {
    if (!raw || !raw.trim()) return "";
    const escaped = _escapeHtml(raw);
    const lines = escaped.split(/\r?\n/);

    const out = [];
    let listType = null;   // "ul" | "ol" | null
    let paraBuf  = [];

    function flushPara() {
      if (paraBuf.length === 0) return;
      out.push("<p>" + _renderInline(paraBuf.join(" ")) + "</p>");
      paraBuf = [];
    }
    function openList(type) {
      if (listType !== type) {
        closeList();
        out.push("<" + type + ">");
        listType = type;
      }
    }
    function closeList() {
      if (listType) { out.push("</" + listType + ">"); listType = null; }
    }

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      if (trimmed === "") { flushPara(); closeList(); continue; }

      let m;
      if ((m = trimmed.match(/^(#{1,3})\s+(.+)$/))) {
        flushPara(); closeList();
        const level = m[1].length;
        out.push(`<h${level}>` + _renderInline(m[2]) + `</h${level}>`);
        continue;
      }
      if ((m = trimmed.match(/^[-*]\s+(.+)$/))) {
        flushPara(); openList("ul");
        out.push("<li>" + _renderInline(m[1]) + "</li>");
        continue;
      }
      if ((m = trimmed.match(/^\d+\.\s+(.+)$/))) {
        flushPara(); openList("ol");
        out.push("<li>" + _renderInline(m[1]) + "</li>");
        continue;
      }
      if (listType) closeList();
      paraBuf.push(trimmed);
    }
    flushPara(); closeList();
    return out.join("\n");
  }

  function _stripFrontmatter(content) {
    if (!content || !content.startsWith("---")) return content || "";
    const m = content.match(/^---\s*\n[\s\S]*?\n---\s*\n?/);
    return m ? content.slice(m[0].length) : content;
  }

  function _humanBytes(n) {
    if (!n || n < 0) return "0 B";
    const units = ["B", "KB", "MB"];
    let i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n.toFixed(0) : n.toFixed(2)) + " " + units[i];
  }

  // ── Data loading ─────────────────────────────────────────────────────

  async function _loadProfile() {
    try {
      const res  = await fetch("/api/profile");
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "Load failed");
      _data.user = data.user;
      _data.soul = data.soul;
    } catch (e) {
      console.error("[Profile] load profile failed", e);
      _data.user = null;
      _data.soul = null;
    }
  }

  async function _loadMemories() {
    try {
      const res  = await fetch("/api/memories");
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "Load failed");
      _data.memories = data.memories || [];
    } catch (e) {
      console.error("[Profile] load memories failed", e);
      _data.memories = [];
    }
  }

  // ── Rendering ────────────────────────────────────────────────────────

  function _renderIdentitySection(kind) {
    const file    = _data[kind];
    const wrap    = $(`profile-${kind}-body`);
    const status  = $(`profile-${kind}-status`);
    const pathEl  = $(`profile-${kind}-path`);
    if (!wrap) return;

    if (!file) {
      wrap.innerHTML = `<div class="profile-empty">${_t("profile.loadFail")}</div>`;
      if (status) { status.textContent = ""; status.className = "profile-status"; }
      if (pathEl) pathEl.textContent = "";
      return;
    }

    wrap.innerHTML = _renderMarkdown(file.content || "")
      || `<div class="profile-empty">${_t("profile.emptyContent")}</div>`;
    if (pathEl) pathEl.textContent = file.path || "";
    if (status) {
      status.textContent = file.is_default
        ? _t("profile.statusDefault")
        : _t("profile.statusCustom");
      status.className = "profile-status "
        + (file.is_default ? "profile-status-default" : "profile-status-custom");
    }
  }

  function _renderMemories() {
    const list    = $("memories-list");
    const summary = $("memories-summary");
    if (!list) return;

    if (summary) {
      summary.textContent = _data.memories.length
        ? _t("memories.summary", { count: _data.memories.length })
        : _t("memories.emptyHint");
    }

    if (_data.memories.length === 0) {
      list.innerHTML = `<div class="profile-empty">${_t("memories.empty")}</div>`;
      return;
    }

    list.innerHTML = "";
    _data.memories.forEach(m => list.appendChild(_buildMemoryCard(m)));
  }

  function _buildMemoryCard(m) {
    const card = document.createElement("div");
    card.className = "memory-card";
    card.dataset.filename = m.filename;

    const topic   = m.topic || m.filename;
    const desc    = m.description || "";
    const updated = m.updated_at || "";
    const size    = _humanBytes(m.size || 0);

    const head = document.createElement("div");
    head.className = "memory-card-head";
    head.innerHTML = `
      <div class="memory-card-info">
        <div class="memory-card-title" title="${_escapeHtml(m.filename)}">${_escapeHtml(topic)}</div>
        ${desc ? `<div class="memory-card-desc">${_escapeHtml(desc)}</div>` : ""}
        <div class="memory-card-meta">
          <span class="memory-filename">${_escapeHtml(m.filename)}</span>
          <span>${_escapeHtml(updated)}</span>
          <span>${size}</span>
        </div>
      </div>
      <div class="memory-card-actions">
        <button class="btn-memory-curate" title="${_t("memories.curateTitle")}">
          <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M12 20h9"/>
            <path d="M16.5 3.5a2.121 2.121 0 1 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/>
          </svg>
          <span>${_t("memories.curate")}</span>
        </button>
        <button class="btn-memory-delete" title="${_t("memories.deleteTitle")}">
          <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="3 6 5 6 21 6"/>
            <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
            <path d="M10 11v6"/><path d="M14 11v6"/>
            <path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/>
          </svg>
          <span>${_t("memories.delete")}</span>
        </button>
        <button class="btn-memory-expand" title="${_t("memories.expandTitle")}" aria-expanded="false">
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="6 9 12 15 18 9"/>
          </svg>
        </button>
      </div>`;
    card.appendChild(head);

    // Collapsible body — rendered lazily on first expand.
    const body = document.createElement("div");
    body.className = "memory-card-body";
    body.style.display = "none";
    card.appendChild(body);

    head.querySelector(".btn-memory-curate")
      .addEventListener("click", (e) => { e.stopPropagation(); _curateMemory(m); });

    head.querySelector(".btn-memory-delete")
      .addEventListener("click", (e) => { e.stopPropagation(); _deleteMemory(m); });

    const expandBtn = head.querySelector(".btn-memory-expand");
    function toggle() {
      const open = body.style.display !== "none";
      if (open) {
        body.style.display = "none";
        expandBtn.setAttribute("aria-expanded", "false");
        expandBtn.classList.remove("expanded");
      } else {
        if (!body.dataset.loaded) {
          body.innerHTML = `<div class="memory-card-loading">${_t("memories.loading")}</div>`;
          fetch("/api/memories/" + encodeURIComponent(m.filename))
            .then(r => r.json())
            .then(d => {
              if (!d.ok) throw new Error(d.error || "Load failed");
              const stripped = _stripFrontmatter(d.content || "");
              body.innerHTML = _renderMarkdown(stripped)
                || `<div class="profile-empty">${_t("profile.emptyContent")}</div>`;
              body.dataset.loaded = "1";
            })
            .catch(err => {
              body.innerHTML = `<div class="profile-empty">${_escapeHtml(err.message)}</div>`;
            });
        }
        body.style.display = "";
        expandBtn.setAttribute("aria-expanded", "true");
        expandBtn.classList.add("expanded");
      }
    }
    expandBtn.addEventListener("click", (e) => { e.stopPropagation(); toggle(); });
    // Clicking the info area also toggles, for a larger hit-target.
    head.querySelector(".memory-card-info")
      .addEventListener("click", toggle);

    return card;
  }

  // ── Tabs ─────────────────────────────────────────────────────────────

  function _switchTab(tab) {
    if (!tab || tab === _activeTab) return;
    _activeTab = tab;

    document.querySelectorAll(".profile-tab").forEach(el => {
      const isActive = el.dataset.tab === tab;
      el.classList.toggle("active", isActive);
      el.setAttribute("aria-selected", isActive ? "true" : "false");
    });

    ["soul", "user", "memories"].forEach(name => {
      const pane = $(`profile-pane-${name}`);
      if (!pane) return;
      const isActive = name === tab;
      pane.classList.toggle("active", isActive);
      pane.style.display = isActive ? "" : "none";
    });
  }

  // ── Actions ──────────────────────────────────────────────────────────

  // Curate one of the identity files via /onboard scope:<soul|user>.
  async function _curateProfile(scope) {
    const btn = $(`btn-profile-curate-${scope}`);
    if (btn) btn.disabled = true;
    try {
      const lang = (I18n && I18n.lang) ? I18n.lang() : "en";
      const sessionName = _t(
        scope === "soul" ? "profile.curateName.soul" : "profile.curateName.user"
      );
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: sessionName, source: "onboard" })
      });
      const data    = await res.json();
      const session = data.session;
      if (!session) throw new Error("No session returned");

      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(
        session.id,
        `/onboard scope:${scope} lang:${lang}`
      );
      Sessions.select(session.id);
    } catch (e) {
      console.error("[Profile] curate profile failed", e);
      alert(_t("profile.curateFail") + ": " + e.message);
      if (btn) btn.disabled = false;
    }
  }

  // Curate a single memory → /onboard path:<abs> session.
  async function _curateMemory(m) {
    const absPath = m.path || ("~/.clacky/memories/" + m.filename);
    try {
      const name = _t("memories.curateName") + " · " + (m.topic || m.filename);
      const res  = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name, source: "onboard" })
      });
      const data    = await res.json();
      const session = data.session;
      if (!session) throw new Error("No session returned");

      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, `/onboard path:${absPath}`);
      Sessions.select(session.id);
    } catch (e) {
      console.error("[Profile] curate memory failed", e);
      alert(_t("memories.curateFail") + ": " + e.message);
    }
  }

  // Delete a memory directly. Backend uses `trash` semantics so it lands in
  // File Recall and can still be recovered.
  async function _deleteMemory(m) {
    const label = m.topic || m.filename;
    if (!confirm(_t("memories.confirmDelete", { name: label }))) return;

    try {
      const res = await fetch(
        "/api/memories/" + encodeURIComponent(m.filename),
        { method: "DELETE" }
      );
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.ok) {
        throw new Error(data.error || `HTTP ${res.status}`);
      }
      // Optimistic local remove + re-render.
      _data.memories = _data.memories.filter(x => x.filename !== m.filename);
      _renderMemories();
    } catch (e) {
      console.error("[Profile] delete memory failed", e);
      alert(_t("memories.deleteFail") + ": " + e.message);
    }
  }

  // ── Wiring ───────────────────────────────────────────────────────────

  function _wire() {
    if (_wired) return;
    _wired = true;

    // Tabs
    document.querySelectorAll(".profile-tab").forEach(el => {
      el.addEventListener("click", () => _switchTab(el.dataset.tab));
    });

    // Per-tab curate buttons
    const soulBtn = $("btn-profile-curate-soul");
    if (soulBtn) soulBtn.addEventListener("click", () => _curateProfile("soul"));
    const userBtn = $("btn-profile-curate-user");
    if (userBtn) userBtn.addEventListener("click", () => _curateProfile("user"));

    // Memories list reload
    const refreshMemBtn = $("btn-memories-refresh-list");
    if (refreshMemBtn) refreshMemBtn.addEventListener("click", () => _loadAndRender());
  }

  async function _loadAndRender() {
    await Promise.all([_loadProfile(), _loadMemories()]);
    _renderIdentitySection("soul");
    _renderIdentitySection("user");
    _renderMemories();
  }

  // ── Public API ────────────────────────────────────────────────────────

  return {
    onPanelShow() {
      _wire();
      // Re-enable curate buttons on every panel entry — they may have been
      // disabled by a prior click that navigated away.
      ["soul", "user"].forEach(s => {
        const b = $(`btn-profile-curate-${s}`);
        if (b) b.disabled = false;
      });
      _loadAndRender();
    }
  };
})();
