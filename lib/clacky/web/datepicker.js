// datepicker.js — Lightweight custom calendar picker
//
// Usage:
//   Any <button data-value=""> with class "datepicker-trigger" gets a calendar
//   popup on click. When a date is selected the button's data-value is set to
//   an ISO string (YYYY-MM-DD) and a "datepicker:change" CustomEvent bubbles up.
//
//   DatePicker.clear(el)  — clear value and label
//   DatePicker.init(el)   — programmatically attach (optional; click delegation
//                           handles all .datepicker-trigger elements automatically)

const DatePicker = (() => {
  const LOCALE = {
    en: {
      days:    ["Su","Mo","Tu","We","Th","Fr","Sa"],
      months:  ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"],
      title:   (y, m, months) => `${months[m]} ${y}`,
      clear:   "Clear",
      today:   "Today",
      label:   (y, m, d) => `${y}/${String(m + 1).padStart(2,"0")}/${String(d).padStart(2,"0")}`,
    },
    zh: {
      days:    ["日","一","二","三","四","五","六"],
      months:  ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"],
      title:   (y, m, months) => `${y}年${months[m]}`,
      clear:   "清除",
      today:   "今天",
      label:   (y, m, d) => `${y}/${String(m + 1).padStart(2,"0")}/${String(d).padStart(2,"0")}`,
    },
  };

  function _loc() {
    const code = (typeof I18n !== "undefined") ? I18n.lang() : "en";
    return LOCALE[code] || LOCALE.en;
  }

  function _pad(n) { return String(n).padStart(2, "0"); }
  function _toISO(y, m, d) { return `${y}-${_pad(m + 1)}-${_pad(d)}`; }

  let _popup  = null;
  let _anchor = null;
  let _year   = 0;
  let _month  = 0;

  function _ensurePopup() {
    if (_popup) return;
    _popup = document.createElement("div");
    _popup.className = "dp-popup";
    _popup.hidden = true;
    document.body.appendChild(_popup);

    _popup.addEventListener("click", (e) => {
      const nav = e.target.closest(".dp-nav");
      if (nav) {
        e.stopPropagation();
        _month += parseInt(nav.dataset.dir);
        if (_month < 0)  { _month = 11; _year--; }
        if (_month > 11) { _month = 0;  _year++; }
        _render();
        return;
      }
      const day = e.target.closest("[data-date]");
      if (day) { _pick(day.dataset.date); return; }
      if (e.target.closest(".dp-btn-clear")) {
        clear(_anchor); _dispatch(); _close(); return;
      }
      if (e.target.closest(".dp-btn-today")) {
        const t = new Date();
        _pick(_toISO(t.getFullYear(), t.getMonth(), t.getDate()));
      }
    });
  }

  function _render() {
    const loc     = _loc();
    const selVal  = _anchor ? (_anchor.dataset.value || "") : "";
    const today   = new Date();
    const tY = today.getFullYear(), tM = today.getMonth(), tD = today.getDate();

    const firstWeekday = new Date(_year, _month, 1).getDay();
    const daysInMonth  = new Date(_year, _month + 1, 0).getDate();

    let html = `<div class="dp-header">
      <button class="dp-nav" data-dir="-12" type="button">&#8810;</button>
      <button class="dp-nav" data-dir="-1" type="button">&#8249;</button>
      <span class="dp-title">${loc.title(_year, _month, loc.months)}</span>
      <button class="dp-nav" data-dir="1" type="button">&#8250;</button>
      <button class="dp-nav" data-dir="12" type="button">&#8811;</button>
    </div>
    <div class="dp-grid">`;

    loc.days.forEach(d => { html += `<div class="dp-dow">${d}</div>`; });
    for (let i = 0; i < firstWeekday; i++) html += `<div></div>`;

    for (let d = 1; d <= daysInMonth; d++) {
      const iso = _toISO(_year, _month, d);
      const cls = ["dp-day",
        iso === selVal ? "dp-day--selected" : "",
        (_year === tY && _month === tM && d === tD) ? "dp-day--today" : "",
      ].filter(Boolean).join(" ");
      html += `<button class="${cls}" data-date="${iso}" type="button">${d}</button>`;
    }

    html += `</div>
    <div class="dp-footer">
      <button class="dp-btn-clear" type="button">${loc.clear}</button>
      <button class="dp-btn-today" type="button">${loc.today}</button>
    </div>`;

    _popup.innerHTML = html;
  }

  function _pick(iso) {
    if (!_anchor) return;
    const [y, m, d] = iso.split("-").map(Number);
    const loc = _loc();
    _anchor.dataset.value  = iso;
    _anchor.textContent    = loc.label(y, m - 1, d);
    _anchor.dataset.active = "true";
    _anchor.removeAttribute("data-i18n");
    _dispatch();
    _close();
  }

  function _dispatch() {
    if (!_anchor) return;
    _anchor.dispatchEvent(new CustomEvent("datepicker:change", { bubbles: true }));
  }

  function _position() {
    if (!_anchor || !_popup || _popup.hidden) return;
    const rect = _anchor.getBoundingClientRect();
    _popup.style.left   = rect.left + "px";
    const spaceBelow = window.innerHeight - rect.bottom;
    if (spaceBelow >= 290) {
      _popup.style.top    = (rect.bottom + 4) + "px";
      _popup.style.bottom = "auto";
    } else {
      _popup.style.top    = "auto";
      _popup.style.bottom = (window.innerHeight - rect.top + 4) + "px";
    }
  }

  function _open(anchorEl) {
    _ensurePopup();
    _anchor = anchorEl;
    const val = anchorEl.dataset.value;
    if (val) {
      const d = new Date(val + "T00:00:00");
      _year = d.getFullYear(); _month = d.getMonth();
    } else {
      const now = new Date();
      _year = now.getFullYear(); _month = now.getMonth();
    }
    _render();
    _popup.hidden = false;
    _position();
  }

  function _close() {
    if (_popup) _popup.hidden = true;
    _anchor = null;
  }

  // Click delegation — open on trigger, close on outside click
  document.addEventListener("click", (e) => {
    const trigger = e.target.closest(".datepicker-trigger");
    if (trigger) {
      e.stopPropagation();
      if (_anchor === trigger) { _close(); return; }
      _open(trigger);
      return;
    }
    if (_popup && !_popup.hidden && !e.target.closest(".dp-popup")) _close();
  });

  window.addEventListener("scroll", _position, true);
  window.addEventListener("resize", _position);

  // Re-render popup label when language changes
  document.addEventListener("langchange", () => {
    if (_popup && !_popup.hidden && _anchor) _render();
    _refreshTriggers();
  });

  function _refreshTriggers() {
    const loc = _loc();
    document.querySelectorAll(".datepicker-trigger[data-value]").forEach(el => {
      const val = el.dataset.value;
      if (!val) return;
      const [y, m, d] = val.split("-").map(Number);
      el.textContent = loc.label(y, m - 1, d);
    });
  }

  function clear(el) {
    if (!el) return;
    el.dataset.value  = "";
    el.dataset.active = "false";
    el.setAttribute("data-i18n", "sessions.search.datePlaceholder");
    if (typeof I18n !== "undefined") el.textContent = I18n.t("sessions.search.datePlaceholder");
  }

  return { clear };
})();
