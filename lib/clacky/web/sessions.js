// ── Sessions — session state, rendering, message cache ────────────────────
//
// Responsibilities:
//   - Maintain the canonical sessions list
//   - session_list (WS) is used ONLY on initial connect to populate the list
//   - After that, the list is maintained locally:
//       add: from POST /api/sessions response
//       update: from session_update WS event
//       remove: from session_deleted WS event
//   - Render the session sidebar list
//   - Manage per-session message DOM cache (fast panel switch)
//   - Select / deselect sessions; show/hide the chat panel
//
// Depends on: WS (ws.js), global $ helper, global escapeHtml helper
// ─────────────────────────────────────────────────────────────────────────

const Sessions = (() => {
  const _sessions     = [];  // [{ id, name, status, total_tasks, total_cost }]
  const _messageCache = {};  // { [session_id]: DocumentFragment }
  let   _activeId     = null;

  // ── Private helpers ────────────────────────────────────────────────────

  function _cacheActiveMessages() {
    if (!_activeId) return;
    const messages = $("messages");
    const frag = document.createDocumentFragment();
    while (messages.firstChild) frag.appendChild(messages.firstChild);
    _messageCache[_activeId] = frag;
  }

  function _restoreMessages(id) {
    const messages = $("messages");
    messages.innerHTML = "";
    if (_messageCache[id]) {
      messages.appendChild(_messageCache[id]);
      delete _messageCache[id];
      messages.scrollTop = messages.scrollHeight;
    }
  }

  function _showChatPanel() {
    $("welcome").style.display           = "none";
    $("task-detail-panel").style.display = "none";
    $("chat-panel").style.display        = "flex";
    $("chat-panel").style.flexDirection  = "column";
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {
    get all()      { return _sessions; },
    get activeId() { return _activeId; },
    find: id => _sessions.find(s => s.id === id),

    // ── List management (called from app.js WS handlers) ─────────────────

    /** Populate list from initial session_list WS event (connect only). */
    setAll(list) {
      _sessions.length = 0;
      _sessions.push(...list);
    },

    /** Insert a newly created session into the local list. */
    add(session) {
      if (!_sessions.find(s => s.id === session.id)) {
        _sessions.push(session);
      }
    },

    /** Patch a single session's fields (from session_update event). */
    patch(id, fields) {
      const s = _sessions.find(s => s.id === id);
      if (s) Object.assign(s, fields);
    },

    /** Remove a session from the list (from session_deleted event). */
    remove(id) {
      const idx = _sessions.findIndex(s => s.id === id);
      if (idx !== -1) _sessions.splice(idx, 1);
    },

    // ── Selection ─────────────────────────────────────────────────────────

    select(id) {
      const s = _sessions.find(s => s.id === id);
      if (!s) return;

      const isSwitch = _activeId !== id;
      _cacheActiveMessages();
      _activeId = id;

      _showChatPanel();
      $("chat-title").textContent = s.name;
      Sessions.updateStatusBar(s.status);
      _restoreMessages(id);

      if (isSwitch) {
        WS.setSubscribedSession(id);
        WS.send({ type: "subscribe", session_id: id });
      }

      Sessions.renderList();
      $("user-input").focus();
    },

    deselect() {
      _cacheActiveMessages();
      _activeId = null;
      WS.setSubscribedSession(null);
      $("welcome").style.display           = "";
      $("chat-panel").style.display        = "none";
      $("task-detail-panel").style.display = "none";
      Sessions.renderList();
    },

    /** Cache messages + clear activeId without touching panel visibility.
     *  Used by Tasks when showing the task panel. */
    _cacheActiveAndDeselect() {
      _cacheActiveMessages();
      _activeId = null;
      WS.setSubscribedSession(null);
      Sessions.renderList();
    },

    // ── Rendering ─────────────────────────────────────────────────────────

    renderList() {
      const list = $("session-list");
      list.innerHTML = "";
      _sessions.forEach(s => {
        const el = document.createElement("div");
        el.className = "session-item" + (s.id === _activeId ? " active" : "");
        el.innerHTML = `
          <div class="session-name">
            <span class="session-dot dot-${s.status || "idle"}"></span>${escapeHtml(s.name)}
          </div>
          <div class="session-meta">${s.total_tasks || 0} tasks · $${(s.total_cost || 0).toFixed(4)}</div>`;
        el.onclick = () => Sessions.select(s.id);
        list.appendChild(el);
      });
    },

    updateStatusBar(status) {
      $("chat-status").textContent = status || "idle";
      $("chat-status").className   = status === "running" ? "status-running" : "status-idle";
      const running = status === "running";
      $("btn-send").disabled           = running;
      $("btn-interrupt").style.display = running ? "" : "none";
    },

    // ── Message helpers ────────────────────────────────────────────────────

    appendMsg(type, html) {
      const messages = $("messages");
      const el = document.createElement("div");
      el.className = `msg msg-${type}`;
      el.innerHTML = html;
      messages.appendChild(el);
      messages.scrollTop = messages.scrollHeight;
    },

    appendInfo(text) {
      const messages = $("messages");
      const el = document.createElement("div");
      el.className   = "msg msg-info";
      el.textContent = text;
      messages.appendChild(el);
      messages.scrollTop = messages.scrollHeight;
    },

    showProgress(text) {
      Sessions.clearProgress();
      const messages = $("messages");
      const el = document.createElement("div");
      el.className   = "progress-msg";
      el.textContent = "⟳ " + text;
      messages.appendChild(el);
      Sessions._progressEl = el;
      messages.scrollTop = messages.scrollHeight;
    },

    clearProgress() {
      if (Sessions._progressEl) {
        Sessions._progressEl.remove();
        Sessions._progressEl = null;
      }
    },

    _progressEl: null,

    // ── Create ─────────────────────────────────────────────────────────────

    /** Create a new session.
     *  The server response contains the full session object — we add it to
     *  the local list immediately and select it. No need to wait for WS. */
    async create() {
      const maxN = _sessions.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const name = "Session " + (maxN + 1);

      const res  = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error: " + (data.error || "unknown")); return; }

      const session = data.session;
      if (!session) return;

      // Add locally and select immediately — no WS round-trip needed
      Sessions.add(session);
      Sessions.renderList();
      Sessions.select(session.id);
    },
  };
})();
