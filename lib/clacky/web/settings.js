// settings.js — Settings panel logic
// Handles reading, editing, saving, testing AI model configurations.

const Settings = (() => {
  // Local copy of models loaded from server
  let _models = [];
  // Provider presets loaded from server
  let _providers = [];

  // ── Public API ──────────────────────────────────────────────────────────────

  function open() {
    _load();
    _loadBrand();
    _loadBrowserStatus();
  }

  // ── Data Loading ────────────────────────────────────────────────────────────

  async function _load() {
    const container = document.getElementById("model-cards");
    container.innerHTML = `<div class="settings-loading">${I18n.t("settings.models.loading")}</div>`;
    try {
      // Load config and providers in parallel
      const [configRes, providerRes] = await Promise.all([
        fetch("/api/config"),
        fetch("/api/providers")
      ]);
      const configData   = await configRes.json();
      const providerData = await providerRes.json();
      _models    = configData.models   || [];
      _providers = providerData.providers || [];
      _renderCards();
    } catch (e) {
      container.innerHTML = `<div class="settings-error">${I18n.t("settings.models.error", { msg: e.message })}</div>`;
    }
  }

  // ── Rendering ───────────────────────────────────────────────────────────────

  function _renderCards() {
    const container = document.getElementById("model-cards");
    container.innerHTML = "";

    if (_models.length === 0) {
      container.innerHTML = `<div class="settings-empty">${I18n.t("settings.models.empty")}</div>`;
      return;
    }

    _models.forEach((m, i) => _renderCard(container, m, i));
  }

  function _renderCard(container, model, index) {
    const isDefault = model.type === "default";
    const isLite    = model.type === "lite";

    const card = document.createElement("div");
    card.className = "model-card";
    card.dataset.index = index;

    // Build provider options
    const providerOptions = _providers.map(p =>
      `<option value="${p.id}">${p.name}</option>`
    ).join("");

    card.innerHTML = `
      <div class="model-card-header">
        <div class="model-card-badges">
          ${isDefault ? `<span class="badge badge-default">${I18n.t("settings.models.badge.default")}</span>` : ""}
          ${isLite    ? `<span class="badge badge-lite">${I18n.t("settings.models.badge.lite")}</span>` : ""}
          ${!isDefault && !isLite ? `<span class="badge badge-secondary">${I18n.t("settings.models.badge.model", { n: index + 1 })}</span>` : ""}
        </div>
        <div class="model-card-actions">
          ${_models.length > 1
            ? `<button class="btn-model-remove" data-index="${index}" title="Remove this model">×</button>`
            : ""}
        </div>
      </div>

      <div class="model-fields">
        <label class="model-field quick-setup-field" ${(model.model || model.base_url) ? 'style="display:none"' : ''}>
          <span class="field-label">${I18n.t("settings.models.field.quicksetup")}</span>
          <div class="custom-select-wrapper" data-index="${index}">
            <div class="custom-select-trigger">
              <span class="custom-select-value placeholder">${I18n.t("settings.models.placeholder.provider")}</span>
              <svg class="custom-select-arrow" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"></path>
              </svg>
            </div>
            <div class="custom-select-dropdown">
              <div class="custom-select-option" data-value="">${I18n.t("settings.models.placeholder.provider")}</div>
              ${_providers.map(p => `<div class="custom-select-option" data-value="${p.id}">${_esc(p.name)}</div>`).join("")}
              <div class="custom-select-option" data-value="custom">${I18n.t("settings.models.custom")}</div>
            </div>
          </div>
        </label>
        <label class="model-field">
          <span class="field-label">${I18n.t("settings.models.field.model")}</span>
          <div class="model-name-combobox" data-index="${index}">
            <input type="text" class="field-input model-name-input" data-key="model" data-index="${index}"
              placeholder="${I18n.t("settings.models.placeholder.model")}" value="${_esc(model.model)}"
              autocomplete="off">
            <button class="model-name-dropdown-btn" type="button" title="Select from presets">
              <svg width="12" height="12" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"></path>
              </svg>
            </button>
            <div class="model-name-dropdown" style="display:none"></div>
          </div>
        </label>
        <label class="model-field">
          <span class="field-label">${I18n.t("settings.models.field.baseurl")}</span>
          <div class="base-url-combobox" data-index="${index}">
            <input type="text" class="field-input base-url-input" data-key="base_url" data-index="${index}"
              placeholder="${I18n.t("settings.models.placeholder.baseurl")}" value="${_esc(model.base_url)}"
              autocomplete="off">
            <button class="base-url-dropdown-btn" type="button" title="Select preset endpoint">
              <svg width="12" height="12" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"></path>
              </svg>
            </button>
            <div class="base-url-dropdown" style="display:none"></div>
          </div>
        </label>
        <label class="model-field">
          <span class="field-label">
            ${I18n.t("settings.models.field.apikey")}
            <a class="get-apikey-link" data-index="${index}" href="#" target="_blank" rel="noopener" style="display:none;margin-left:8px;font-size:12px;color:var(--accent,#6366f1);text-decoration:none;opacity:0.85;">${I18n.t("settings.models.field.getApiKey")}</a>
          </span>
          <div class="field-input-row">
            <input type="password" class="field-input api-key-input" data-key="api_key" data-index="${index}"
              placeholder="${I18n.t("settings.models.placeholder.apikey")}" value="${_esc(model.api_key_masked)}">
            <button class="btn-toggle-key" data-index="${index}" title="Show/hide key">
              <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"></path>
              </svg>
            </button>
          </div>
        </label>
      </div>

      <div class="model-card-footer">
        <span class="model-test-result" data-index="${index}"></span>
        <div class="model-card-actions-row">
          ${!isDefault ? `<button class="btn-set-default" data-index="${index}" title="${I18n.t("settings.models.btn.setDefault")}">${I18n.t("settings.models.btn.setDefault")}</button>` : ""}
          <button class="btn-save-model btn-primary" data-index="${index}">${I18n.t("settings.models.btn.save")}</button>
        </div>
      </div>
    `;

    container.appendChild(card);
    _bindCardEvents(card, index);
  }

  function _bindCardEvents(card, index) {
    // Custom dropdown interactions
    const customSelectWrapper = card.querySelector(".custom-select-wrapper");
    const trigger = customSelectWrapper.querySelector(".custom-select-trigger");
    const dropdown = customSelectWrapper.querySelector(".custom-select-dropdown");
    const valueSpan = trigger.querySelector(".custom-select-value");
    const options = dropdown.querySelectorAll(".custom-select-option");

    // Toggle dropdown
    trigger.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = dropdown.classList.contains("open");
      // Close all other dropdowns
      document.querySelectorAll(".custom-select-dropdown.open").forEach(d => {
        d.classList.remove("open");
        d.previousElementSibling.classList.remove("open");
      });
      if (!isOpen) {
        dropdown.classList.add("open");
        trigger.classList.add("open");
      }
    });

    // Select option
    options.forEach(option => {
      option.addEventListener("click", (e) => {
        e.stopPropagation();
        const value = option.dataset.value;
        const text = option.textContent;
        
        // Update UI
        valueSpan.textContent = text;
        if (value) {
          valueSpan.classList.remove("placeholder");
        } else {
          valueSpan.classList.add("placeholder");
        }
        
        // Update selected state
        options.forEach(opt => opt.classList.remove("selected"));
        option.classList.add("selected");
        
        // Close dropdown
        dropdown.classList.remove("open");
        trigger.classList.remove("open");
        
        // Auto-fill model & base_url if a provider preset was selected
        const getApiKeyLink = card.querySelector(`.get-apikey-link[data-index="${index}"]`);
        if (value && value !== "custom") {
          const preset = _providers.find(p => p.id === value);
          if (preset) {
            const modelInput   = card.querySelector(`[data-key="model"]`);
            const baseUrlInput = card.querySelector(`[data-key="base_url"]`);
            if (modelInput)   modelInput.value   = preset.default_model || "";
            if (baseUrlInput) baseUrlInput.value = preset.base_url       || "";
            // Show "how to get" link if provider has a website_url
            if (getApiKeyLink && preset.website_url) {
              getApiKeyLink.href = preset.website_url;
              getApiKeyLink.style.display = "";
            } else if (getApiKeyLink) {
              getApiKeyLink.style.display = "none";
            }
          }
        } else if (getApiKeyLink) {
          getApiKeyLink.style.display = "none";
        }
      });
    });

    // Close dropdown when clicking outside
    document.addEventListener("click", () => {
      dropdown.classList.remove("open");
      trigger.classList.remove("open");
    });

    // Toggle API key visibility
    const toggleKeyBtn = card.querySelector(".btn-toggle-key");
    const apiKeyInput = card.querySelector(".api-key-input");
    const eyeIcon = toggleKeyBtn.querySelector("svg");
    
    toggleKeyBtn.addEventListener("click", () => {
      const isPassword = apiKeyInput.type === "password";
      apiKeyInput.type = isPassword ? "text" : "password";
      
      // Update icon
      if (isPassword) {
        // Show eye-off icon
        eyeIcon.innerHTML = `
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"></path>
        `;
      } else {
        // Show eye icon
        eyeIcon.innerHTML = `
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path>
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"></path>
        `;
      }
    });

    // Save: auto-test first, then save if passed
    card.querySelector(".btn-save-model").addEventListener("click", () => _saveModel(index));

    // Remove model
    const removeBtn = card.querySelector(".btn-model-remove");
    if (removeBtn) {
      removeBtn.addEventListener("click", () => _removeModel(index));
    }

    // Set as default model
    const setDefaultBtn = card.querySelector(".btn-set-default");
    if (setDefaultBtn) {
      setDefaultBtn.addEventListener("click", () => _setAsDefault(index));
    }

    // Model name combobox: dropdown button + model list
    const modelCombobox = card.querySelector(".model-name-combobox");
    const modelInput = modelCombobox.querySelector(".model-name-input");
    const modelDropdownBtn = modelCombobox.querySelector(".model-name-dropdown-btn");
    const modelDropdown = modelCombobox.querySelector(".model-name-dropdown");

    // Build model list from current base_url's provider
    const _updateModelDropdown = () => {
      const baseUrlInput = card.querySelector(`[data-key="base_url"]`);
      const baseUrl = baseUrlInput ? baseUrlInput.value.trim().replace(/\/+$/, "") : "";

      // Find provider by matching base_url against BOTH the canonical
      // preset.base_url AND every endpoint_variants[].base_url — otherwise
      // picking e.g. GLM's Coding-Plan variant would wipe the model list
      // because only the canonical URL would match.
      const provider = _providers.find(p => {
        const candidates = [p.base_url].concat(
          Array.isArray(p.endpoint_variants) ? p.endpoint_variants.map(v => v.base_url) : []
        ).filter(Boolean);
        return candidates.some(c => {
          const norm = String(c).replace(/\/+$/, "");
          return baseUrl === norm || baseUrl.startsWith(norm + "/");
        });
      });
      const models = provider?.models || [];

      if (models.length === 0) {
        modelDropdown.innerHTML = '<div class="model-dropdown-empty">No preset models available</div>';
        return;
      }

      // Render model options
      modelDropdown.innerHTML = models.map(m => 
        `<div class="model-dropdown-option" data-value="${_esc(m)}">${_esc(m)}</div>`
      ).join("");

      // Bind click events
      modelDropdown.querySelectorAll(".model-dropdown-option").forEach(opt => {
        opt.addEventListener("click", (e) => {
          e.stopPropagation();
          const value = opt.dataset.value;
          if (modelInput) modelInput.value = value;
          modelDropdown.style.display = "none";
        });
      });
    };

    // Toggle dropdown
    modelDropdownBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = modelDropdown.style.display === "block";
      
      // Close all other model dropdowns
      document.querySelectorAll(".model-name-dropdown").forEach(d => {
        d.style.display = "none";
      });

      if (!isOpen) {
        _updateModelDropdown();
        modelDropdown.style.display = "block";
      }
    });

    // Close dropdown when clicking outside
    document.addEventListener("click", () => {
      modelDropdown.style.display = "none";
    });

    // Re-populate model list when base_url changes
    const baseUrlInput = card.querySelector(`[data-key="base_url"]`);
    if (baseUrlInput) {
      baseUrlInput.addEventListener("blur", () => {
        _updateModelDropdown();
      });
    }

    // Base URL combobox: dropdown button + endpoint_variants list.
    //
    // Rationale: some providers (GLM on Zhipu/Z.ai, MiniMax on .com/.io) run
    // multiple regional / billing-plan endpoints under a single identity.
    // Listing every variant lets the user pick the right one instead of
    // hand-editing the URL, while still allowing free-form input for
    // unknown / self-hosted proxies. Mirrors the model-name combobox.
    //
    // Data source: the endpoint_variants[] field on each provider preset,
    // resolved by matching the currently-entered base_url against every
    // preset's {base_url + endpoint_variants[].base_url}. When no variants
    // are declared for the matched provider (single-endpoint providers like
    // Anthropic, OpenClacky), the dropdown shows an "empty" hint.
    const baseUrlCombobox   = card.querySelector(".base-url-combobox");
    const baseUrlDropdownBtn = baseUrlCombobox.querySelector(".base-url-dropdown-btn");
    const baseUrlDropdown   = baseUrlCombobox.querySelector(".base-url-dropdown");

    // Resolve the "active" provider preset from the current form values:
    // 1. If the Quick Setup select points at a known provider, use that
    //    (even before the base_url input is typed into).
    // 2. Otherwise fall back to matching the current base_url against all
    //    preset base_url + endpoint_variants. Unknown URLs → null.
    const _currentProvider = () => {
      const selected = card.querySelector(".custom-select-option.selected");
      const selectedId = selected?.dataset.value;
      if (selectedId && selectedId !== "custom") {
        const byId = _providers.find(p => p.id === selectedId);
        if (byId) return byId;
      }
      const url = (baseUrlInput?.value || "").trim().replace(/\/+$/, "");
      if (!url) return null;
      return _providers.find(p => {
        const candidates = [p.base_url].concat(
          Array.isArray(p.endpoint_variants) ? p.endpoint_variants.map(v => v.base_url) : []
        ).filter(Boolean);
        return candidates.some(c => {
          const norm = String(c).replace(/\/+$/, "");
          return url === norm || url.startsWith(norm + "/");
        });
      }) || null;
    };

    const _renderBaseUrlDropdown = () => {
      const provider = _currentProvider();
      const variants = provider && Array.isArray(provider.endpoint_variants)
        ? provider.endpoint_variants
        : [];

      if (variants.length === 0) {
        baseUrlDropdown.innerHTML =
          `<div class="model-dropdown-empty">${I18n.t("settings.models.baseurl.noVariants")}</div>`;
        return;
      }

      baseUrlDropdown.innerHTML = variants.map(v => {
        // Prefer i18n key (localised per UI language); fall back to literal
        // `label` (shipped English copy) and finally to base_url for safety.
        // Pattern: _translateVariant(v) -> "大陆 · 按量付费" in zh, "Mainland · Pay-as-you-go" in en.
        const translated = v.label_key ? I18n.t(v.label_key) : null;
        // I18n.t typically returns the key itself when missing — treat that as a miss.
        const labelText = (translated && translated !== v.label_key) ? translated : (v.label || v.base_url);
        const label = _esc(labelText);
        const url   = _esc(v.base_url);
        return `
          <div class="model-dropdown-option base-url-dropdown-option" data-value="${url}">
            <div class="base-url-dropdown-label">${label}</div>
            <div class="base-url-dropdown-url">${url}</div>
          </div>`;
      }).join("");

      baseUrlDropdown.querySelectorAll(".base-url-dropdown-option").forEach(opt => {
        opt.addEventListener("click", (e) => {
          e.stopPropagation();
          if (baseUrlInput) {
            baseUrlInput.value = opt.dataset.value;
            // Trigger model-list refresh since base_url just changed.
            _updateModelDropdown();
          }
          baseUrlDropdown.style.display = "none";
        });
      });
    };

    baseUrlDropdownBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = baseUrlDropdown.style.display === "block";
      // Close sibling dropdowns (model-name + other base-url) to avoid overlap.
      document.querySelectorAll(".model-name-dropdown, .base-url-dropdown").forEach(d => {
        d.style.display = "none";
      });
      if (!isOpen) {
        _renderBaseUrlDropdown();
        baseUrlDropdown.style.display = "block";
      }
    });

    // Close dropdown when clicking outside
    document.addEventListener("click", () => {
      baseUrlDropdown.style.display = "none";
    });
  }

  // ── Read form values from a card ────────────────────────────────────────────

  function _readCard(index) {
    const card = document.querySelector(`.model-card[data-index="${index}"]`);
    if (!card) return null;
    return {
      index,
      model:            card.querySelector(`[data-key="model"]`).value.trim(),
      base_url:         card.querySelector(`[data-key="base_url"]`).value.trim(),
      api_key:          card.querySelector(`[data-key="api_key"]`).value.trim(),
      anthropic_format: false,
      type:             _models[index]?.type ?? null
    };
  }

  // ── Save ─────────────────────────────────────────────────────────────────────

  async function _saveModel(index) {
    const saveBtn = document.querySelector(`.btn-save-model[data-index="${index}"]`);
    const updated = _readCard(index);
    if (!updated) return;

    saveBtn.disabled = true;

    // Step 1: auto-test first
    saveBtn.textContent = I18n.t("settings.models.btn.testing");
    _showTestResult(index, null, "");

    try {
      const testRes = await fetch("/api/config/test", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...updated, index })
      });
      const testData = await testRes.json();
      _showTestResult(index, testData.ok, testData.message);

      if (!testData.ok) {
        // Test failed — stop, let user fix
        saveBtn.textContent = I18n.t("settings.models.btn.save");
        saveBtn.disabled = false;
        return;
      }
    } catch (e) {
      _showTestResult(index, false, e.message);
      saveBtn.textContent = I18n.t("settings.models.btn.save");
      saveBtn.disabled = false;
      return;
    }

    // Step 2: test passed — now save via single-item endpoint.
    //
    // Contract (see http_server.rb):
    //   - Row has an id already → PATCH /api/config/models/:id
    //   - No id yet (locally-added row) → POST /api/config/models to
    //     create, then capture the server-assigned id.
    // We NEVER send "the whole list" — each save touches exactly one row,
    // so no bug in this function can ever affect another model's api_key.
    saveBtn.textContent = I18n.t("settings.models.btn.saving");

    const existing = _models[index] || {};
    const hasId    = !!existing.id;

    // For PATCH: only send api_key if the user actually typed something
    // non-masked. The masked display value ("sk-ab12****...5678") must
    // never be sent as api_key — the server treats it as "no change"
    // defensively, but the cleanest path is simply to omit it.
    const payload = {
      model:            updated.model,
      base_url:         updated.base_url,
      anthropic_format: updated.anthropic_format,
      type:             updated.type
    };
    if (updated.api_key && !updated.api_key.includes("****")) {
      payload.api_key = updated.api_key;
    }

    try {
      let res, data;
      if (hasId) {
        res  = await fetch(`/api/config/models/${encodeURIComponent(existing.id)}`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        });
        data = await res.json();
      } else {
        // Creation requires a non-empty api_key — surface a friendly
        // error rather than a server 422.
        if (!payload.api_key) {
          saveBtn.textContent = I18n.t("settings.models.btn.save");
          saveBtn.disabled    = false;
          _showTestResult(index, false, I18n.t("settings.models.placeholder.apikey"));
          return;
        }
        res  = await fetch(`/api/config/models`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        });
        data = await res.json();
        if (data.ok && data.id) {
          // Record the assigned id so subsequent saves become PATCH.
          _models[index].id = data.id;
        }
      }

      if (data.ok) {
        saveBtn.textContent = I18n.t("settings.models.btn.saved");
        setTimeout(() => { saveBtn.textContent = I18n.t("settings.models.btn.save"); saveBtn.disabled = false; }, 1500);
        // Reload to get fresh masked keys
        setTimeout(_load, 1600);
      } else {
        saveBtn.textContent = I18n.t("settings.models.btn.save");
        saveBtn.disabled = false;
        _showTestResult(index, false, data.error || I18n.t("settings.models.saveFailed"));
      }
    } catch (e) {
      saveBtn.textContent = I18n.t("settings.models.btn.save");
      saveBtn.disabled = false;
      _showTestResult(index, false, e.message);
    }
  }

  function _showTestResult(index, ok, message) {
    const el = document.querySelector(`.model-test-result[data-index="${index}"]`);
    if (!el) return;
    if (ok === null) { el.textContent = ""; el.className = "model-test-result"; return; }
    el.textContent = ok ? `✓ ${message || I18n.t("settings.models.connected")}` : `✗ ${I18n.t("settings.models.testFail")}: ${message || I18n.t("settings.models.failed")}`;
    el.className   = `model-test-result ${ok ? "result-ok" : "result-fail"}`;
  }

  // ── Set as Default Model ───────────────────────────────────────────────────

  async function _setAsDefault(index) {
    const btn = document.querySelector(`.btn-set-default[data-index="${index}"]`);
    if (!btn) return;

    const target = _models[index];
    if (!target || !target.id) {
      // Can only promote saved models. Locally-added unsaved cards have
      // no id yet — user must save them first.
      alert(I18n.t("settings.models.setDefaultFailed"));
      return;
    }

    btn.disabled    = true;
    btn.textContent = I18n.t("settings.models.btn.setting");

    try {
      const res = await fetch(`/api/config/models/${encodeURIComponent(target.id)}/default`, {
        method: "POST"
      });
      const data = await res.json();

      if (data.ok) {
        btn.textContent = I18n.t("settings.models.btn.done");
        // Reload to refresh the UI
        setTimeout(_load, 800);
      } else {
        btn.textContent = I18n.t("settings.models.btn.setDefault");
        btn.disabled    = false;
        alert(data.error || I18n.t("settings.models.setDefaultFailed"));
      }
    } catch (e) {
      btn.textContent = I18n.t("settings.models.btn.setDefault");
      btn.disabled    = false;
      alert(I18n.t("settings.models.errorPrefix") + e.message);
    }
  }

  // ── Add / Remove model ───────────────────────────────────────────────────────

  function _addModel() {
    // Locally append an empty card. No server call here — the new entry
    // is persisted via POST /api/config/models only when the user clicks
    // "Save" (inside _saveModel). This means typing into a half-filled
    // new card can never mutate the real config on the backend.
    //
    // UX convention: a newly added model becomes the "default" once
    // saved — users overwhelmingly add a new model because they want to
    // use it. We mark it default locally for the preview, and flip the
    // other cards' type to null so the UI only shows one default badge.
    // The backend enforces the single-default invariant on save anyway.
    _models.forEach(m => { if (m.type === "default") m.type = null; });
    _models.push({
      id:               null,   // will be assigned by server on first save
      index:            _models.length,
      model:            "",
      base_url:         "",
      api_key_masked:   "",
      anthropic_format: false,
      type:             "default"
    });
    _renderCards();

    // Scroll the new (last) card into view.
    //
    // Why not just scrollIntoView: the settings panel uses #settings-body
    // as a flex scroll container. When the page hasn't overflowed yet,
    // scrollIntoView is a no-op; and across browsers the "smooth" path
    // has been flaky when the scrolling element is a flex child.
    //
    // Two rAFs ensure the freshly rendered card has been laid out before
    // we compute its position.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        const container = document.getElementById("settings-body");
        if (!container) return;
        const cards = container.querySelectorAll(".model-card");
        const last  = cards[cards.length - 1];
        if (!last) return;

        // Align the new card's top with the container's top, minus a
        // small breathing-room offset so it doesn't touch the edge.
        // offsetTop is relative to the nearest positioned ancestor, so
        // we compute position via getBoundingClientRect delta — robust
        // regardless of the card's offsetParent chain.
        const OFFSET = 16;
        const delta  = last.getBoundingClientRect().top
                     - container.getBoundingClientRect().top;
        container.scrollTo({
          top:      container.scrollTop + delta - OFFSET,
          behavior: "smooth"
        });

        // Put focus on the new card's first input so the user can start
        // typing immediately.
        const firstInput = last.querySelector("input, select, textarea");
        if (firstInput) firstInput.focus({ preventScroll: true });
      });
    });
  }

  async function _removeModel(index) {
    if (_models.length <= 1) return;
    const modelName = _models[index]?.model || String(index + 1);
    const confirmed = await Modal.confirm(I18n.t("settings.models.confirmRemove", { model: modelName }));
    if (!confirmed) return;

    const target = _models[index];

    // Unsaved local card → just drop it from the local list, no server call.
    if (!target || !target.id) {
      _models.splice(index, 1);
      _renderCards();
      return;
    }

    try {
      const res = await fetch(`/api/config/models/${encodeURIComponent(target.id)}`, {
        method: "DELETE"
      });
      // Whatever the server says, reload to reflect the true state.
      // (On error, _load will re-show the model.)
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        alert(data.error || I18n.t("settings.models.setDefaultFailed"));
      }
    } catch (_) { /* ignore */ }

    // Reload fresh state
    _load();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function _esc(str) {
    return (str || "").replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
  }

  // ── Rerun onboard ────────────────────────────────────────────────────────────

  async function _rerunOnboard() {
    const btn = document.getElementById("btn-rerun-onboard");
    btn.disabled    = true;
    btn.textContent = I18n.t("settings.personalize.btn.starting");

    try {
      // Close settings panel and navigate to chat, then start the onboard session.
      // Onboard.startSoulSession() creates a new session, selects it, and sends /onboard.
      Router.navigate("chat");
      await Onboard.startSoulSession();
    } catch (e) {
      btn.disabled    = false;
      btn.textContent = I18n.t("settings.personalize.btn.rerun");
    }
  }

  // ── Browser Setup ─────────────────────────────────────────────────────────────

  async function _loadBrowserStatus() {
    try {
      const res  = await fetch("/api/browser/status");
      const data = await res.json();
      const desc        = document.getElementById("browser-status-desc");
      const btn         = document.getElementById("btn-browser-setup");
      const toggleWrap  = document.getElementById("browser-toggle-wrap");
      const toggleInput = document.getElementById("browser-toggle-input");

      // File doesn't exist → not set up yet
      if (data.enabled === undefined || data.enabled === null) {
        desc.textContent = I18n.t("settings.browser.desc");
        btn.textContent  = I18n.t("settings.browser.btn");
        toggleWrap.style.display = "none";
        return;
      }

      // Configured — show toggle + reconfigure button
      const version = data.chrome_version ? ` (Chrome v${data.chrome_version})` : "";
      desc.textContent     = I18n.t(data.enabled ? "settings.browser.configured" : "settings.browser.disabled") + version;
      btn.textContent      = I18n.t("settings.browser.btn.reconfigure");
      toggleWrap.style.display = "inline-block";
      toggleInput.checked  = data.enabled;

      // Only bind once
      if (!toggleInput.dataset.bound) {
        toggleInput.dataset.bound = "1";
        toggleInput.addEventListener("change", _toggleBrowser);
      }
    } catch (_) { /* non-critical */ }
  }

  async function _toggleBrowser() {
    const toggleInput = document.getElementById("browser-toggle-input");
    toggleInput.disabled = true;
    try {
      const res  = await fetch("/api/browser/toggle", { method: "POST" });
      const data = await res.json();
      if (!data.ok) throw new Error(data.error || "toggle failed");
      await _loadBrowserStatus();
    } catch (_) {
      // Revert on failure
      toggleInput.checked  = !toggleInput.checked;
    } finally {
      toggleInput.disabled = false;
    }
  }

  async function _setupBrowser() {
    const btn = document.getElementById("btn-browser-setup");
    btn.disabled    = true;
    btn.textContent = I18n.t("settings.browser.btn.starting");
    try {
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: "🌐 Browser Setup", source: "setup" })
      });
      const data    = await res.json();
      const session = data.session;
      if (!session) throw new Error("No session returned");
      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, "/browser-setup");
      Sessions.select(session.id);
    } catch (e) {
      btn.disabled    = false;
      btn.textContent = I18n.t("settings.browser.btn");
    }
  }

  // ── Brand & License ───────────────────────────────────────────────────────────

  // Whether the server was started with --brand-test (relaxed key validation).
  let _brandTestMode = false;

  // Load and render the current brand/license status in Settings.
  async function _loadBrand() {
    try {
      const res  = await fetch("/api/brand/status");
      const data = await res.json();
      _brandTestMode = !!data.test_mode;
      _renderBrandStatus(data);
    } catch (_) {
      // If the API is unreachable just leave both areas hidden — non-critical.
    }
  }

  function _renderBrandStatus(data) {
    const statusCard   = document.getElementById("brand-status-card");
    const activateForm = document.getElementById("brand-activate-form");

    if (data.branded && !data.needs_activation) {
      // Already activated — show status card, hide form
      statusCard.style.display   = "";
      activateForm.style.display = "none";

      document.getElementById("brand-status-name").textContent = data.product_name || "—";

      const badge = document.getElementById("brand-status-badge");
      if (data.warning) {
        // Distinguish between expired (red) and expiring-soon (yellow)
        const isExpired = data.warning && data.warning.toLowerCase().includes("expired");
        badge.textContent = isExpired ? I18n.t("settings.brand.badge.expired") : I18n.t("settings.brand.badge.warning");
        badge.className   = "brand-status-value " + (isExpired ? "badge-expired" : "badge-expiring");
      } else {
        badge.textContent  = I18n.t("settings.brand.badge.active");
        badge.className    = "brand-status-value badge-active";
      }

      // Fetch full brand info for expiry date and support QR code
      fetch("/api/brand").then(r => r.json()).then(info => {
        const expiresEl = document.getElementById("brand-status-expires");
        if (info.license_expires_at) {
          expiresEl.textContent = new Date(info.license_expires_at).toLocaleDateString();
        } else {
          expiresEl.textContent = "—";
        }

        // Show homepage link if available
        const homepageRow  = document.getElementById("brand-status-homepage-row");
        const homepageLink = document.getElementById("brand-status-homepage");
        if (info.homepage_url && homepageRow && homepageLink) {
          homepageLink.href        = info.homepage_url;
          homepageLink.textContent = info.homepage_url;
          homepageRow.style.display = "";
        } else if (homepageRow) {
          homepageRow.style.display = "none";
        }

        // Show support contact if available
        const contactWrap = document.getElementById("brand-support-contact");
        const contactLink = document.getElementById("brand-support-contact-link");
        if (info.support_contact && contactWrap && contactLink) {
          const contact = info.support_contact;
          contactLink.textContent = contact;
          // Auto-detect mailto / http link
          if (contact.startsWith("http://") || contact.startsWith("https://")) {
            contactLink.href = contact;
          } else if (contact.includes("@")) {
            contactLink.href = "mailto:" + contact;
          } else {
            contactLink.href = "#";
            contactLink.style.cursor = "default";
          }
          contactWrap.style.display = "";
        } else if (contactWrap) {
          contactWrap.style.display = "none";
        }

        // Show support QR code if available
        const qrContainer = document.getElementById("brand-support-qr");
        const qrImg       = document.getElementById("brand-support-qr-img");
        if (info.support_qr_url && qrContainer && qrImg) {
          qrImg.src                 = info.support_qr_url;
          qrContainer.style.display = "";
          _initQrLightbox(info.support_qr_url, info.support_qr_label || null);
        } else if (qrContainer) {
          qrContainer.style.display = "none";
        }
      }).catch(() => {
        document.getElementById("brand-status-expires").textContent = "—";
      });

    } else {
      // Not activated (or needs activation) — show form, hide status card
      statusCard.style.display   = "none";
      activateForm.style.display = "";

      // Pre-fill brand name in input placeholder if we know it
      if (data.product_name) {
        const desc = activateForm.querySelector(".brand-activate-desc");
        if (desc) desc.textContent =
          I18n.t("settings.brand.descNamed", { name: data.product_name });
      }

      // Show "Get a serial number" link only when the brand vendor has
      // published a homepage_url (read from /api/brand). No homepage → no link.
      if (typeof Brand.applyGetSerialLink === "function") Brand.applyGetSerialLink();
    }
  }

  /** Return a user-friendly error message for license activation failures. */
  function _friendlyActivateError(rawError) {
    if (!rawError) return I18n.t("settings.brand.activationFailed");
    const lower = rawError.toLowerCase();
    if (lower.includes("timeout") || lower.includes("network error") ||
        lower.includes("execution expired") || lower.includes("failed to open")) {
      return I18n.t("settings.brand.networkRetry");
    }
    return rawError;
  }

  async function _activateLicense() {
    const input  = document.getElementById("settings-license-key");
    const btn    = document.getElementById("btn-settings-activate");
    const result = document.getElementById("settings-activate-result");
    const key    = input.value.trim();

    if (!key) {
      _showBrandResult(false, I18n.t("settings.brand.enterKey"));
      return;
    }

    // In brand-test mode skip strict key format validation so developers can use any test key.
    if (!_brandTestMode && !/^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{8}){4}$/.test(key)) {
      _showBrandResult(false, I18n.t("settings.brand.invalidFormat"));
      return;
    }

    btn.disabled    = true;
    btn.textContent = I18n.t("settings.brand.btn.activating");
    _showBrandResult(null, "");

    try {
      const res  = await fetch("/api/brand/activate", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ license_key: key })
      });
      const data = await res.json();

      if (data.ok) {
        _showBrandResult(true, I18n.t("settings.brand.activated", { name: data.product_name || "configured" }));
        // Apply brand name and logo across the entire UI immediately
        if (data.product_name) Brand.applyBrandName(data.product_name);
        Brand.clearBrandCache();
        Brand.applyHeaderLogo();
        // Refresh brand status flags (user_licensed may have flipped from false
        // to true if this is a creator-tier license) and repaint dependent UI:
        //   - Creator sidebar entry (hidden for brand consumers, shown otherwise)
        //   - Header owner badge (shown only for creator licenses)
        // Without this refresh the user would need to reload the page to see
        // the Creator Hub appear in the sidebar after activation.
        Brand.refresh().then(() => {
          if (typeof Creator !== "undefined" && Creator.updateSidebarVisibility) {
            Creator.updateSidebarVisibility();
          }
          if (typeof Brand.applyOwnerBadge === "function") Brand.applyOwnerBadge();
        });
        // Remove the activation banner immediately after successful activation
        const banner = document.getElementById("brand-activation-banner");
        if (banner) banner.remove();
        // Reload brand status card after short delay
        setTimeout(_loadBrand, 800);
        // Auto-navigate to brand skills tab after a brief moment so user sees the success message first
        setTimeout(() => {
          Router.navigate("skills");
          if (typeof Skills !== "undefined") Skills.openBrandSkillsTab();
        }, 1500);
      } else {
        _showBrandResult(false, _friendlyActivateError(data.error));
      }
    } catch (e) {
      // Fetch itself threw (network down, timeout, etc.) — always show retry message
      _showBrandResult(false, I18n.t("settings.brand.networkRetry"));
    } finally {
      btn.disabled    = false;
      btn.textContent = I18n.t("settings.brand.btn.activate");
    }
  }

  function _showBrandResult(ok, message) {
    const el = document.getElementById("settings-activate-result");
    if (!el) return;
    if (ok === null) { el.textContent = ""; el.className = "model-test-result"; return; }
    el.textContent = message;
    el.className   = "model-test-result " + (ok ? "result-ok" : "result-fail");
  }

  // ── Init ──────────────────────────────────────────────────────────────────────

  function _initLangBtns() {
    // Highlight the active language button on open
    document.querySelectorAll(".settings-lang-btn").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.lang === I18n.lang());
      btn.addEventListener("click", () => {
        I18n.setLang(btn.dataset.lang);
        document.querySelectorAll(".settings-lang-btn").forEach(b =>
          b.classList.toggle("active", b.dataset.lang === I18n.lang())
        );
      });
    });
  }

  function init() {
    document.getElementById("btn-add-model").addEventListener("click", _addModel);
    document.getElementById("btn-rerun-onboard").addEventListener("click", _rerunOnboard);
    document.getElementById("btn-browser-setup").addEventListener("click", _setupBrowser);

    document.getElementById("btn-settings-activate").addEventListener("click", _activateLicense);
    document.getElementById("settings-license-key").addEventListener("keydown", e => {
      if (e.key === "Enter") _activateLicense();
    });

    // "Get a Serial Number" → opens the brand vendor's homepage in a new tab.
    // URL comes from /api/brand `homepage_url`, stashed on the button's dataset
    // by Brand.applyGetSerialLink(). If no homepage is configured the whole
    // row stays hidden, so this listener is effectively unreachable in that
    // case; the guard is purely defensive.
    document.getElementById("btn-get-serial")?.addEventListener("click", (e) => {
      const url = e.currentTarget.dataset.homepageUrl;
      if (url) window.open(url, "_blank", "noopener,noreferrer");
    });
    document.getElementById("btn-rebind-license").addEventListener("click", async () => {
      const confirmed = await Modal.confirm(I18n.t("settings.brand.confirmRebind"));
      if (!confirmed) return;
      // Show the form again so user can enter a new key
      document.getElementById("brand-status-card").style.display   = "none";
      document.getElementById("brand-activate-form").style.display = "";
      document.getElementById("settings-license-key").value = "";
      document.getElementById("settings-license-key").focus();
    });

    document.getElementById("btn-unbind-license").addEventListener("click", async () => {
      const confirmed = await Modal.confirm(I18n.t("settings.brand.confirmUnbind"));
      if (!confirmed) return;

      try {
        const res = await fetch("/api/brand/license", { method: "DELETE" });
        const data = await res.json();

        if (data.ok) {
          // Clear brand name and logo from header
          Brand.applyBrandName("OpenClacky");
          Brand.clearBrandCache();
          Brand.applyHeaderLogo();
          // Reset Skills panel state (hide Brand Skills tab, switch to My Skills)
          if (typeof Skills !== "undefined" && Skills.resetAfterUnbind) {
            Skills.resetAfterUnbind();
          }
          // Refresh brand flags so the sidebar creator entry and owner badge
          // reflect the now-unbound state without a page reload.
          Brand.refresh().then(() => {
            if (typeof Creator !== "undefined" && Creator.updateSidebarVisibility) {
              Creator.updateSidebarVisibility();
            }
            if (typeof Brand.applyOwnerBadge === "function") Brand.applyOwnerBadge();
          });
          // Hide status card, show activation form
          document.getElementById("brand-status-card").style.display   = "none";
          document.getElementById("brand-activate-form").style.display = "";
          document.getElementById("settings-license-key").value = "";
          _showBrandResult(true, I18n.t("settings.brand.unbindSuccess"));
          // Reload brand status after a brief delay
          setTimeout(_loadBrand, 800);
        } else {
          _showBrandResult(false, data.error || I18n.t("settings.brand.unbindFailed"));
        }
      } catch (e) {
        _showBrandResult(false, I18n.t("settings.brand.networkRetry"));
      }
    });

    _initLangBtns();

    // Re-render model cards when language changes (dynamic HTML, not data-i18n)
    document.addEventListener("langchange", () => _renderCards());
  }

  // ── QR Code Lightbox ───────────────────────────────────────────────────
  // Sets up click-to-enlarge behaviour for the support QR code.
  // Safe to call multiple times — idempotent via a data attribute guard.
  function _initQrLightbox(qrUrl, label) {
    const btn      = document.getElementById("brand-support-qr-btn");
    const lightbox = document.getElementById("qr-lightbox");
    const backdrop = document.getElementById("qr-lightbox-backdrop");
    const closeBtn = document.getElementById("qr-lightbox-close");
    const lbImg    = document.getElementById("qr-lightbox-img");
    const lbLabel  = document.getElementById("qr-lightbox-label");

    if (!btn || !lightbox) return;
    // Avoid double-binding
    if (btn.dataset.lightboxBound) return;
    btn.dataset.lightboxBound = "1";

    function openLightbox() {
      lbImg.src = qrUrl;
      if (lbLabel && label) lbLabel.textContent = label;
      lightbox.style.display = "";
      document.body.style.overflow = "hidden";
      closeBtn && closeBtn.focus();
    }

    function closeLightbox() {
      lightbox.style.display = "none";
      document.body.style.overflow = "";
      btn.focus();
    }

    btn.addEventListener("click", openLightbox);
    closeBtn  && closeBtn.addEventListener("click", closeLightbox);
    backdrop  && backdrop.addEventListener("click", closeLightbox);

    // Close on Escape key
    document.addEventListener("keydown", e => {
      if (e.key === "Escape" && lightbox.style.display !== "none") closeLightbox();
    });
  }

  return { open, init, loadBrand: _loadBrand };
})();
