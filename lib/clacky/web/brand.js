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
    if (window.ClackyUiPolicy?.isHosted()) {
      _testMode = false;
      _userLicensed = false;
      _branded = false;
      return false;
    }

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

        // Apply logo/theme from whatever is already cached in brand.yml —
        // install.sh only writes product_name + package_name, but if a
        // previous session already pulled the public distribution info,
        // we can light up the full brand visuals right now.
        _applyHeaderLogo();

        // Backend just kicked off an async refresh of the public distribution
        // (logo, theme_color, homepage_url, support_*). brand.yml will be
        // written once the network round-trip completes — re-poll a few
        // seconds later so the user sees the full brand visuals in *this*
        // session instead of having to activate or reload the page first.
        if (data.distribution_refresh_pending) {
          _scheduleDistributionRefreshPoll();
        }

        return false;
      }

      if (data.warning) _showWarning(data.warning);

      // Load full brand info to apply logo in header
      _applyHeaderLogo();
      // Show OWNER badge for creator-tier licenses (user_licensed=true).
      _applyOwnerBadge();

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
      } else {
        // No brand theme — remove any previously applied overrides to restore defaults
        const root = document.documentElement;
        root.style.removeProperty("--color-accent-primary");
        root.style.removeProperty("--color-accent-hover");
        root.style.removeProperty("--color-button-primary");
        root.style.removeProperty("--color-button-primary-hover");
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
      } else {
        // No logo configured — hide logo image and remove has-logo class
        if (logoImg) {
          logoImg.style.display = "none";
          logoImg.src           = "";
        }
        if (brandWrap) brandWrap.classList.remove("has-logo");
      }

      // Always show brand name text; hide it only when no brand name is set
      if (logoText) {
        const name = info.product_name || "";
        if (name) {
          logoText.textContent    = name;
          logoText.style.display  = "";
        } else {
          // No brand configured — show the default "OpenClacky" name
          logoText.textContent   = "OpenClacky";
          logoText.style.display = "";
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

  // Poll /api/brand a few times to pick up freshly-refreshed distribution
  // assets (logo_url / theme_color / homepage_url). Used on first boot of a
  // branded-but-unactivated install, where /api/brand/status just kicked off
  // an async distribution fetch — brand.yml will be written once the round-
  // trip completes, and we want to apply the result in the current session.
  //
  // Delay schedule: 3s, 8s, 15s from now. Stops early once logo_url and
  // theme_color are both present (assumed "fully refreshed").
  // Safe to call multiple times: a second call is ignored while a poll chain
  // is already in flight.
  let _distRefreshPolling = false;
  function _scheduleDistributionRefreshPoll() {
    if (_distRefreshPolling) return;
    _distRefreshPolling = true;

    const delays = [3000, 5000, 7000]; // cumulative: 3s, 8s, 15s
    let attempt  = 0;

    const poll = () => {
      _clearBrandCache();
      _fetchBrandInfo().then(info => {
        const hasFullBrand = !!(info && info.logo_url && info.theme_color);
        _applyHeaderLogo();
        // Stop when we've got the full brand visuals, or we've exhausted retries.
        if (hasFullBrand || attempt >= delays.length) {
          _distRefreshPolling = false;
          return;
        }
        setTimeout(poll, delays[attempt++]);
      }).catch(() => {
        if (attempt >= delays.length) { _distRefreshPolling = false; return; }
        setTimeout(poll, delays[attempt++]);
      });
    };

    setTimeout(poll, delays[attempt++]);
  }

  // Show or hide the OWNER badge next to the header logo, based on whether
  // the current license is bound to a user (creator tier). Idempotent — safe
  // to call multiple times. Should be invoked after any state change that
  // affects userLicensed: initial check(), post-activation refresh(),
  // post-unbind, etc.
  function _applyOwnerBadge() {
    const badge = document.getElementById("header-owner-badge");
    if (!badge) return;
    const showCreator = window.ClackyUiPolicy?.viewEnabled("creator") !== false;
    badge.style.display = (_userLicensed && showCreator) ? "" : "none";
  }

  // Show or hide the "Get a Serial Number" helper row in the activation form,
  // driven by whether the brand vendor has published a homepage_url.
  // URL source: /api/brand → homepage_url field (set by the brand partner
  // via BrandConfig/distribution, never hardcoded in the client).
  // Rules:
  //   - homepage_url present        → row visible, button opens the URL
  //   - homepage_url missing/empty  → row hidden (no dead link for
  //                                    unbranded or brand-without-homepage setups)
  function _applyGetSerialLink() {
    const row = document.getElementById("brand-get-serial");
    const btn = document.getElementById("btn-get-serial");
    if (!row || !btn) return;
    _fetchBrandInfo().then(info => {
      const url = info && typeof info.homepage_url === "string" ? info.homepage_url.trim() : "";
      if (url) {
        row.style.display = "";
        btn.dataset.homepageUrl = url;
      } else {
        row.style.display = "none";
        delete btn.dataset.homepageUrl;
      }
    }).catch(() => {
      row.style.display = "none";
    });
  }

  // Refresh internal brand state by re-fetching /api/brand/status.
  // Unlike check() — which also drives the boot UI — refresh() only updates
  // the cached flags (_branded / _userLicensed / _testMode) so code that
  // reads them (e.g. Creator.updateSidebarVisibility) sees fresh values
  // after a license activation without a full page reload.
  async function refresh() {
    try {
      const res  = await fetch("/api/brand/status");
      const data = await res.json();
      _testMode     = !!data.test_mode;
      _userLicensed = !!data.user_licensed;
      _branded      = !!data.branded;
      return data;
    } catch (_) {
      return null;
    }
  }

  return { check, refresh, applyBrandName: _applyBrandName, applyHeaderLogo: _applyHeaderLogo, applyOwnerBadge: _applyOwnerBadge, applyGetSerialLink: _applyGetSerialLink, clearBrandCache: _clearBrandCache, goToLicenseInput: _goToLicenseInput, get userLicensed() { return _userLicensed; }, get branded() { return _branded; } };
})();
