// creator.js — Creator Hub panel
//
// Three-section layout:
//   1. Cloud Skills  — published to the platform (version, download count)
//   2. Local Skills  — local only, or published but with local changes
//   3. Create New    — opens a new session with /skill-creator
//
// Only visible when Brand.userLicensed is true.
// Load order: after brand.js, before app.js

const Creator = (() => {
  // ── Private state ────────────────────────────────────────────────────
  let _cloudSkills = [];
  let _localSkills = [];
  let _loading     = false;
  let _domWired    = false;

  // ── Helpers ──────────────────────────────────────────────────────────

  function escapeHtml(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function _t(key) {
    return I18n.t ? I18n.t(key) : key;
  }

  // Returns true if local SKILL.md is newer than the last upload
  function _hasLocalChanges(skill) {
    if (!skill.local_modified_at || !skill.uploaded_at) return false;
    try {
      return new Date(skill.local_modified_at) > new Date(skill.uploaded_at);
    } catch { return false; }
  }

  // ── Data loading ─────────────────────────────────────────────────────

  async function _load() {
    if (_loading) return;
    _loading = true;
    _renderLoading();
    try {
      const res  = await fetch("/api/creator/skills");
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Load failed");

      _cloudSkills = data.cloud_skills || [];
      _localSkills = data.local_skills || [];
      _render();

      if (data.platform_fetch_error) {
        _showNotice(
          I18n.lang() === "zh"
            ? `平台数据加载失败：${data.platform_fetch_error}`
            : `Platform data unavailable: ${data.platform_fetch_error}`,
          "warn"
        );
      }
    } catch (e) {
      console.error("[Creator] load failed", e);
      _renderError(e.message);
    } finally {
      _loading = false;
    }
  }

  // ── Rendering ────────────────────────────────────────────────────────

  function _renderLoading() {
    const cloudList = document.getElementById("creator-cloud-list");
    const localList = document.getElementById("creator-local-list");
    const placeholder = `<div class="creator-loading">${_t("creator.loading")}</div>`;
    if (cloudList) cloudList.innerHTML = placeholder;
    if (localList) localList.innerHTML = "";
  }

  function _renderError(msg) {
    const cloudList = document.getElementById("creator-cloud-list");
    if (cloudList) cloudList.innerHTML = `<div class="creator-empty creator-error">${escapeHtml(msg)}</div>`;
    const localList = document.getElementById("creator-local-list");
    if (localList) localList.innerHTML = "";
  }

  function _render() {
    _renderCloudSection();
    _renderLocalSection();
    _wireNewSkillEntry();
  }

  function _renderCloudSection() {
    const list  = document.getElementById("creator-cloud-list");
    const block = document.getElementById("creator-cloud-block");
    if (!list) return;

    if (_cloudSkills.length === 0) {
      list.innerHTML = `<div class="creator-empty">${_t("creator.cloud.empty")}</div>`;
      return;
    }

    list.innerHTML = "";
    _cloudSkills.forEach(skill => {
      list.appendChild(_buildCloudCard(skill));
    });
  }

  function _renderLocalSection() {
    const list  = document.getElementById("creator-local-list");
    const block = document.getElementById("creator-local-block");
    if (!list) return;

    if (_localSkills.length === 0) {
      list.innerHTML = `<div class="creator-empty">${_t("creator.local.empty")}</div>`;
      return;
    }

    list.innerHTML = "";
    _localSkills.forEach(skill => {
      list.appendChild(_buildLocalCard(skill));
    });
  }

  // ── Cloud card ───────────────────────────────────────────────────────

  function _buildCloudCard(skill) {
    const card = document.createElement("div");
    card.className = "creator-skill-card creator-cloud-card";
    card.dataset.name = skill.name;

    const versionHtml = skill.version
      ? `<span class="creator-version">v${escapeHtml(skill.version)}</span>`
      : "";

    const downloadHtml = typeof skill.download_count === "number"
      ? `<span class="creator-dl-count" title="${_t("creator.downloads")}">
           <svg xmlns="http://www.w3.org/2000/svg" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
             <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
             <polyline points="7 10 12 15 17 10"/>
             <line x1="12" y1="15" x2="12" y2="3"/>
           </svg>
           ${skill.download_count}
         </span>`
      : "";

    // Has local changes indicator
    const changesHtml = skill.has_local_changes
      ? `<span class="creator-changes-badge" title="${_t("creator.hasLocalChanges")}">● ${_t("creator.changed")}</span>`
      : "";

    // Action buttons:
    //   - local_present + has_local_changes → "Update" (publish) + "Iterate" (skill-creator)
    //   - local_present + no changes        → grey disabled "Up to date" + "Iterate"
    //   - no local copy                     → nothing (can only iterate to create local first)
    let actionBtnsHtml = "";
    if (skill.local_present) {
      if (skill.has_local_changes) {
        actionBtnsHtml = `
          <div class="creator-upload-wrap">
            <button class="btn-creator-publish" data-state="">
              <svg class="btn-upload-icon" xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                <polyline points="17 8 12 3 7 8"/>
                <line x1="12" y1="3" x2="12" y2="15"/>
              </svg>
              <span class="btn-upload-label">${_t("creator.btn.update")}</span>
            </button>
            <div class="skill-upload-progress-wrap" style="display:none">
              <div class="skill-upload-progress-bar"></div>
            </div>
          </div>
          <button class="btn-creator-iterate" title="${_t("creator.btn.iterate")}">
            <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="23 4 23 10 17 10"/>
              <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/>
            </svg>
            ${_t("creator.btn.iterate")}
          </button>`;
      } else {
        actionBtnsHtml = `
          <button class="btn-creator-up-to-date" disabled title="${_t("creator.btn.upToDate")}">
            <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="20 6 9 17 4 12"/>
            </svg>
            ${_t("creator.btn.upToDate")}
          </button>
          <button class="btn-creator-iterate" title="${_t("creator.btn.iterate")}">
            <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="23 4 23 10 17 10"/>
              <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/>
            </svg>
            ${_t("creator.btn.iterate")}
          </button>`;
      }
    }

    card.innerHTML = `
      <div class="creator-card-main">
        <div class="creator-card-info">
          <div class="creator-card-title">
            <span class="creator-skill-name">${escapeHtml(skill.name)}</span>
            <span class="creator-badge creator-badge-published">${_t("creator.badge.published")}</span>
            ${changesHtml}
          </div>
          <div class="creator-card-desc">${escapeHtml(skill.description || "")}</div>
          <div class="creator-card-meta">${versionHtml}${downloadHtml}</div>
        </div>
        <div class="creator-card-actions">${actionBtnsHtml}</div>
      </div>`;

    if (skill.local_present && skill.has_local_changes) {
      const btn  = card.querySelector(".btn-creator-publish");
      const wrap = card.querySelector(".skill-upload-progress-wrap");
      const bar  = card.querySelector(".skill-upload-progress-bar");
      btn.addEventListener("click", () => {
        if (btn.disabled) return;
        _publishSkill(skill.name, btn, wrap, bar, true, card, true);
      });
    }

    if (skill.local_present) {
      const iterBtn = card.querySelector(".btn-creator-iterate");
      if (iterBtn) {
        iterBtn.addEventListener("click", () => _iterateSkill(skill.name));
      }
    }

    return card;
  }

  // ── Local card ───────────────────────────────────────────────────────

  function _buildLocalCard(skill) {
    const card = document.createElement("div");
    card.className = "creator-skill-card creator-local-card";
    card.dataset.name = skill.name;

    const shadowHtml = skill.shadowing_brand
      ? `<span class="creator-shadow-badge" title="${_t("creator.shadow.tooltip")}">⚡ ${_t("creator.shadow.label")}</span>`
      : "";

    card.innerHTML = `
      <div class="creator-card-main">
        <div class="creator-card-info">
          <div class="creator-card-title">
            <span class="creator-skill-name">${escapeHtml(skill.name)}</span>
            <span class="creator-badge creator-badge-local">${_t("creator.badge.unpublished")}</span>
            ${shadowHtml}
          </div>
          <div class="creator-card-desc">${escapeHtml(skill.description || "")}</div>
        </div>
        <div class="creator-card-actions">
          <div class="creator-upload-wrap">
            <button class="btn-creator-publish" data-state="">
              <svg class="btn-upload-icon" xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                <polyline points="17 8 12 3 7 8"/>
                <line x1="12" y1="3" x2="12" y2="15"/>
              </svg>
              <span class="btn-upload-label">${_t("creator.btn.publish")}</span>
            </button>
            <div class="skill-upload-progress-wrap" style="display:none">
              <div class="skill-upload-progress-bar"></div>
            </div>
          </div>
        </div>
      </div>`;

    const btn  = card.querySelector(".btn-creator-publish");
    const wrap = card.querySelector(".skill-upload-progress-wrap");
    const bar  = card.querySelector(".skill-upload-progress-bar");
    btn.addEventListener("click", () => {
      if (btn.disabled) return;
      _publishSkill(skill.name, btn, wrap, bar, false, card, false);
    });

    return card;
  }

  // ── Publish logic ────────────────────────────────────────────────────

  async function _publishSkill(skillName, publishBtn, progressWrap, progressBar, force, card, isUpdate) {
    publishBtn.disabled = true;
    publishBtn.dataset.state = "uploading";
    const btnLabel = publishBtn.querySelector(".btn-upload-label");
    if (btnLabel) btnLabel.textContent = I18n.lang() === "zh" ? "发布中…" : "Publishing…";

    progressWrap.style.display = "block";
    progressBar.style.width = "0%";

    let animPct = 0;
    const animInterval = setInterval(() => {
      const remaining = 85 - animPct;
      animPct += Math.max(1, remaining * 0.08);
      if (animPct > 85) animPct = 85;
      progressBar.style.width = animPct + "%";
    }, 150);

    let alreadyExists  = false;
    let skipFinalReset = false;

    try {
      const url  = `/api/my-skills/${encodeURIComponent(skillName)}/publish${force ? "?force=true" : ""}`;
      const res  = await fetch(url, { method: "POST" });
      const data = await res.json();

      clearInterval(animInterval);

      if (!res.ok || !data.ok) {
        alreadyExists = !!data.already_exists;
        throw new Error(data.error || "Publish failed");
      }

      // Success
      progressBar.style.width = "100%";
      progressBar.dataset.state = "success";
      publishBtn.dataset.state = "success";
      if (btnLabel) btnLabel.textContent = I18n.lang() === "zh" ? "已发布 ✓" : "Published ✓";

      await new Promise(r => setTimeout(r, 1400));
      // Reload to get fresh data
      await _load();
      skipFinalReset = true; // _load() re-renders, no need to reset manually

    } catch (e) {
      clearInterval(animInterval);

      progressBar.style.width = "100%";
      progressBar.dataset.state = "error";
      publishBtn.dataset.state = "error";
      if (btnLabel) btnLabel.textContent = I18n.lang() === "zh" ? "发布失败" : "Failed";
      console.error("[Creator] publish failed", e);
      publishBtn.title = e.message;
      await new Promise(r => setTimeout(r, 2000));

      if (alreadyExists && !force) {
        skipFinalReset = true;

        publishBtn.disabled = false;
        publishBtn.dataset.state = "";
        if (btnLabel) btnLabel.textContent = I18n.lang() === "zh" ? "更新" : "Update";
        progressWrap.style.display = "none";
        progressBar.style.width = "0%";
        delete progressBar.dataset.state;

        const confirmed = await Modal.confirm(
          I18n.lang() === "zh"
            ? `"${skillName}" 已存在于平台。\n\n是否用当前版本覆盖？`
            : `"${skillName}" already exists on the platform.\n\nOverwrite with the current version?`
        );
        if (confirmed) {
          _publishSkill(skillName, publishBtn, progressWrap, progressBar, true, card, isUpdate);
        }
      }
    } finally {
      if (!skipFinalReset) {
        publishBtn.disabled = false;
        publishBtn.dataset.state = "";
        if (btnLabel) {
          btnLabel.textContent = isUpdate
            ? (I18n.lang() === "zh" ? "更新" : "Update")
            : (I18n.lang() === "zh" ? "发布" : "Publish");
        }
        progressWrap.style.display = "none";
        progressBar.style.width = "0%";
        delete progressBar.dataset.state;
      }
    }
  }

  // ── Iterate skill (open skill-creator session for an existing skill) ──

  function _iterateSkill(skillName) {
    Skills.createInSession(`/skill-creator ${I18n.t("creator.iterate.prompt")}${skillName}`);
  }

  // ── Create new skill entry ────────────────────────────────────────────

  function _wireNewSkillEntry() {
    const entry = document.getElementById("creator-new-entry");
    if (!entry || entry.dataset.wired) return;
    entry.dataset.wired = "1";
    entry.addEventListener("click", () => Skills.createInSession());
  }

  // ── Notice bar ────────────────────────────────────────────────────────

  function _showNotice(msg, type = "warn") {
    const container = document.getElementById("creator-cloud-list");
    if (!container) return;
    const old = container.querySelector(".creator-notice");
    if (old) old.remove();
    const el = document.createElement("div");
    el.className = `creator-notice creator-notice-${type}`;
    el.textContent = msg;
    container.prepend(el);
  }

  // ── Public API ────────────────────────────────────────────────────────

  return {
    /** Show/hide the creator section.
     *  Hidden for brand consumer users (branded=true, userLicensed=false).
     *  Visible for creators (userLicensed=true) and unbranded users. */
    updateSidebarVisibility() {
      const section = document.getElementById("creator-section");
      if (!section) return;
      const isBrandConsumer = Brand.branded && !Brand.userLicensed;
      section.style.display = isBrandConsumer ? "none" : "";
    },

    /** Called by Router when the creator panel becomes active. */
    onPanelShow() {
      if (!_domWired) {
        _domWired = true;
        _wireNewSkillEntry();
      }
      // Show promo banner and cloud lock for non-licensed users
      const licensed = Brand.userLicensed;
      const banner = document.getElementById("creator-promo-banner");
      const lock   = document.getElementById("creator-cloud-lock");
      const list   = document.getElementById("creator-cloud-list");
      if (banner) banner.style.display = licensed ? "none" : "";
      if (lock)   lock.style.display   = licensed ? "none" : "";
      if (list)   list.style.display   = licensed ? ""     : "none";
      _load();
    },
  };
})();
