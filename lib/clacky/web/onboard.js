// onboard.js — First-run setup flow
//
// Two distinct phases, now cleanly separated:
//
//   key_setup  → Show the full-screen setup-panel (language + API key).
//                Hard block: nothing works without an API key.
//                On success, automatically launches the /onboard session.
//
//   soul_setup → API key is already configured, SOUL.md is missing.
//                Automatically creates an /onboard session and boots the UI —
//                no blocking panel shown, user lands directly in the session.
//
// The old onboard-panel (with phase-lang / phase-key / phase-soul) is gone.
// setup-panel handles the mandatory first-run setup.
// /onboard skill handles the optional personalisation inside a chat session.

const Onboard = (() => {
  let _providers   = [];
  let _selectedLang = I18n.lang();  // language chosen during setup

  // ── Public API ──────────────────────────────────────────────────────────────

  async function check() {
    try {
      const res  = await fetch("/api/onboard/status");
      const data = await res.json();
      if (!data.needs_onboard) return { needsOnboard: false, phase: null };

      const phase = data.phase;

      if (phase === "key_setup") {
        // Mandatory: show full-screen setup panel, block boot.
        _showSetup();
        return { needsOnboard: true, phase };
      }

      if (phase === "soul_setup") {
        // Skip any blocking panel — just auto-launch the /onboard session.
        // If the user already has an onboard session in progress (hash has a
        // session id), restore it instead of creating a duplicate.
        if (window.location.hash.includes("session/")) {
          return { needsOnboard: false, phase: null };
        }
        await _launchOnboardSession();
        return { needsOnboard: true, phase };
      }

      return { needsOnboard: false, phase: null };
    } catch (_) {
      return { needsOnboard: false, phase: null };
    }
  }

  // ── Setup panel (key_setup) ─────────────────────────────────────────────────

  function _showSetup() {
    document.body.classList.add("setup-mode");
    Router.navigate("setup");
    Sessions.renderList();

    _selectedLang = I18n.lang();
    _bindLangStep();
  }

  // Step 1 — language selection
  function _bindLangStep() {
    const btnEn   = $("setup-btn-lang-en");
    const btnZh   = $("setup-btn-lang-zh");
    const btnNext = $("setup-btn-lang-next");

    _updateLangBtns(_selectedLang);

    btnEn.addEventListener("click", () => {
      _selectedLang = "en";
      I18n.setLang("en");
      _updateLangBtns("en");
    });

    btnZh.addEventListener("click", () => {
      _selectedLang = "zh";
      I18n.setLang("zh");
      _updateLangBtns("zh");
    });

    btnNext.addEventListener("click", async () => {
      _showSetupStep("key");
      await _loadProviders();
      _bindKeyStep();
    });
  }

  function _updateLangBtns(lang) {
    const btnEn   = $("setup-btn-lang-en");
    const btnZh   = $("setup-btn-lang-zh");
    const btnNext = $("setup-btn-lang-next");
    if (!btnEn || !btnZh) return;
    btnEn.classList.toggle("active", lang === "en");
    btnZh.classList.toggle("active", lang === "zh");
    if (btnNext) btnNext.textContent = lang === "zh" ? "继续 →" : "Continue →";
  }

  function _showSetupStep(step) {
    $("setup-phase-lang").style.display = step === "lang" ? "" : "none";
    $("setup-phase-key").style.display  = step === "key"  ? "" : "none";
    $("setup-dot-1").className = "setup-step" + (step === "lang" ? " active" : " done");
    $("setup-dot-2").className = "setup-step" + (step === "key"  ? " active" : "");
  }

  // Step 2 — API key setup
  // Guard: providers are loaded only once; dropdown is bound only once.
  let _providersLoaded = false;
  let _dropdownBound   = false;

  async function _loadProviders() {
    // Fetch providers only once; on Back→Next, re-render from cache.
    if (!_providersLoaded) {
      try {
        const res  = await fetch("/api/providers");
        const data = await res.json();
        _providers = data.providers || [];
        _providersLoaded = true;
      } catch (_) { /* ignore */ }
    }

    // Always re-render options (dropdown is cleared on each visit to Step 2)
    _renderProviderOptions();
    // Bind event listeners only once (delegation-based, safe to skip on re-entry)
    _bindCustomDropdown();
  }

  function _renderProviderOptions() {
    const dropdown = $("setup-provider-dropdown");
    // Clear any previously rendered options before re-rendering
    dropdown.innerHTML = "";

    _providers.forEach(p => {
      const opt = document.createElement("div");
      opt.className     = "custom-select-option";
      opt.dataset.value = p.id;
      opt.textContent   = p.name;
      dropdown.appendChild(opt);
    });

    // Always append "Custom" as the last option
    const custom = document.createElement("div");
    custom.className     = "custom-select-option";
    custom.dataset.value = "__custom__";
    custom.dataset.i18n  = "onboard.provider.custom";
    custom.textContent   = I18n.t("onboard.provider.custom");
    dropdown.appendChild(custom);
  }

  function _bindCustomDropdown() {
    if (_dropdownBound) return; // listeners already attached
    _dropdownBound = true;

    const wrapper   = $("setup-provider-wrapper");
    const trigger   = wrapper.querySelector(".custom-select-trigger");
    const dropdown  = wrapper.querySelector(".custom-select-dropdown");
    const valueSpan = trigger.querySelector(".custom-select-value");

    trigger.addEventListener("click", e => {
      e.stopPropagation();
      const open = dropdown.classList.toggle("open");
      trigger.classList.toggle("open", open);
    });

    // Use event delegation on the dropdown container — works for any option
    // including dynamically added ones (no need to re-bind on Back/Next).
    dropdown.addEventListener("click", e => {
      e.stopPropagation();
      const opt = e.target.closest(".custom-select-option");
      if (!opt) return;

      const value = opt.dataset.value;
      valueSpan.textContent = opt.textContent;
      valueSpan.classList.toggle("placeholder", !value);
      dropdown.querySelectorAll(".custom-select-option").forEach(o => o.classList.remove("selected"));
      opt.classList.add("selected");
      dropdown.classList.remove("open");
      trigger.classList.remove("open");

      const getApiKeyLink = $("setup-get-apikey-link");
      if (value === "__custom__") {
        // Custom: clear presets so the user can fill in their own values
        $("setup-model").value    = "";
        $("setup-base-url").value = "";
        if (getApiKeyLink) getApiKeyLink.style.display = "none";
      } else if (value) {
        const preset = _providers.find(p => p.id === value);
        if (preset) {
          $("setup-model").value    = preset.default_model || "";
          $("setup-base-url").value = preset.base_url      || "";
          // Show "how to get" link if provider has a website_url
          if (getApiKeyLink && preset.website_url) {
            getApiKeyLink.href         = preset.website_url;
            getApiKeyLink.style.display = "";
          } else if (getApiKeyLink) {
            getApiKeyLink.style.display = "none";
          }
        }
      } else if (getApiKeyLink) {
        getApiKeyLink.style.display = "none";
      }
    });

    // Single global click-outside listener
    document.addEventListener("click", () => {
      dropdown.classList.remove("open");
      trigger.classList.remove("open");
    });
  }

  // Guard: key-step listeners are attached only once
  let _keyStepBound = false;

  function _bindKeyStep() {
    if (_keyStepBound) return;
    _keyStepBound = true;

    // Toggle key visibility
    const toggleBtn  = $("setup-toggle-key");
    const keyInput   = $("setup-api-key");
    const eyeIcon    = toggleBtn.querySelector("svg");

    toggleBtn.addEventListener("click", () => {
      const isPassword = keyInput.type === "password";
      keyInput.type = isPassword ? "text" : "password";
      eyeIcon.innerHTML = isPassword
        ? `<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"></path>`
        : `<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"></path>`;
    });

    $("setup-btn-test").addEventListener("click", _testAndSave);

    // Back to Step 1
    $("setup-btn-back").addEventListener("click", () => {
      _showSetupStep("lang");
    });
  }

  async function _testAndSave() {
    const btn     = $("setup-btn-test");
    const model   = $("setup-model").value.trim();
    const baseUrl = $("setup-base-url").value.trim();
    const apiKey  = $("setup-api-key").value.trim();
    const zh      = _selectedLang === "zh";

    if (!model || !baseUrl || !apiKey) {
      _setResult(false, zh ? "请填写模型、Base URL 和 API Key。" : "Please fill in Model, Base URL and API Key.");
      return;
    }

    btn.disabled    = true;
    btn.textContent = I18n.t("onboard.key.testing");
    _setResult(null, "");

    // Step 1: test connection
    try {
      const res  = await fetch("/api/config/test", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ model, base_url: baseUrl, api_key: apiKey, index: 0 })
      });
      const data = await res.json();
      if (!data.ok) {
        _setResult(false, data.message || (zh ? "连接失败。" : "Connection failed."));
        btn.disabled    = false;
        btn.textContent = I18n.t("onboard.key.btn.test");
        return;
      }
    } catch (e) {
      _setResult(false, e.message);
      btn.disabled    = false;
      btn.textContent = I18n.t("onboard.key.btn.test");
      return;
    }

    // Step 2: save config
    btn.textContent = I18n.t("onboard.key.saving");
    try {
      const res  = await fetch("/api/config/models", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ type: "default", model, base_url: baseUrl, api_key: apiKey, anthropic_format: false })
      });
      const data = await res.json();
      if (!data.ok) {
        _setResult(false, data.error || (zh ? "保存失败。" : "Save failed."));
        btn.disabled    = false;
        btn.textContent = I18n.t("onboard.key.btn.test");
        return;
      }
    } catch (e) {
      _setResult(false, e.message);
      btn.disabled    = false;
      btn.textContent = I18n.t("onboard.key.btn.test");
      return;
    }

    // Success — show brief feedback then auto-launch /onboard session
    _setResult(true, zh ? "连接成功！" : "Connected!");
    setTimeout(() => _launchOnboardSession(), 600);
  }

  function _setResult(ok, msg) {
    const el = $("setup-test-result");
    if (!el) return;
    if (ok === null) { el.textContent = ""; el.className = "setup-test-result"; return; }
    el.textContent = ok ? "✓ " + msg : "✗ " + msg;
    el.className   = "setup-test-result " + (ok ? "result-ok" : "result-fail");
  }

  // ── /onboard session launcher ───────────────────────────────────────────────

  // Create a dedicated session and send the /onboard slash command.
  // Called after key_setup succeeds AND on soul_setup phase (auto, no panel shown).
  async function _launchOnboardSession() {
    try {
      await _complete();
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: "✨ Onboard", source: "setup" })
      });
      const data    = await res.json();
      const session = data.session;
      if (!session) throw new Error("No session returned");

      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, `/onboard lang:${_selectedLang}`);
      Sessions.select(session.id);

      _bootUI();
    } catch (_) {
      // Fallback: just boot normally if session creation fails
      _bootUI();
    }
  }

  // POST /api/onboard/complete — persists config, creates default session if missing.
  async function _complete() {
    try {
      const res = await fetch("/api/onboard/complete", { method: "POST" });
      return await res.json();
    } catch (_) { return null; }
  }

  // Boot the normal UI (WS + sessions sidebar + tasks + skills).
  function _bootUI() {
    document.body.classList.remove("setup-mode");
    WS.connect();
    Tasks.load();
    Skills.load();
  }

  return { check, startSoulSession: _launchOnboardSession };
})();
