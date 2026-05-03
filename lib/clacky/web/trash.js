// trash.js — Recently Deleted panel
//
// Top-level sidebar panel that lists files moved to trash by the agent
// across every project-scoped trash dir under ~/.clacky/trash/.
//
// Each card shows the original path, project, size and deleted-at,
// plus Restore / Delete buttons. Bulk actions at the top:
// refresh, empty files older than 7 days, empty everything.
//
// Load order: after app.js modules (I18n, Modal), before app.js boot.

const Trash = (() => {
  // ── Private state ────────────────────────────────────────────────────
  let _files      = [];
  let _totals     = { count: 0, size: 0 };
  let _loading    = false;
  let _wired      = false;

  // ── Helpers ──────────────────────────────────────────────────────────

  function $(id) { return document.getElementById(id); }

  function escapeHtml(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function _t(key) {
    return I18n.t ? I18n.t(key) : key;
  }

  function _humanBytes(n) {
    if (!n || n < 0) return "0 B";
    const units = ["B", "KB", "MB", "GB"];
    let i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n.toFixed(0) : n.toFixed(2)) + " " + units[i];
  }

  function _humanTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    const now   = new Date();
    const ms    = now - d;
    const mins  = Math.floor(ms / 60000);
    const hours = Math.floor(ms / 3600000);
    const days  = Math.floor(ms / 86400000);
    const zh    = I18n.lang() === "zh";
    if (mins < 1)   return zh ? "刚刚"        : "just now";
    if (mins < 60)  return zh ? `${mins} 分钟前`  : `${mins}m ago`;
    if (hours < 24) return zh ? `${hours} 小时前` : `${hours}h ago`;
    if (days < 7)   return zh ? `${days} 天前`    : `${days}d ago`;
    return d.toLocaleDateString();
  }

  // ── Data loading ─────────────────────────────────────────────────────

  async function _load() {
    if (_loading) return;
    _loading = true;
    const list = $("trash-list");
    if (list) list.innerHTML =
      `<div class="creator-loading">${_t("trash.loading")}</div>`;
    try {
      const res  = await fetch("/api/trash");
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Load failed");
      _files  = data.files  || [];
      _totals = { count: data.total_count || 0, size: data.total_size || 0 };
      _render();
    } catch (e) {
      console.error("[Trash] load failed", e);
      if (list) list.innerHTML =
        `<div class="creator-empty creator-error">${escapeHtml(e.message)}</div>`;
    } finally {
      _loading = false;
    }
  }

  function _render() {
    const list        = $("trash-list");
    const summary     = $("trash-summary");
    const btnOld      = $("btn-trash-empty-old");
    const btnOrphans  = $("btn-trash-empty-orphans");
    const btnAll      = $("btn-trash-empty-all");
    if (!list) return;

    const orphanCount = _files.filter(f => {
      const root = f.project_root || "";
      return /^\/(?:var\/folders|tmp|private\/var\/folders)\b/.test(root) ||
             /\/d\d{8}-\d+-[a-z0-9]+(?:\/|$)/.test(root);
    }).length;

    if (summary) {
      summary.textContent = _files.length
        ? I18n.t("trash.summary", {
            count: _totals.count,
            size:  _humanBytes(_totals.size)
          }) + (orphanCount > 0 ? "  •  " + I18n.t("trash.summaryOrphans", { count: orphanCount }) : "")
        : "";
    }
    if (btnOld)     btnOld.disabled     = _files.length === 0;
    if (btnOrphans) btnOrphans.disabled = orphanCount === 0;
    if (btnAll)     btnAll.disabled     = _files.length === 0;

    if (_files.length === 0) {
      list.innerHTML = `<div class="creator-empty">${_t("trash.empty")}</div>`;
      return;
    }

    list.innerHTML = "";
    _files.forEach(f => list.appendChild(_buildCard(f)));
  }

  function _buildCard(file) {
    const card = document.createElement("div");
    card.className = "trash-card";
    card.dataset.project = file.project_root;
    card.dataset.path    = file.original_path;

    const original = file.original_path || "";
    const basename = original.split("/").pop() || original;
    // Show last two path segments after basename to give agents context when
    // many files share the same basename (very common: "package.json", "index.js").
    const parts    = original.split("/").filter(Boolean);
    const shortPath = parts.length > 3
      ? ".../" + parts.slice(-3).join("/")
      : original;
    const sizeStr  = _humanBytes(file.file_size || 0);
    const whenStr  = _humanTime(file.deleted_at);
    // Heuristic: if project_root starts with /var/folders or /tmp, or contains
    // a tempdir-style name (d20260502-...), the original project is gone.
    // We still show it, but mark it so the user can clean it up confidently.
    const orphan = /^\/(?:var\/folders|tmp|private\/var\/folders)\b/.test(file.project_root || "") ||
                   /\/d\d{8}-\d+-[a-z0-9]+(?:\/|$)/.test(file.project_root || "");

    card.innerHTML = `
      <div class="trash-card-info">
        <div class="trash-card-title" title="${escapeHtml(original)}">${escapeHtml(basename)}</div>
        <div class="trash-card-path" title="${escapeHtml(original)}">${escapeHtml(shortPath)}</div>
        <div class="trash-card-meta">
          <span class="trash-project" title="${escapeHtml(file.project_root)}">
            <svg xmlns="http://www.w3.org/2000/svg" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
            </svg>
            ${escapeHtml(file.project_name || "")}
          </span>
          <span>${sizeStr}</span>
          <span title="${escapeHtml(file.deleted_at || "")}">${escapeHtml(whenStr)}</span>
          ${orphan ? `<span class="trash-missing" title="${_t("trash.orphanHint")}">⚠ ${_t("trash.orphan")}</span>` : ""}
        </div>
      </div>
      <div class="trash-card-actions">
        <button class="btn-trash-restore" title="${_t("trash.restore")}" ${orphan ? "disabled" : ""}>
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="1 4 1 10 7 10"/>
            <path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/>
          </svg>
          ${_t("trash.restore")}
        </button>
        <button class="btn-trash-delete" title="${_t("trash.delete")}">
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="3 6 5 6 21 6"/>
            <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
            <path d="M10 11v6"/><path d="M14 11v6"/>
          </svg>
        </button>
      </div>`;

    card.querySelector(".btn-trash-restore").addEventListener("click", () =>
      _restoreOne(file, card));
    card.querySelector(".btn-trash-delete").addEventListener("click", () =>
      _deleteOne(file, card));

    return card;
  }

  async function _restoreOne(file, card) {
    const btn = card.querySelector(".btn-trash-restore");
    btn.disabled = true;
    try {
      const res = await fetch("/api/trash/restore", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          project_root:  file.project_root,
          original_path: file.original_path
        })
      });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        alert(I18n.t("trash.restoreFail", {
          msg: data.error || res.statusText
        }));
      } else {
        // Remove card, update totals locally for instant feedback.
        _files = _files.filter(f =>
          !(f.project_root === file.project_root && f.original_path === file.original_path));
        _totals = {
          count: Math.max(0, _totals.count - 1),
          size:  Math.max(0, _totals.size - (file.file_size || 0))
        };
        _render();
      }
    } catch (e) {
      alert(I18n.t("trash.restoreFail", { msg: e.message }));
    } finally {
      btn.disabled = false;
    }
  }

  async function _deleteOne(file, card) {
    const basename = (file.original_path || "").split("/").pop() || file.original_path;
    const confirmed = await Modal.confirm(
      I18n.t("trash.confirmDeleteOne", { name: basename })
    );
    if (!confirmed) return;

    const url = "/api/trash?" + new URLSearchParams({
      project: file.project_root,
      file:    file.original_path
    }).toString();

    try {
      const res  = await fetch(url, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        alert(data.error || res.statusText);
        return;
      }
      _files = _files.filter(f =>
        !(f.project_root === file.project_root && f.original_path === file.original_path));
      _totals = {
        count: Math.max(0, _totals.count - 1),
        size:  Math.max(0, _totals.size - (file.file_size || 0))
      };
      _render();
    } catch (e) {
      alert(e.message);
    }
  }

  async function _emptyBulk(daysOld, confirmKey) {
    const confirmed = await Modal.confirm(_t(confirmKey));
    if (!confirmed) return;

    const qs  = new URLSearchParams();
    qs.set("days_old", String(daysOld));
    const url = "/api/trash?" + qs.toString();

    try {
      const res  = await fetch(url, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        alert(data.error || res.statusText);
        return;
      }
      if (data.deleted_count === 0 && daysOld > 0) {
        alert(_t("trash.nothingOld"));
      } else {
        alert(I18n.t("trash.emptied", {
          count: data.deleted_count || 0,
          size:  _humanBytes(data.freed_size || 0)
        }));
      }
      await _load();
    } catch (e) {
      alert(e.message);
    }
  }

  // Detects trash entries whose original project_root clearly no longer
  // exists (test temp dirs under /var/folders, /tmp, or dir-format "dYYYYMMDD-...").
  // The delete API does permanent deletion on a per-file basis.
  async function _emptyOrphans() {
    const orphans = _files.filter(f => {
      const root = f.project_root || "";
      return /^\/(?:var\/folders|tmp|private\/var\/folders)\b/.test(root) ||
             /\/d\d{8}-\d+-[a-z0-9]+(?:\/|$)/.test(root);
    });
    if (orphans.length === 0) {
      alert(_t("trash.noOrphans"));
      return;
    }
    const confirmed = await Modal.confirm(
      I18n.t("trash.confirmEmptyOrphans", { count: orphans.length })
    );
    if (!confirmed) return;

    let deleted = 0, freed = 0, failed = 0;
    for (const f of orphans) {
      const url = "/api/trash?" + new URLSearchParams({
        project: f.project_root,
        file:    f.original_path
      }).toString();
      try {
        const r = await fetch(url, { method: "DELETE" });
        const d = await r.json();
        if (r.ok && d.ok) {
          deleted += 1;
          freed   += d.freed_size || 0;
        } else {
          failed += 1;
        }
      } catch (_e) {
        failed += 1;
      }
    }
    alert(I18n.t("trash.orphansCleaned", {
      count:  deleted,
      size:   _humanBytes(freed),
      failed: failed
    }));
    await _load();
  }

  function _wire() {
    if (_wired) return;
    _wired = true;
    const btnRefresh = $("btn-trash-refresh");
    const btnOld     = $("btn-trash-empty-old");
    const btnOrphans = $("btn-trash-empty-orphans");
    const btnAll     = $("btn-trash-empty-all");
    if (btnRefresh) btnRefresh.addEventListener("click", () => _load());
    if (btnOld)     btnOld.addEventListener("click",
      () => _emptyBulk(7, "trash.confirmEmptyOld"));
    if (btnOrphans) btnOrphans.addEventListener("click", () => _emptyOrphans());
    if (btnAll)     btnAll.addEventListener("click",
      () => _emptyBulk(0, "trash.confirmEmptyAll"));
  }

  // ── Public API ────────────────────────────────────────────────────────

  return {
    /** Called by Router when the trash panel becomes active. */
    onPanelShow() {
      _wire();
      _load();
    },
  };
})();
