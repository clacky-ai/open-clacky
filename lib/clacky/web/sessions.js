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
//   - Select / deselect sessions — panel switching is delegated to Router
//   - Load message history via GET /api/sessions/:id/messages (cursor pagination)
//
// Depends on: WS (ws.js), Router (app.js), global $ / escapeHtml helpers
// ─────────────────────────────────────────────────────────────────────────

const Sessions = (() => {
  const _sessions          = [];  // [{ id, name, status, total_tasks, total_cost }]
  const _historyState      = {};  // { [session_id]: { hasMore, oldestCreatedAt, loading, loaded } }
  const _renderedCreatedAt = {};  // { [session_id]: Set<number> } — dedup by created_at
  let   _activeId          = null;
  let   _activeTab         = "manual";  // "manual" | "cron" | "channel" | "setup"
  // Per-source pagination state (manual/cron/channel/setup for general tabs; coding for coding section)
  const _hasMoreBySource   = { manual: false, cron: false, channel: false, setup: false, coding: false };
  const _loadingMoreSource = { manual: false, cron: false, channel: false, setup: false, coding: false };
  let   _pendingRunTaskId  = null;  // session_id waiting to send "run_task" after subscribe
  let   _pendingMessage    = null;  // { session_id, content } — slash command to send after subscribe

  // ── Markdown renderer ──────────────────────────────────────────────────
  //
  // Renders assistant message text as Markdown HTML using the marked library.
  // Thinking blocks (<think>...</think>) are extracted first, then the remaining
  // text is parsed as Markdown, and the rendered segments are reassembled.

  function _renderMarkdown(rawText) {
    if (!rawText) return "";

    const OPEN_TAG  = "<think>";
    const CLOSE_TAG = "</think>";

    // Split the raw text into alternating [text, think, text, think, ...] segments.
    // We extract <think> blocks BEFORE markdown parsing so they render verbatim,
    // not as markdown.
    const segments = [];  // { type: "text"|"think", content: string }
    let rest = rawText;

    while (rest.includes(OPEN_TAG)) {
      const openIdx  = rest.indexOf(OPEN_TAG);
      const closeIdx = rest.indexOf(CLOSE_TAG, openIdx + OPEN_TAG.length);

      // Text before <think>
      if (openIdx > 0) segments.push({ type: "text",  content: rest.slice(0, openIdx) });

      if (closeIdx === -1) {
        // Unclosed <think> — treat remainder as plain text
        segments.push({ type: "text", content: rest.slice(openIdx) });
        rest = "";
        break;
      }

      const thinkContent = rest.slice(openIdx + OPEN_TAG.length, closeIdx);
      segments.push({ type: "think", content: thinkContent });
      // Strip leading newlines immediately after </think>
      rest = rest.slice(closeIdx + CLOSE_TAG.length).replace(/^\n+/, "");
    }
    if (rest) segments.push({ type: "text", content: rest });

    // Render each segment and join
    let html = "";
    segments.forEach(seg => {
      if (seg.type === "think") {
        // Thinking content: render as markdown too (it may have code blocks etc.)
        const thinkHtml = _markedParse(seg.content);
        html += _buildThinkingBlock(thinkHtml);
      } else {
        html += _markedParse(seg.content);
      }
    });

    return html;
  }

  // Run marked on a text string. Returns HTML. Falls back to escaped plain text
  // if the marked library is unavailable.
  function _markedParse(text) {
    if (!text) return "";
    if (typeof marked !== "undefined") {
      // Custom renderer: open all links in a new tab
      const renderer = new marked.Renderer();
      renderer.link = function({ href, title, text }) {
        const titleAttr = title ? ` title="${title}"` : "";
        return `<a href="${href}"${titleAttr} target="_blank" rel="noopener noreferrer">${text}</a>`;
      };
      // Use marked with a few sensible defaults:
      //   breaks: true  — treat single newlines as <br> (matches chat UX expectations)
      //   gfm:    true  — GitHub-flavoured markdown (tables, strikethrough, etc.)
      return marked.parse(text, { breaks: true, gfm: true, renderer });
    }
    // Fallback: plain escaped text with newlines preserved
    return escapeHtml(text).replace(/\n/g, "<br>");
  }

  // Build the collapsible thinking block HTML for a given rendered-HTML content string.
  // Called by _renderMarkdown after the think-block content has been parsed by marked.
  function _buildThinkingBlock(renderedHtml) {
    return `<details class="thinking-block">` +
      `<summary class="thinking-summary">` +
        `<span class="thinking-chevron">›</span>` +
        `<span class="thinking-label">Thought for a moment</span>` +
      `</summary>` +
      `<div class="thinking-body">${renderedHtml}</div>` +
    `</details>`;
  }

  // ── Private helpers ────────────────────────────────────────────────────

  function _cacheActiveMessages() {
    // No-op: DOM is no longer cached. History is re-fetched from API on every switch.
  }

  function _restoreMessages(id) {
    // Clear the pane and dedup state; history will be re-fetched from API.
    $("messages").innerHTML = "";
    delete _renderedCreatedAt[id];
    if (_historyState[id]) {
      _historyState[id].oldestCreatedAt = null;
      _historyState[id].hasMore         = true;
      _historyState[id].loading         = false;  // reset so next fetch is not skipped
    }
  }

  // ── Tool group helpers ─────────────────────────────────────────────────
  //
  // A "tool group" is a collapsible <div class="tool-group"> that contains
  // one .tool-item row per tool_call in a consecutive run of tool calls.
  // While running: expanded (shows each tool + a "running" spinner).
  // When done (assistant_message or complete): collapsed to "⚙ N tools used".

  // Build one .tool-item row element.
  function _makeToolItem(name, args, summary) {
    const item = document.createElement("div");
    item.className = "tool-item";

    // Use backend-provided summary when available, fall back to client-side summarise
    const argSummary = summary || _summariseArgs(name, args);

    // When a structured summary is available, show it as the primary label (no redundant tool name).
    // Otherwise show the raw tool name + arg summary as before.
    const label = summary
      ? `<span class="tool-item-name">⚙ ${escapeHtml(summary)}</span>`
      : `<span class="tool-item-name">⚙ ${escapeHtml(name)}</span>` +
        (argSummary ? `<span class="tool-item-arg">${escapeHtml(argSummary)}</span>` : "");

    item.innerHTML = label + `<span class="tool-item-status running">…</span>`;
    return item;
  }

  // Produce a short one-line summary of tool arguments for the compact view.
  function _summariseArgs(toolName, args) {
    if (!args || typeof args !== "object") return String(args || "");
    // Pick the most informative single field as a short summary
    const pick = args.path || args.command || args.query || args.url ||
                 args.task || args.content || args.question || args.message;
    if (pick) return String(pick).slice(0, 80);
    // Fallback: first string value
    const first = Object.values(args).find(v => typeof v === "string");
    return first ? first.slice(0, 80) : "";
  }

  // Create a new tool group element (collapsed header + empty body).
  function _makeToolGroup() {
    const group = document.createElement("div");
    group.className = "tool-group expanded";

    const header = document.createElement("div");
    header.className = "tool-group-header";
    // Header is hidden until the group has ≥ 2 tool calls.
    // When there is only one tool call, the single .tool-item renders
    // directly (no redundant "1 tool(s) used" label above it).
    header.style.display = "none";
    header.innerHTML =
      `<span class="tool-group-arrow">▶</span>` +
      `<span class="tool-group-label">⚙ <span class="tg-count">0</span> tool(s) used</span>`;
    header.addEventListener("click", () => {
      group.classList.toggle("expanded");
    });

    const body = document.createElement("div");
    body.className = "tool-group-body";

    group.appendChild(header);
    group.appendChild(body);
    return group;
  }

  // Add a tool_call to a group; returns the new .tool-item element.
  function _addToolCallToGroup(group, name, args, summary) {
    const body   = group.querySelector(".tool-group-body");
    const header = group.querySelector(".tool-group-header");
    const count  = group.querySelector(".tg-count");
    const item   = _makeToolItem(name, args, summary);
    body.appendChild(item);
    const n = body.children.length;
    count.textContent = n;
    // Reveal the header once there are 2 or more tool calls
    if (n >= 2 && header.style.display === "none") header.style.display = "";
    return item;
  }

  // Mark the last tool-item in a group as done (update status indicator).
  function _completeLastToolItem(group, result) {
    const body  = group.querySelector(".tool-group-body");
    const items = body.querySelectorAll(".tool-item");
    if (!items.length) return;
    const last   = items[items.length - 1];
    const status = last.querySelector(".tool-item-status");
    if (status) {
      status.className = "tool-item-status ok";
      status.textContent = "✓";
    }
  }

  // Collapse a tool group (called when AI responds or task finishes).
  // When a group has only one tool call and no visible header, the body stays
  // "expanded" so the single tool item remains visible after collapse.
  function _collapseToolGroup(group) {
    const body = group.querySelector(".tool-group-body");
    const n    = body ? body.children.length : 0;
    // Only hide the body (collapse) when there are multiple tools with a visible header.
    // A single-tool group has no header, so we keep its body visible forever.
    if (n > 1) group.classList.remove("expanded");
  }

  // Render a single history event into a target container.
  // Reuses the same display logic as the live WS handler.
  // historyGroup: optional { group } state object shared across events in a round
  // (so consecutive tool_calls get grouped, and tool_results match up).
  function _renderHistoryEvent(ev, container, historyCtx) {
    // historyCtx = { group: DOMElement|null, lastItem: DOMElement|null }
    if (!historyCtx) historyCtx = { group: null, lastItem: null };

    switch (ev.type) {
      case "history_user_message": {
        // Collapse any open tool group from the previous round
        if (historyCtx.group) { _collapseToolGroup(historyCtx.group); historyCtx.group = null; }
        const el = document.createElement("div");
        el.className = "msg msg-user";
        // Render image thumbnails and PDF badges (if any) followed by the text content
        let bubbleHtml = "";
        if (Array.isArray(ev.images) && ev.images.length > 0) {
          bubbleHtml += ev.images.map(src => {
            if (src && src.startsWith("pdf:")) {
              // File badge — extract filename and extension from sentinel "pdf:<name>"
              const fname = src.slice(4);
              const ext   = (fname.split(".").pop() || "file").toUpperCase();
              const icon  = ext === "PDF" ? "📄" : ext === "ZIP" ? "🗜️" :
                            (ext === "DOC" || ext === "DOCX") ? "📝" :
                            (ext === "XLS" || ext === "XLSX") ? "📊" :
                            (ext === "PPT" || ext === "PPTX") ? "📋" : "📎";
              return `<span class="msg-pdf-badge">` +
                `<span class="msg-pdf-badge-icon">${icon}</span>` +
                `<span class="msg-pdf-badge-info">` +
                  `<span class="msg-pdf-badge-name">${escapeHtml(fname)}</span>` +
                  `<span class="msg-pdf-badge-type">${escapeHtml(ext)}</span>` +
                `</span>` +
              `</span>`;
            }
            return `<img src="${escapeHtml(src)}" alt="image" class="msg-image-thumb">`;
          }).join("");
          if (ev.content) bubbleHtml += "<br>";
        }
        bubbleHtml += escapeHtml(ev.content || "");
        el.innerHTML = bubbleHtml;
        container.appendChild(el);
        break;
      }

      case "assistant_message": {
        // Collapse tool group before assistant reply
        if (historyCtx.group) { _collapseToolGroup(historyCtx.group); historyCtx.group = null; }
        const el = document.createElement("div");
        el.className = "msg msg-assistant";
        el.innerHTML = _renderMarkdown(ev.content || "");
        container.appendChild(el);
        break;
      }

      case "tool_call": {
        // Start or reuse tool group
        if (!historyCtx.group) {
          historyCtx.group = _makeToolGroup();
          container.appendChild(historyCtx.group);
        }
        historyCtx.lastItem = _addToolCallToGroup(historyCtx.group, ev.name, ev.args, ev.summary);
        break;
      }

      case "tool_result": {
        if (historyCtx.group && historyCtx.lastItem) {
          const status = historyCtx.lastItem.querySelector(".tool-item-status");
          if (status) { status.className = "tool-item-status ok"; status.textContent = "✓"; }
          historyCtx.lastItem = null;
        }
        break;
      }

      case "token_usage": {
        // Collapse any open tool group before rendering the token line
        if (historyCtx.group) { _collapseToolGroup(historyCtx.group); historyCtx.group = null; }
        Sessions.appendTokenUsage(ev, container);
        break;
      }

      default:
        return; // skip unknown types
    }
  }

  // Fetch one page of history and insert into #messages or cache.
  // before=null means most recent page; prepend=true for scroll-up load.
  async function _fetchHistory(id, before = null, prepend = false) {
    const state = _historyState[id] || (_historyState[id] = { hasMore: true, oldestCreatedAt: null, loading: false });
    if (state.loading) return;
    state.loading = true;

    try {
      const params = new URLSearchParams({ limit: 30 });
      if (before) params.set("before", before);

      const res = await fetch(`/api/sessions/${id}/messages?${params}`);
      if (!res.ok) {
        if (id === _activeId) {
          let reason = "";
          try { const d = await res.json(); reason = d.error || ""; } catch {}
          const suffix = reason ? `: ${reason}` : "";
          Sessions.appendMsg("info", `${I18n.t("chat.history_load_failed")} (${res.status}${suffix})`);
        }
        return;
      }
      const data = await res.json();

      state.hasMore = !!data.has_more;

      const events = data.events || [];
      if (events.length === 0) return;

      // Track oldest created_at for next cursor (scroll-up pagination)
      events.forEach(ev => {
        if (ev.type === "history_user_message" && ev.created_at) {
          if (state.oldestCreatedAt === null || ev.created_at < state.oldestCreatedAt) {
            state.oldestCreatedAt = ev.created_at;
          }
        }
      });

      // Dedup by created_at: skip rounds already rendered (e.g. arrived via live WS)
      const dedup = _renderedCreatedAt[id] || (_renderedCreatedAt[id] = new Set());
      const frag  = document.createDocumentFragment();

      let currentCreatedAt = null;
      let skipRound        = false;
      // Shared context for tool grouping across a page of history events
      const historyCtx     = { group: null, lastItem: null };

      events.forEach(ev => {
        if (ev.type === "history_user_message") {
          currentCreatedAt = ev.created_at;
          skipRound        = currentCreatedAt && dedup.has(currentCreatedAt);
          if (!skipRound && currentCreatedAt) dedup.add(currentCreatedAt);
        }
        if (!skipRound) _renderHistoryEvent(ev, frag, historyCtx);
      });

      // Collapse any tool group still open at end of page
      if (historyCtx.group) _collapseToolGroup(historyCtx.group);

      // Insert into #messages (only renders if this session is currently active)
      if (id === _activeId) {
        const messages = $("messages");
        if (prepend && messages.firstChild) {
          const scrollBefore = messages.scrollHeight - messages.scrollTop;
          messages.insertBefore(frag, messages.firstChild);
          messages.scrollTop = messages.scrollHeight - scrollBefore;
        } else {
          messages.appendChild(frag);
          messages.scrollTop = messages.scrollHeight;
        }

        // Restore transient UI state based on session status after initial load
        // (not prepend, which is scroll-up pagination — no need to re-restore then)
        if (!prepend) {
          const session = _sessions.find(s => s.id === id);
          if (session) {
            if (session.status === "running") {
              // Agent is still running (e.g. page was refreshed mid-task)
              Sessions.showProgress(I18n.t("chat.thinking"));
            } else if (session.status === "error" && session.error) {
              // Show the stored error message at the end of history
              Sessions.appendMsg("error", session.error);
            }
          }
        }
      }
    } finally {
      state.loading = false;
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────

  // Return a human-readable relative label for a session with no name.
  // e.g. "Today 14:14" / "Yesterday" / "Mar 21"
  function _relativeTime(createdAt) {
    if (!createdAt) return I18n.t("sessions.untitled") || "Untitled";
    const d   = new Date(createdAt);
    const now = new Date();
    const diffDays = Math.floor((now - d) / 86400000);
    const pad = n => String(n).padStart(2, "0");
    const hhmm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    if (diffDays === 0) return `Today ${hhmm}`;
    if (diffDays === 1) return `Yesterday ${hhmm}`;
    return `${d.getMonth() + 1}/${d.getDate()} ${hhmm}`;
  }

  // Build a load-more button for a given source tab.
  function _makeLoadMoreBtn(source) {
    const btn = document.createElement("button");
    btn.className   = "btn-load-more-sessions";
    btn.disabled    = _loadingMoreSource[source];
    btn.textContent = _loadingMoreSource[source]
      ? I18n.t("sessions.loadingMore")
      : I18n.t("sessions.loadMore");
    btn.onclick = () => Sessions.loadMoreSessions(source);
    return btn;
  }

  // ── Private render helper ─────────────────────────────────────────────
  //
  // Build and append a single session-item <div> into `container`.
  // Used by both the general list and the coding section.
  function _renderSessionItem(container, s) {
    const el = document.createElement("div");
    el.className = "session-item" + (s.id === _activeId ? " active" : "");
    const displayName = s.name || _relativeTime(s.created_at);
    const metaText    = I18n.t("sessions.meta", { tasks: s.total_tasks || 0, cost: (s.total_cost || 0).toFixed(4) });
    el.innerHTML = `
      <span class="session-dot dot-${s.status || "idle"}"></span>
      <div class="session-body">
        <div class="session-name">${escapeHtml(displayName)}</div>
        <div class="session-meta">${metaText}</div>
      </div>
      <button class="session-delete-btn" title="${I18n.t("sessions.deleteTitle")}">×</button>`;

    // Use a click timer to distinguish single-click (select) from double-click (rename).
    let clickTimer = null;
    el.onclick = () => {
      if (clickTimer) {
        clearTimeout(clickTimer);
        clickTimer = null;
        return;
      }
      clickTimer = setTimeout(() => {
        clickTimer = null;
        Sessions.select(s.id);
      }, 200);
    };

    // Delete button
    const deleteBtn = el.querySelector(".session-delete-btn");
    deleteBtn.onclick = (e) => {
      e.stopPropagation();
      Sessions.deleteSession(s.id);
    };

    // Double-click to rename
    const nameDiv = el.querySelector(".session-name");
    nameDiv.ondblclick = (e) => {
      e.stopPropagation();
      if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
      Sessions._startRename(s.id, nameDiv, s.name);
    };

    container.appendChild(el);
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {
    get all()      { return _sessions; },
    get activeId() { return _activeId; },
    find: id => _sessions.find(s => s.id === id),

    // ── List management ───────────────────────────────────────────────────

    /** Populate list from initial session_list WS event (connect only). */
    setAll(list, hasMoreBySource = {}) {
      _sessions.length = 0;
      _sessions.push(...list);
      // Accept either new per-source map or legacy scalar boolean
      if (typeof hasMoreBySource === "object" && hasMoreBySource !== null) {
        Object.assign(_hasMoreBySource, hasMoreBySource);
      }
    },

    /** Insert a newly created session into the local list. */
    add(session) {
      if (!_sessions.find(s => s.id === session.id)) {
        _sessions.push(session);
      }
    },

    /** Patch a single session's fields (from session_update event).
     *  If the session is not in the list yet (e.g. just created by another tab),
     *  prepend it so the sidebar shows it immediately. */
    patch(id, fields) {
      const s = _sessions.find(s => s.id === id);
      if (s) {
        Object.assign(s, fields);
      } else {
        _sessions.unshift({ id, ...fields });
      }
    },

    /** Remove a session from the list (from session_deleted event). */
    remove(id) {
      const idx = _sessions.findIndex(s => s.id === id);
      if (idx !== -1) _sessions.splice(idx, 1);
    },

    /** Load older sessions for a specific bucket.
     *  bucket: "manual" | "cron" | "channel" | "setup"  → uses ?source=<bucket>
     *          "coding"                                  → uses ?profile=coding
     */
    async loadMoreSessions(source) {
      if (_loadingMoreSource[source] || !_hasMoreBySource[source]) return;
      _loadingMoreSource[source] = true;
      Sessions.renderList();  // re-render to show loading state on button

      try {
        // Cursor: oldest created_at among sessions in this bucket
        const bucketSessions = source === "coding"
          ? _sessions.filter(s => s.agent_profile === "coding")
          : _sessions.filter(s => s.source === source);

        const oldest = bucketSessions.reduce((min, s) => {
          if (!s.created_at) return min;
          return (!min || s.created_at < min) ? s.created_at : min;
        }, null);

        const param = source === "coding" ? "profile=coding" : `source=${encodeURIComponent(source)}&profile=general`;
        let url = `/api/sessions?limit=10&${param}`;
        if (oldest) url += `&before=${encodeURIComponent(oldest)}`;

        const res  = await fetch(url);
        if (!res.ok) return;
        const data = await res.json();

        let added = 0;
        (data.sessions || []).forEach(s => {
          if (!_sessions.find(x => x.id === s.id)) {
            _sessions.push(s);
            added++;
          }
        });
        _hasMoreBySource[source] = !!data.has_more;

        if (added > 0) Sessions.renderList();
        else Sessions.renderList();  // update button state even with no new items
      } catch (e) {
        console.error("loadMoreSessions error:", e);
      } finally {
        _loadingMoreSource[source] = false;
        Sessions.renderList();
      }
    },

    /** Delete a session via API (called from UI delete button). */
    async deleteSession(id) {
      const s = _sessions.find(s => s.id === id);
      const name = s ? s.name : id;
      const confirmed = await Modal.confirm(I18n.t("sessions.confirmDelete", { name }));
      if (!confirmed) return;

      try {
        const res = await fetch(`/api/sessions/${id}`, { method: "DELETE" });
        if (res.ok) {
          // Optimistically remove from local list immediately without waiting for
          // the WS session_deleted broadcast (handles WS lag or disconnected state).
          Sessions.remove(id);
          if (id === Sessions.activeId) Router.navigate("welcome");
          Sessions.renderList();
        } else {
          const data = await res.json().catch(() => ({}));
          console.error("Failed to delete session:", data.error || res.status);
          // If server says not found, remove it from local list anyway to keep UI consistent.
          if (res.status === 404) {
            Sessions.remove(id);
            if (id === Sessions.activeId) Router.navigate("welcome");
            Sessions.renderList();
          }
        }
        // Server also broadcasts session_deleted WS event; Sessions.remove() is idempotent
        // so duplicate removal is harmless.
      } catch (err) {
        console.error("Delete session error:", err);
      }
    },

    // ── Selection ─────────────────────────────────────────────────────────
    //
    // Panel switching is handled by Router — Sessions only manages state.

    /** Navigate to a session. Delegates panel switching to Router. */
    select(id) {
      const s = _sessions.find(s => s.id === id);
      if (!s) return;
      Router.navigate("session", { id });
    },

    /** Deselect active session and go to welcome screen. */
    deselect() {
      _cacheActiveMessages();
      _activeId = null;
      WS.setSubscribedSession(null);
      Router.navigate("welcome");
    },

    // ── Router interface ──────────────────────────────────────────────────
    // These methods are called exclusively by Router._apply() to mutate
    // session state as part of a coordinated view transition. They must NOT
    // trigger further Router.navigate() calls to avoid infinite loops.

    /** Set _activeId directly (called by Router when activating a session). */
    _setActiveId(id) {
      _activeId = id;
    },

    /** Restore cached messages for a session into the #messages container. */
    _restoreMessagesPublic(id) {
      _restoreMessages(id);
    },

    /** Cache messages + clear activeId without touching panel visibility.
     *  Called by Router before switching away from a session view. */
    _cacheActiveAndDeselect() {
      _cacheActiveMessages();
      _activeId = null;
      WS.setSubscribedSession(null);
      Sessions.renderList();
    },

    // ── Rendering ─────────────────────────────────────────────────────────

    setTab(tab) {
      _activeTab = tab;
      // Sync tab button active state
      document.querySelectorAll(".session-tab").forEach(btn => {
        btn.classList.toggle("active", btn.dataset.tab === tab);
      });
      Sessions.renderList();
    },

    renderList() {
      // Sort helper: newest-first by created_at
      const byTime = (a, b) => {
        const ta = a.created_at ? new Date(a.created_at) : 0;
        const tb = b.created_at ? new Date(b.created_at) : 0;
        return tb - ta;
      };

      // ── Classify ──────────────────────────────────────────────────────────
      // Two orthogonal dimensions: agent_profile (general vs coding) and source (tab).
      // Coding section: profile === "coding", shown separately at bottom — no source filter.
      // General area tabs: all non-coding sessions, filtered by source per tab.
      const codingSessions  = _sessions.filter(s => s.agent_profile === "coding").sort(byTime);
      const generalSessions = _sessions.filter(s => s.agent_profile !== "coding").sort(byTime);

      // ── Tab visibility ────────────────────────────────────────────────────
      const hasCron    = generalSessions.some(s => s.source === "cron")    || _hasMoreBySource["cron"];
      const hasChannel = generalSessions.some(s => s.source === "channel") || _hasMoreBySource["channel"];
      const hasSetup   = generalSessions.some(s => s.source === "setup")   || _hasMoreBySource["setup"];
      const hasNonManual = hasCron || hasChannel || hasSetup;

      const tabBar = $("session-tabs");
      if (tabBar) tabBar.style.display = hasNonManual ? "" : "none";

      const setupTabBtn = $("tab-setup");
      if (setupTabBtn) setupTabBtn.style.display = hasSetup ? "" : "none";

      // Use active tab directly — no fallback to manual when content is empty.
      // Tabs may show an empty state (e.g. cron tab before any cron sessions exist).
      const effectiveTab = _activeTab;

      const tabSessions = generalSessions.filter(s => (s.source || "manual") === effectiveTab);

      // ── Render general (tab-filtered) sessions ──────────────────────────
      const list = $("session-list");
      list.innerHTML = "";
      if (tabSessions.length === 0) {
        list.innerHTML = `<div class="session-empty">${I18n.t("sessions.empty")}</div>`;
      } else {
        tabSessions.forEach(s => _renderSessionItem(list, s));
      }
      // Per-tab load-more button (inside the tab's section)
      if (_hasMoreBySource[effectiveTab]) {
        list.appendChild(_makeLoadMoreBtn(effectiveTab));
      }

      // ── Render coding sessions (fixed section) ───────────────────────────
      const codingSection = $("coding-section");
      const codingList    = $("coding-session-list");
      if (codingSessions.length === 0) {
        codingSection.style.display = "none";
      } else {
        codingSection.style.display = "";
        codingList.innerHTML = "";
        codingSessions.forEach(s => _renderSessionItem(codingList, s));
        // Per-section load-more button
        if (_hasMoreBySource["coding"]) {
          codingList.appendChild(_makeLoadMoreBtn("coding"));
        }
      }
    },

    /** Begin inline rename: replace session-name content with an <input>. */
    _startRename(sessionId, nameDiv, currentName) {
      // Prevent starting a second rename while one is already active
      if (nameDiv.querySelector("input")) return;

      // Replace name span content with input (dot lives in session-row, not here)
      nameDiv.innerHTML = "";
      nameDiv.classList.add("renaming"); // disable overflow:hidden while editing
      const input = document.createElement("input");
      input.className = "session-rename-input";
      input.value = currentName;
      nameDiv.appendChild(input);
      input.focus();
      input.select();

      // Track whether commit has already run to prevent double-firing
      // (blur fires when the DOM is torn down by renderList, so we guard it)
      let committed = false;

      const commit = async () => {
        if (committed) return;
        committed = true;

        // Capture value before touching the DOM
        const newName = input.value.trim();

        // Restore original display immediately
        nameDiv.classList.remove("renaming");
        nameDiv.textContent = currentName;

        if (!newName || newName === currentName) return;

        try {
          const res = await fetch(`/api/sessions/${sessionId}`, {
            method: "PATCH",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name: newName })
          });
          if (!res.ok) console.error("Rename failed:", await res.text());
          // WS session_renamed event will update the list
        } catch (err) {
          console.error("Rename error:", err);
        }
      };

      input.onblur = commit;
      input.onkeydown = (e) => {
        if (e.key === "Enter") { e.preventDefault(); input.blur(); }
        if (e.key === "Escape") { committed = true; input.value = currentName; input.blur(); }
      };
      // Stop click/dblclick from bubbling while editing
      input.onclick  = (e) => e.stopPropagation();
      input.ondblclick = (e) => e.stopPropagation();
    },

    updateStatusBar(status) {
      $("chat-status").textContent = status || "idle";
      if (status === "running") {
        $("chat-status").className = "status-running";
      } else if (status === "error") {
        $("chat-status").className = "status-error";
      } else {
        $("chat-status").className = "status-idle";
      }
      $("btn-interrupt").style.display = status === "running" ? "" : "none";
    },

    /** Update the session info bar below the chat header with current session metadata. */
    updateInfoBar(s) {
      if (!s) {
        // Hide all spans when no session
        ["sib-id", "sib-status", "sib-dir", "sib-mode", "sib-model", "sib-tasks", "sib-cost"].forEach(id => {
          const el = $(id); if (el) el.textContent = "";
        });
        const bar = $("session-info-bar");
        if (bar) bar.style.display = "none";
        return;
      }

      // Status dot + text — first
      const sibStatus = $("sib-status");
      if (sibStatus) {
        sibStatus.textContent = `● ${s.status || "idle"}`;
        sibStatus.className = `sib-status-${s.status || "idle"}`;
      }

      // Session ID (short — first 8 chars)
      const sibId = $("sib-id");
      if (sibId) sibId.textContent = s.id ? s.id.slice(0, 8) : "";

      // Working dir — shorten to last 2 path segments
      const sibDir = $("sib-dir");
      if (sibDir && s.working_dir) {
        const parts = s.working_dir.replace(/\/$/, "").split("/");
        sibDir.textContent = parts.length > 2 ? "…/" + parts.slice(-2).join("/") : s.working_dir;
        sibDir.title = s.working_dir;
      }

      // Permission mode — hide wrap entirely if empty
      const sibModeWrap = $("sib-mode-wrap");
      const sibMode = $("sib-mode");
      if (sibMode) sibMode.textContent = s.permission_mode || "";
      if (sibModeWrap) sibModeWrap.style.display = s.permission_mode ? "" : "none";

      // Model — hide wrap entirely if empty
      const sibModelWrap = $("sib-model-wrap");
      const sibModel = $("sib-model");
      if (sibModel) sibModel.textContent = s.model || "";
      if (sibModelWrap) sibModelWrap.style.display = s.model ? "" : "none";

      // Tasks
      const sibTasks = $("sib-tasks");
      if (sibTasks) sibTasks.textContent = `${s.total_tasks || 0} tasks`;

      // Cost
      const sibCost = $("sib-cost");
      if (sibCost) sibCost.textContent = `$${(s.total_cost || 0).toFixed(2)}`;

      const bar = $("session-info-bar");
      if (bar) bar.style.display = "flex";
    },

    // ── Message helpers ────────────────────────────────────────────────────

    // Live tool group state (one active group per session at a time)
    _liveToolGroup:     null,  // current open .tool-group DOM element
    _liveLastToolItem:  null,  // last .tool-item added (for tool_result pairing)

    // Append a tool_call as a compact item inside the live tool group.
    // Creates the group if it doesn't exist yet.
    appendToolCall(name, args, summary) {
      const messages = $("messages");
      if (!Sessions._liveToolGroup) {
        Sessions._liveToolGroup = _makeToolGroup();
        messages.appendChild(Sessions._liveToolGroup);
      }
      Sessions._liveLastToolItem = _addToolCallToGroup(Sessions._liveToolGroup, name, args, summary);
      messages.scrollTop = messages.scrollHeight;
    },

    // Update the last tool-item with a result status tick.
    appendToolResult(result) {
      if (Sessions._liveToolGroup && Sessions._liveLastToolItem) {
        _completeLastToolItem(Sessions._liveToolGroup, result);
        Sessions._liveLastToolItem = null;
      }
    },

    // Append a token usage line directly to the message list.
    // Server guarantees this event arrives AFTER assistant_message, so no buffering needed.
    // Format mirrors CLI:
    //   [Tokens] | +409 | [*] | Input: 69,977 (cache: 69,566 read, 410 write) | Output: 101 | Total: 70,078 | Cost: $0.02392
    appendTokenUsage(ev, container) {
      const messages = container || $("messages");
      const el = document.createElement("div");
      el.className = "token-usage-line";

      // Delta: +N or -N with colour coding
      const delta    = ev.delta_tokens || 0;
      const deltaStr = delta >= 0 ? `+${delta.toLocaleString()}` : `${delta.toLocaleString()}`;
      let   deltaCls = delta > 10000 ? "tu-delta-high" : delta > 5000 ? "tu-delta-mid" : "tu-delta-ok";
      if (delta < 0) deltaCls = "tu-delta-neg";

      // Cache indicator [*] when cache was used
      const cacheRead  = ev.cache_read  || 0;
      const cacheWrite = ev.cache_write || 0;
      const cacheUsed  = cacheRead > 0 || cacheWrite > 0;

      // Input: base tokens + cache breakdown
      const promptTokens = ev.prompt_tokens || 0;
      let inputStr = promptTokens.toLocaleString();
      if (cacheUsed) {
        const parts = [];
        if (cacheRead  > 0) parts.push(`${cacheRead.toLocaleString()} read`);
        if (cacheWrite > 0) parts.push(`${cacheWrite.toLocaleString()} write`);
        inputStr += ` (cache: ${parts.join(", ")})`;
      }

      // Cost: 5 decimal places (matches CLI precision)
      // :api    => "$0.00123"   (exact)
      // :price  => "~$0.00123" (estimated from pricing table)
      // :default => "N/A"      (model unknown)
      const cost = ev.cost || 0;
      let costStr;
      if (ev.cost_source === "default") {
        costStr = "N/A";
      } else if (ev.cost_source === "price") {
        costStr = `~$${cost.toFixed(5)}`;
      } else {
        costStr = `$${cost.toFixed(5)}`;
      }

      // Always-visible: label, delta, cache indicator, cost
      // Detail fields (Input/Output/Total) are hidden until hover
      el.innerHTML =
        `<span class="tu-label">[Tokens]</span>` +
        `<span class="tu-sep">|</span>` +
        `<span class="tu-delta ${deltaCls}">${escapeHtml(deltaStr)}</span>` +
        (cacheUsed ? `<span class="tu-sep">|</span><span class="tu-cache">[*]</span>` : "") +
        `<span class="tu-sep">|</span>` +
        `<span class="tu-cost">Cost: ${escapeHtml(costStr)}</span>` +
        `<span class="tu-detail">` +
          `<span class="tu-sep">|</span>` +
          `<span class="tu-field">Input: <b>${escapeHtml(inputStr)}</b></span>` +
          `<span class="tu-sep">|</span>` +
          `<span class="tu-field">Output: <b>${(ev.completion_tokens || 0).toLocaleString()}</b></span>` +
          `<span class="tu-sep">|</span>` +
          `<span class="tu-field">Total: <b>${(ev.total_tokens || 0).toLocaleString()}</b></span>` +
        `</span>`;

      messages.appendChild(el);
      if (!container) messages.scrollTop = messages.scrollHeight; // only auto-scroll for live events
    },

    // Collapse the live tool group (call when AI starts responding or task ends).
    collapseToolGroup() {
      if (Sessions._liveToolGroup) {
        _collapseToolGroup(Sessions._liveToolGroup);
        Sessions._liveToolGroup    = null;
        Sessions._liveLastToolItem = null;
      }
    },

    appendMsg(type, html) {
      // Starting a new assistant/user/info message: close any open tool group
      if (type !== "tool") Sessions.collapseToolGroup();

      const messages = $("messages");
      const el = document.createElement("div");
      el.className = `msg msg-${type}`;
      // Assistant messages are rendered as Markdown (raw text → HTML via marked).
      // All other types receive pre-escaped HTML strings and are inserted directly.
      el.innerHTML = type === "assistant" ? _renderMarkdown(html) : html;
      messages.appendChild(el);
      messages.scrollTop = messages.scrollHeight;
    },

    appendInfo(text) {
      Sessions.collapseToolGroup();
      const messages = $("messages");
      const el = document.createElement("div");
      el.className   = "msg msg-info";
      el.textContent = text;
      messages.appendChild(el);
      messages.scrollTop = messages.scrollHeight;
    },

    // Two-phase idle compression status — renders as a single line that updates in-place.
    // phase "start": create element with spinner; phase "end": update same element with result.
    updateIdleStatus(phase, text) {
      const messages = $("messages");
      if (phase === "start") {
        Sessions.collapseToolGroup();
        const el = document.createElement("div");
        el.className   = "msg msg-info msg-idle-status";
        el.textContent = "⟳ " + text;
        messages.appendChild(el);
        Sessions._idleStatusEl = el;
      } else {
        // phase "end" — update existing element or create a new one if start was missed
        if (Sessions._idleStatusEl) {
          Sessions._idleStatusEl.textContent = "· " + text;
          Sessions._idleStatusEl.classList.add("msg-idle-done");
          Sessions._idleStatusEl = null;
        } else {
          Sessions.appendInfo("· " + text);
        }
      }
      messages.scrollTop = messages.scrollHeight;
    },

    _idleStatusEl: null,

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

    // Append live shell output lines beneath the progress indicator.
    // Creates a scrollable <pre> block on first call; subsequent calls append lines.
    appendShellOutput(text) {
      if (!text) return;
      const messages = $("messages");
      if (!Sessions._shellOutputEl) {
        const pre = document.createElement("pre");
        pre.className = "shell-output-block";
        // Insert after _progressEl if present, otherwise at bottom
        if (Sessions._progressEl && Sessions._progressEl.parentNode === messages) {
          Sessions._progressEl.insertAdjacentElement("afterend", pre);
        } else {
          messages.appendChild(pre);
        }
        Sessions._shellOutputEl = pre;
      }
      // Append new lines (add newline separator if block already has content)
      if (Sessions._shellOutputEl.textContent) {
        Sessions._shellOutputEl.textContent += "\n" + text;
      } else {
        Sessions._shellOutputEl.textContent = text;
      }
      messages.scrollTop = messages.scrollHeight;
    },

    clearShellOutput() {
      if (Sessions._shellOutputEl) {
        Sessions._shellOutputEl.remove();
        Sessions._shellOutputEl = null;
      }
    },

    _shellOutputEl: null,

    // ── Create ─────────────────────────────────────────────────────────────

    /** Create a new session and navigate to it. */
    async create(agentProfile = "general") {
      const maxN = _sessions.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const name = "Session " + (maxN + 1);

      const res  = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name, agent_profile: agentProfile, source: "manual" })
      });
      const data = await res.json();
      if (!res.ok) { alert(I18n.t("sessions.createError") + (data.error || "unknown")); return; }

      const session = data.session;
      if (!session) return;

      Sessions.add(session);

      // If a coding session was created, make sure the coding section is visible.
      // If a general session was created, switch to the manual tab to show it.
      if (agentProfile === "general") Sessions.setTab("manual");
      Sessions.renderList();
      Sessions.select(session.id);
    },

    // ── History loading ────────────────────────────────────────────────────

    /** Load the most recent page of history for a session (called on first visit). */
    loadHistory(id) {
      return _fetchHistory(id, null, false);
    },

    /** Load older history (called when user scrolls to top). */
    loadMoreHistory(id) {
      const state = _historyState[id];
      if (!state || !state.hasMore) return;
      return _fetchHistory(id, state.oldestCreatedAt, true);
    },

    /** Check if there is more history to load for a session. */
    hasMoreHistory(id) {
      return _historyState[id]?.hasMore ?? true;
    },

    /** Register a live-WS-rendered round's created_at so history replay skips it. */
    markRendered(id, createdAt) {
      if (!createdAt) return;
      const dedup = _renderedCreatedAt[id] || (_renderedCreatedAt[id] = new Set());
      dedup.add(createdAt);
    },

    /** Mark a session as having a pending task that should start after subscribe. */
    setPendingRunTask(sessionId) {
      _pendingRunTaskId = sessionId;
    },

    /** Consume and return the pending run-task session id (clears it). */
    takePendingRunTask() {
      const id = _pendingRunTaskId;
      _pendingRunTaskId = null;
      return id;
    },

    /** Register a slash-command message to send after subscribe is confirmed. */
    setPendingMessage(sessionId, content) {
      _pendingMessage = { session_id: sessionId, content };
    },

    /** Consume and return the pending message (clears it). */
    takePendingMessage() {
      const msg = _pendingMessage;
      _pendingMessage = null;
      return msg;
    },
  };
})();
