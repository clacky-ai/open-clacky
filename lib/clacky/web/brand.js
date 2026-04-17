// brand.js — White-label branding support
//
// Responsibilities:
//   1. On boot, fetch GET /api/brand/status
//      - If needs_activation → show brand activation panel (like onboard)
//      - If branded + warning → show a dismissible warning bar
//      - If not branded → no-op (standard OpenClacky experience)
//   2. Fetch GET /api/brand and apply product_name to all branded DOM elements
//
// Load order: must be loaded after onboard.js and before app.js

const Brand = (() => {

  // ── Public API ─────────────────────────────────────────────────────────────

  // Whether the server was started with --brand-test (set during check()).
  let _testMode     = false;
  // Whether the current license is bound to a user (creator mode).
  let _userLicensed = false;
  // Whether this installation has an activated brand license (any kind).
  let _branded      = false;

  // Check brand status. Returns true if activation is needed
  // (caller should defer normal UI boot until activation is done or skipped).
  async function check() {
    try {
      const res  = await fetch("/api/brand/status");
      const data = await res.json();

      _testMode     = !!data.test_mode;
      _userLicensed = !!data.user_licensed;
      _branded      = !!data.branded;

      if (!data.branded) return false;

      // Brand name is already baked into the HTML by the server at request time,
      // so no DOM update is needed here on boot.

      if (data.needs_activation) {
        // Show a top banner instead of a blocking full-screen panel.
        // Boot continues normally; user can activate at any time via the banner.
        _showActivationBanner(data.product_name);
        return false;
      }

      if (data.warning) _showWarning(data.warning);

      // Load full brand info to apply logo in header
      _applyHeaderLogo();

      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  // Show a dismissible activation banner at the top of the page.
  // Clicking the banner creates a dedicated session and invokes the
  // Clicking the banner opens Settings and focuses the license key input directly.
  function _showActivationBanner(brandName) {
    const existing = document.getElementById("brand-activation-banner");
    if (existing) return;

    const bar = document.createElement("div");
    bar.id        = "brand-activation-banner";
    bar.className = "brand-activation-banner";

    const span = document.createElement("span");
    const name = brandName || I18n.t("brand.banner.defaultName");
    span.textContent = I18n.t("brand.banner.prompt", { name });
    span.setAttribute("data-i18n", "brand.banner.prompt");
    if (brandName) span.setAttribute("data-i18n-vars", `name=${brandName}`);

    const link = document.createElement("button");
    link.className   = "brand-activation-banner-link";
    link.textContent = I18n.t("brand.banner.action");
    link.setAttribute("data-i18n", "brand.banner.action");
    link.addEventListener("click", () => _goToLicenseInput());

    const closeBtn = document.createElement("button");
    closeBtn.className = "brand-activation-banner-close";
    closeBtn.innerHTML = "&#x2715;";
    closeBtn.onclick   = () => bar.remove();

    bar.appendChild(span);
    bar.appendChild(link);
    bar.appendChild(closeBtn);
    document.getElementById("main").prepend(bar);
  }

  // Navigate to Settings, scroll to Brand & License section, flash it, then focus the input.
  function _goToLicenseInput() {
    Router.navigate("settings");
    // Settings.open() loads brand status; wait a tick for the panel to render.
    if (typeof Settings !== "undefined") Settings.open();
    // Settings.open() triggers an async fetch; wait for layout to stabilise before scrolling.
    setTimeout(() => {
      const section         = document.getElementById("brand-license-section");
      const input           = document.getElementById("settings-license-key");
      const scrollContainer = document.getElementById("settings-body");

      if (section && scrollContainer) {
        const containerTop = scrollContainer.getBoundingClientRect().top;
        const sectionTop   = section.getBoundingClientRect().top;
        const offset       = sectionTop - containerTop + scrollContainer.scrollTop - 24;
        scrollContainer.scrollTo({ top: offset, behavior: "smooth" });
      }

      if (section) {
        // Flash the section to draw the user's eye (re-trigger if clicked again).
        section.classList.remove("section-highlight");
        void section.offsetWidth; // force reflow to restart animation
        section.classList.add("section-highlight");
        section.addEventListener("animationend", () => section.classList.remove("section-highlight"), { once: true });
      }

      if (input) input.focus();
    }, 300);
  }

  function _showActivationPanel(brandName) {
    if (brandName) {
      const title = $("brand-title");
      const sub   = $("brand-subtitle");
      if (title) title.textContent = I18n.t("brand.activate.title", { name: brandName });
      if (sub)   sub.textContent   = I18n.t("brand.activate.subtitle");
    }
    Router.navigate("brand");
    _bindActivationPanel();
  }

  function _bindActivationPanel() {
    $("brand-btn-activate").addEventListener("click", _doActivate);
    $("brand-license-key").addEventListener("keydown", e => {
      if (e.key === "Enter") _doActivate();
    });
    $("brand-btn-skip").addEventListener("click", _skipActivation);
  }

  async function _doActivate() {
    const btn = $("brand-btn-activate");
    const key = $("brand-license-key").value.trim();

    if (!key) {
      _setResult(false, I18n.t("settings.brand.enterKey"));
      return;
    }

    // In brand-test mode accept any non-empty key so developers can test without a real license.
    if (!_testMode && !/^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{8}){4}$/.test(key)) {
      _setResult(false, I18n.t("settings.brand.invalidFormat"));
      return;
    }

    btn.disabled    = true;
    btn.textContent = I18n.t("settings.brand.btn.activating");
    _setResult(null, "");

    try {
      const res  = await fetch("/api/brand/activate", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ license_key: key })
      });
      const data = await res.json();

      if (data.ok) {
        _setResult(true, I18n.t("brand.activate.success"));
        if (data.product_name) _applyBrandName(data.product_name);
        _clearBrandCache();
        _applyHeaderLogo();
        setTimeout(_bootUI, 800);
      } else {
        _setResult(false, data.error || I18n.t("settings.brand.activationFailed"));
        btn.disabled    = false;
        btn.textContent = I18n.t("settings.brand.btn.activate");
      }
    } catch (e) {
      _setResult(false, I18n.t("settings.brand.networkError") + e.message);
      btn.disabled    = false;
      btn.textContent = I18n.t("settings.brand.btn.activate");
    }
  }

  function _skipActivation() {
    // Show a dismissible warning so the user knows brand features are unavailable.
    // Pass the i18n key so the bar text updates when the user switches language.
    _showWarning(I18n.t("brand.skip.warning"), "brand.skip.warning");
    _bootUI();
  }

  function _setResult(ok, msg) {
    const el = $("brand-activate-result");
    if (!el) return;
    if (ok === null) { el.textContent = ""; el.className = "onboard-test-result"; return; }
    el.textContent = ok ? msg : msg;
    el.className   = "onboard-test-result " + (ok ? "result-ok" : "result-fail");
  }

  // Replace all branded text nodes in the DOM.
  function _applyBrandName(name) {
    const nodes = {
      "page-title":    name,
      "sidebar-logo":  name,
      "onboard-title": I18n.t("onboard.welcome", { name }),
      "welcome-title": I18n.t("onboard.welcome", { name })
    };
    Object.entries(nodes).forEach(([id, text]) => {
      const el = $(id);
      if (el) el.textContent = text;
    });
  }

  // Cache for brand info to avoid redundant fetches and duplicate image loads.
  let _brandInfoCache = null;
  let _brandInfoFetching = null;

  // Fetch /api/brand once and cache the result. Returns a Promise<info>.
  function _fetchBrandInfo() {
    if (_brandInfoCache) return Promise.resolve(_brandInfoCache);
    if (_brandInfoFetching) return _brandInfoFetching;
    _brandInfoFetching = fetch("/api/brand")
      .then(r => r.json())
      .then(info => { _brandInfoCache = info; _brandInfoFetching = null; return info; })
      .catch(err => { _brandInfoFetching = null; throw err; });
    return _brandInfoFetching;
  }

  // Fetch /api/brand and apply logo_url + product_name to the header if available.
  function _applyHeaderLogo() {
    _fetchBrandInfo().then(info => {
      const logoImg   = document.getElementById("header-logo-img");
      const logoText  = document.getElementById("header-logo");
      const brandWrap = document.getElementById("header-brand");

      // Apply theme color — overrides --color-accent-primary and --color-button-primary
      if (info.theme_color) {
        const root = document.documentElement;
        root.style.setProperty("--color-accent-primary",      info.theme_color);
        root.style.setProperty("--color-accent-hover",        info.theme_color);
        root.style.setProperty("--color-button-primary",      info.theme_color);
        root.style.setProperty("--color-button-primary-hover", info.theme_color);
        // Also update browser tab color on mobile
        const metaTheme = document.querySelector("meta[name='theme-color']");
        if (metaTheme) metaTheme.setAttribute("content", info.theme_color);
      }

      // header-brand already has onclick="Router.navigate('chat')" in HTML, no extra link needed

      const hasLogo = !!(info.logo_url && logoImg);

      if (hasLogo) {
        if (logoImg.src && logoImg.src === info.logo_url) {
          // Already showing the correct logo — only ensure favicon is in sync
          _applyFavicon(info.logo_url);
        } else {
          // Pre-load the image; only show it once loaded to avoid layout flicker
          const img = new Image();
          img.onload = () => {
            logoImg.src           = info.logo_url;
            logoImg.alt           = info.product_name || "";
            logoImg.style.display = "";
            if (brandWrap) brandWrap.classList.add("has-logo");
            // Update browser tab favicon to match the brand logo
            _applyFavicon(info.logo_url);
          };
          img.onerror = () => {
            // Logo failed to load — keep text-only mode
          };
          img.src = info.logo_url;
        }
      }

      // Always show brand name text; hide it only when no brand name is set
      if (logoText) {
        const name = info.product_name || "";
        if (name) {
          logoText.textContent    = name;
          logoText.style.display  = "";
        } else {
          // No brand name at all — hide the text span
          logoText.style.display = "none";
        }
      }
    }).catch(() => {
      // Silently ignore — logo is non-critical
    });
  }

  // Replace the browser tab favicon with the given URL.
  // Works for both image URLs and SVG data URIs.
  function _applyFavicon(url) {
    let link = document.querySelector("link[rel='icon']");
    if (!link) {
      link = document.createElement("link");
      link.rel = "icon";
      document.head.appendChild(link);
    }
    const lower = url.split("?")[0].toLowerCase();
    if (lower.endsWith(".svg"))       link.type = "image/svg+xml";
    else if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) link.type = "image/jpeg";
    else if (lower.endsWith(".ico")) link.type = "image/x-icon";
    else                              link.type = "image/png";
    link.href = url;
  }

  // Show a dismissible warning bar above the main content.
  // The i18n key is stored on the span so I18n.applyAll() can re-translate
  // it when the user switches language without dismissing the bar.
  function _showWarning(message, i18nKey) {
    const existing = document.getElementById("brand-warning-bar");
    if (existing) return;

    const bar = document.createElement("div");
    bar.id        = "brand-warning-bar";
    bar.className = "brand-warning-bar";

    const span = document.createElement("span");
    span.textContent = message;
    if (i18nKey) span.setAttribute("data-i18n", i18nKey);

    const btn = document.createElement("button");
    btn.innerHTML = "&#x2715;";
    btn.onclick = () => bar.remove();

    bar.appendChild(span);
    bar.appendChild(btn);
    document.getElementById("main").prepend(bar);
  }

  // Continue the boot sequence after brand check is resolved (activated or skipped).
  // Delegates to window.bootAfterBrand() defined in app.js so the onboard check
  // runs before WS.connect() — ensures key_setup is shown when no API key exists.
  function _bootUI() {
    if (typeof window.bootAfterBrand === "function") {
      window.bootAfterBrand();
    } else {
      // Fallback: app.js not yet loaded, boot directly
      WS.connect();
      Tasks.load();
      Skills.load();
    }
  }

  // Bust the cached /api/brand response so the next applyHeaderLogo() call
  // fetches fresh data from the server (needed after license key switch).
  function _clearBrandCache() {
    _brandInfoCache    = null;
    _brandInfoFetching = null;
  }

  return { check, applyBrandName: _applyBrandName, applyHeaderLogo: _applyHeaderLogo, clearBrandCache: _clearBrandCache, goToLicenseInput: _goToLicenseInput, get userLicensed() { return _userLicensed; }, get branded() { return _branded; } };
})();
