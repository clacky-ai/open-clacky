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
  let   _hasMore           = false;   // unified pagination: are there older sessions to load?
  let   _loadingMore       = false;
  // Search state
  const _filter            = { q: "", date: "", type: "" };  // committed filter (applied to server)
  let   _searchOpen        = false;   // is the search panel visible?
  let   _pendingRunTaskId  = null;  // session_id waiting to send "run_task" after subscribe
  let   _pendingMessage    = null;  // { session_id, content } — slash command to send after subscribe
  // Buffer for tool_stdout lines that arrive before history has finished rendering.
  // This happens on session switch: WS replay fires before the HTTP history fetch completes.
  // Flushed in _fetchHistory after the fragment is appended to the DOM.
  let   _pendingStdoutLines = null; // string[] | null

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
    // Reset scroll tracking when switching sessions
    _userScrolledUp = false;
  }

  // ── Auto-scroll helper ─────────────────────────────────────────────────
  //
  // Track whether user has manually scrolled up. If they haven't, always auto-scroll.
  // If they have, only auto-scroll when they scroll back to bottom themselves.
  //
  // This solves the issue where rapid content streaming causes scrollHeight to grow
  // faster than scrollTop can catch up, incorrectly triggering the "not at bottom" check.

  let _userScrolledUp = false;  // true if user manually scrolled away from bottom

  function _isAtBottom(container) {
    if (!container) return false;
    const threshold = 150;
    return container.scrollHeight - container.scrollTop - container.clientHeight < threshold;
  }

  function _scrollToBottomIfNeeded(container) {
    if (!container) return;
    // Only auto-scroll if user hasn't manually scrolled up
    // Once they scroll up, stop auto-scrolling until they scroll back to bottom themselves
    if (!_userScrolledUp) {
      container.scrollTop = container.scrollHeight;
      _hideNewMessageBanner();
    } else {
      _showNewMessageBanner();
    }
  }

  // ── New message notification banner ────────────────────────────────────
  //
  // Shows a floating "New messages ↓" banner when new messages arrive and
  // user is not at the bottom of the message list. Clicking the banner
  // scrolls to bottom and hides it.

  function _showNewMessageBanner() {
    const banner = $("new-message-banner");
    if (!banner) return;
    banner.style.display = "block";
  }

  function _hideNewMessageBanner() {
    const banner = $("new-message-banner");
    if (!banner) return;
    banner.style.display = "none";
  }

  function _initNewMessageBanner() {
    const banner = $("new-message-banner");
    const messages = $("messages");
    if (!banner || !messages) return;
    
    // Click to scroll to bottom
    banner.addEventListener("click", () => {
      messages.scrollTop = messages.scrollHeight;
      _userScrolledUp = false;
      _hideNewMessageBanner();
    });

    // Detect actual user scroll interactions (wheel, touch, keyboard)
    // These fire BEFORE the scroll event, so we can set the flag reliably.
    const detectUserScroll = (e) => {
      // Only flag if user is scrolling up (negative deltaY = scroll up)
      // For wheel events: deltaY < 0 means scroll up
      // For touch/keyboard: check scroll position in the scroll event
      const isWheelUp = e.type === "wheel" && e.deltaY < 0;
      const isKeyboardUp = e.type === "keydown" && (e.key === "ArrowUp" || e.key === "PageUp" || e.key === "Home");
      
      if (isWheelUp || isKeyboardUp) {
        _userScrolledUp = true;
      }
    };

    messages.addEventListener("wheel", detectUserScroll, { passive: true });
    messages.addEventListener("keydown", detectUserScroll);
    
    // For touch devices: touchmove doesn't tell us direction, so check in scroll event
    let touchStartY = 0;
    messages.addEventListener("touchstart", (e) => {
      touchStartY = e.touches[0].clientY;
    }, { passive: true });
    
    messages.addEventListener("touchmove", (e) => {
      const touchDeltaY = e.touches[0].clientY - touchStartY;
      // touchDeltaY > 0 means finger moved down = content scrolls up
      if (touchDeltaY > 5) {
        _userScrolledUp = true;
      }
    }, { passive: true });

    // Monitor scroll position: clear flag when user reaches bottom
    messages.addEventListener("scroll", () => {
      if (_isAtBottom(messages)) {
        _userScrolledUp = false;
        _hideNewMessageBanner();
      }
    });
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

    item.innerHTML =
      `<div class="tool-item-header">` +
        label +
        `<span class="tool-item-status running">…</span>` +
      `</div>` +
      `<pre class="tool-item-stdout" style="display:none"></pre>`;
    return item;
  }

  // Convert ANSI escape codes to HTML spans with color classes.
  // Handles the common SGR codes used by shell scripts (colors + reset).
  function _ansiToHtml(text) {
    const ANSI_COLORS = {
      "30": "ansi-black",   "31": "ansi-red",     "32": "ansi-green",
      "33": "ansi-yellow",  "34": "ansi-blue",     "35": "ansi-magenta",
      "36": "ansi-cyan",    "37": "ansi-white",
      "1;31": "ansi-bold ansi-red",   "1;32": "ansi-bold ansi-green",
      "1;33": "ansi-bold ansi-yellow","1;34": "ansi-bold ansi-blue",
      "0;31": "ansi-red",   "0;32": "ansi-green",
      "0;33": "ansi-yellow","0;34": "ansi-blue",
    };
    let result = "";
    let open = false;
    // Split on ESC[ sequences
    const parts = text.split(/\x1b\[([0-9;]*)m/);
    for (let i = 0; i < parts.length; i++) {
      if (i % 2 === 0) {
        // Plain text — escape HTML
        result += parts[i].replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
      } else {
        // Code
        const code = parts[i];
        if (open) { result += "</span>"; open = false; }
        if (code === "0" || code === "") {
          // reset — already closed above
        } else {
          const cls = ANSI_COLORS[code];
          if (cls) { result += `<span class="${cls}">`; open = true; }
        }
      }
    }
    if (open) result += "</span>";
    return result;
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
    // If stdout area is empty, hide it; otherwise keep it visible (user may be reading)
    const stdout = last.querySelector(".tool-item-stdout");
    if (stdout && !stdout.textContent.trim()) stdout.style.display = "none";
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
            if (src && src.startsWith("expired:")) {
              // Image whose tmp file has been deleted — show an expired badge
              const fname = src.slice(8);
              return `<span class="msg-pdf-badge msg-image-expired">` +
                `<span class="msg-pdf-badge-icon">🖼️</span>` +
                `<span class="msg-pdf-badge-info">` +
                  `<span class="msg-pdf-badge-name">${escapeHtml(fname || "image")}</span>` +
                  `<span class="msg-pdf-badge-type">${I18n.t("chat.image_expired") || "Expired"}</span>` +
                `</span>` +
              `</span>`;
            }
            return `<img src="${escapeHtml(src)}" alt="image" class="msg-image-thumb">`;
          }).join("");
          if (ev.content) bubbleHtml += "<br>";
        }
        bubbleHtml += escapeHtml(ev.content || "");
        el.innerHTML = bubbleHtml;
        _appendMsgTime(el, ev.created_at);
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

  // Write stdout lines into a .tool-item's stdout area, showing it if hidden.
  // Shared by appendToolStdout (live) and _flushPendingStdout (deferred).
  function _applyStdoutToItem(toolItem, lines) {
    const stdout = toolItem.querySelector(".tool-item-stdout");
    if (!stdout) return;
    stdout.innerHTML += lines.map(_ansiToHtml).join("");
    if (stdout.style.display === "none") stdout.style.display = "";
    stdout.scrollTop = stdout.scrollHeight;
    const messages = $("messages");
    _scrollToBottomIfNeeded(messages);
  }

  // Flush any stdout lines buffered while history was still loading.
  // Called from _fetchHistory right after the DOM fragment is inserted.
  function _flushPendingStdout() {
    if (!_pendingStdoutLines || _pendingStdoutLines.length === 0) return;
    const lines = _pendingStdoutLines;
    _pendingStdoutLines = null;

    const messages = $("messages");
    if (!messages) return;
    const items = messages.querySelectorAll(".tool-item");
    if (items.length === 0) return;
    const toolItem = items[items.length - 1];
    _applyStdoutToItem(toolItem, lines);
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
          // Initial load or append: scroll to bottom (user just opened session or sent message)
          messages.appendChild(frag);
          messages.scrollTop = messages.scrollHeight;
          // Flush any tool_stdout lines that arrived via WS before this history
          // fetch completed (race condition on session switch).
          if (!prepend) _flushPendingStdout();
        }

        // If no more history remains, insert a "beginning of conversation" marker at the top.
        // Remove any existing marker first to avoid duplicates.
        messages.querySelector(".history-start-marker")?.remove();
        if (!state.hasMore) {
          const marker = document.createElement("div");
          marker.className = "history-start-marker";
          marker.textContent = I18n.t("chat.history_start");
          messages.insertBefore(marker, messages.firstChild);
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

  // Format a timestamp for display inside a message bubble.
  // Same-day: "HH:MM"; cross-day: "MM-DD HH:MM".
  function _formatMsgTime(dateOrStr) {
    if (!dateOrStr) return "";
    const d   = new Date(dateOrStr);
    if (isNaN(d)) return "";
    const now = new Date();
    const pad = n => String(n).padStart(2, "0");
    const hhmm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    const sameDay = d.getFullYear() === now.getFullYear() &&
                    d.getMonth()    === now.getMonth()    &&
                    d.getDate()     === now.getDate();
    return sameDay ? hhmm : `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${hhmm}`;
  }

  // Append a .msg-time span to a message element.
  function _appendMsgTime(el, dateOrStr) {
    const t = _formatMsgTime(dateOrStr);
    if (!t) return;
    const span = document.createElement("span");
    span.className   = "msg-time";
    span.textContent = t;
    el.appendChild(span);
  }

  // Build the unified load-more button.
  function _makeLoadMoreBtn() {
    const btn = document.createElement("button");
    btn.className   = "btn-load-more-sessions";
    btn.disabled    = _loadingMore;
    btn.textContent = _loadingMore ? I18n.t("sessions.loadingMore") : I18n.t("sessions.loadMore");
    btn.onclick = () => Sessions.loadMore();
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

    // Source badge: only shown for non-manual sessions
    const badgeKey = s.agent_profile === "coding" ? "sessions.badge.coding"
                   : s.source === "cron"          ? "sessions.badge.cron"
                   : s.source === "channel"        ? "sessions.badge.channel"
                   : s.source === "setup"          ? "sessions.badge.setup"
                   : null;
    const badgeHtml = badgeKey
      ? `<span class="session-badge session-badge--${s.agent_profile === "coding" ? "coding" : s.source}">${I18n.t(badgeKey)}</span>`
      : "";

    el.innerHTML = `
      <span class="session-dot dot-${s.status || "idle"}"></span>
      <div class="session-body">
        <div class="session-name">${escapeHtml(displayName)}${badgeHtml}</div>
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

    // Double-click anywhere on the session row to rename
    const nameDiv = el.querySelector(".session-name");
    el.ondblclick = (e) => {
      // Ignore double-click on the delete button
      if (e.target.closest(".session-delete-btn")) return;
      e.stopPropagation();
      if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
      Sessions._startRename(s.id, nameDiv, s.name);
    };

    container.appendChild(el);
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {
    get all()        { return _sessions; },
    get activeId()   { return _activeId; },
    get searchOpen() { return _searchOpen; },
    find: id => _sessions.find(s => s.id === id),

    // ── Init ──────────────────────────────────────────────────────────────
    init() {
      _initNewMessageBanner();
      // Re-render session list (badges/labels) when the user switches language
      document.addEventListener("langchange", () => Sessions.renderList());
    },

    // ── List management ───────────────────────────────────────────────────

    /** Populate list from initial session_list WS event (connect only). */
    setAll(list, hasMore = false) {
      _sessions.length = 0;
      _sessions.push(...list);
      _hasMore = !!hasMore;
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

    /** Load the next page of older sessions (unified time cursor). */
    async loadMore() {
      if (_loadingMore || !_hasMore) return;
      _loadingMore = true;
      Sessions.renderList();

      try {
        // Cursor: oldest created_at in the current list
        const oldest = _sessions.reduce((min, s) => {
          if (!s.created_at) return min;
          return (!min || s.created_at < min) ? s.created_at : min;
        }, null);

        const params = new URLSearchParams({ limit: "20" });
        if (oldest)          params.set("before", oldest);
        if (_filter.q)       params.set("q",    _filter.q);
        if (_filter.date)    params.set("date", _filter.date);
        if (_filter.type)    params.set("type", _filter.type);

        const res  = await fetch(`/api/sessions?${params}`);
        if (!res.ok) return;
        const data = await res.json();

        (data.sessions || []).forEach(s => {
          if (!_sessions.find(x => x.id === s.id)) _sessions.push(s);
        });
        _hasMore = !!data.has_more;
      } catch (e) {
        console.error("loadMore error:", e);
      } finally {
        _loadingMore = false;
        Sessions.renderList();
      }
    },

    /** Commit current filter values and re-fetch from server. Called by Enter / Go button. */
    async commitSearch() {
      // Read live input values into _filter
      const qEl    = document.getElementById("session-search-q");
      const typeEl = document.getElementById("session-search-type");
      const dateEl = document.getElementById("session-search-date");
      if (qEl)    _filter.q    = qEl.value.trim();
      if (typeEl) _filter.type = typeEl.value;
      if (dateEl) _filter.date = dateEl.value;

      // Clear list and reload from server with new filters
      _sessions.length = 0;
      _hasMore = false;
      _loadingMore = true;
      Sessions.renderList();

      try {
        const params = new URLSearchParams({ limit: "20" });
        if (_filter.q)    params.set("q",    _filter.q);
        if (_filter.date) params.set("date", _filter.date);
        if (_filter.type) params.set("type", _filter.type);

        const res  = await fetch(`/api/sessions?${params}`);
        if (!res.ok) return;
        const data = await res.json();
        _sessions.push(...(data.sessions || []));
        _hasMore = !!data.has_more;
      } catch (e) {
        console.error("commitSearch error:", e);
      } finally {
        _loadingMore = false;
        Sessions.renderList();
      }
    },

    /** Clear a single filter key and re-fetch. */
    async clearFilter(key) {
      _filter[key] = "";
      // Sync the DOM input back
      const ids = { q: "session-search-q", type: "session-search-type", date: "session-search-date" };
      const el  = document.getElementById(ids[key]);
      if (el) el.value = "";
      await Sessions.commitSearch();
    },

    /** Toggle the search panel open/closed. */
    toggleSearch() {
      _searchOpen = !_searchOpen;
      const panel  = document.getElementById("session-search-bar");
      const togBtn = document.getElementById("btn-session-search-toggle");
      if (!panel) return;

      if (_searchOpen) {
        panel.hidden = false;
        panel.classList.add("search-panel--open");
        togBtn && togBtn.classList.add("active");
        // Auto-focus the text input
        const inp = document.getElementById("session-search-q");
        if (inp) setTimeout(() => inp.focus(), 30);
      } else {
        panel.classList.remove("search-panel--open");
        togBtn && togBtn.classList.remove("active");
        // After animation finishes, hide panel and reset inputs
        const hadActiveFilter = _filter.q || _filter.date || _filter.type;
        setTimeout(() => {
          panel.hidden = true;
          // Reset DOM inputs
          const qEl  = document.getElementById("session-search-q");
          const dEl  = document.getElementById("session-search-date");
          const tEl  = document.getElementById("session-search-type");
          if (qEl) qEl.value = "";
          if (dEl) dEl.value = "";
          if (tEl) tEl.value = "";
          // Clear filter state
          _filter.q = _filter.date = _filter.type = "";
          // Only re-fetch if a filter was actually active (avoids pointless reload)
          if (hadActiveFilter) Sessions.commitSearch();
        }, 180);
      }
    },

    // kept for compat
    setTab() {},
    /** @deprecated — use commitSearch */
    async search(patch) {
      Object.assign(_filter, patch);
      await Sessions.commitSearch();
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

    renderList() {
      // Sort helper: newest-first by created_at
      const byTime = (a, b) => {
        const ta = a.created_at ? new Date(a.created_at) : 0;
        const tb = b.created_at ? new Date(b.created_at) : 0;
        return tb - ta;
      };

      // ── Apply client-side filter (mirrors server params for instant feedback) ─
      const { q, date, type } = _filter;
      let visible = [..._sessions].sort(byTime);
      if (date) visible = visible.filter(s => (s.created_at || "").startsWith(date));
      if (type) {
        visible = type === "coding"
          ? visible.filter(s => s.agent_profile === "coding")
          : visible.filter(s => s.source === type && s.agent_profile !== "coding");
      }

      // ── Show/hide magnifier button ─────────────────────────────────────
      // Always visible when search panel is open; otherwise hide when < 10 sessions total.
      const togBtn = document.getElementById("btn-session-search-toggle");
      if (togBtn) togBtn.style.display = (_searchOpen || _sessions.length >= 10) ? "" : "none";

      // ── Update filter UI: highlight active selects/date, show/hide clear button ──
      const typeEl      = document.getElementById("session-search-type");
      const dateEl      = document.getElementById("session-search-date");
      const clearAllBtn = document.getElementById("btn-search-clear-all");
      const qClearBtn   = document.getElementById("btn-search-q-clear");
      if (typeEl)      typeEl.dataset.active = _filter.type ? "true" : "false";
      if (dateEl)      dateEl.dataset.active = _filter.date ? "true" : "false";
      const hasFilter = !!(_filter.type || _filter.date);
      if (clearAllBtn) clearAllBtn.hidden = !hasFilter;
      // ✕ inside the input — update based on current q value
      const qEl = document.getElementById("session-search-q");
      if (qClearBtn) qClearBtn.hidden = !(qEl && qEl.value);

      const list = $("session-list");
      list.innerHTML = "";
      if (visible.length === 0) {
        list.innerHTML = `<div class="session-empty">${I18n.t("sessions.empty")}</div>`;
      } else {
        visible.forEach(s => _renderSessionItem(list, s));
      }

      if (_hasMore) list.appendChild(_makeLoadMoreBtn());

      // Scroll active session into view so the sidebar always shows the current session.
      const activeEl = list.querySelector(".session-item.active");
      if (activeEl) activeEl.scrollIntoView({ block: "nearest" });
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
          if (res.ok) {
            // Update local data and re-render immediately.
            // Don't rely on WS session_renamed event — it won't arrive when
            // renaming a non-active session (WS is scoped to the active session).
            Sessions.patch(sessionId, { name: newName });
            Sessions.renderList();
            if (sessionId === Sessions.activeId) {
              const titleEl = document.getElementById("chat-title");
              if (titleEl) titleEl.textContent = newName;
            }
          } else {
            console.error("Rename failed:", await res.text());
          }
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
      _scrollToBottomIfNeeded(messages);
    },

    // Update the last tool-item with a result status tick.
    appendToolResult(result) {
      if (Sessions._liveToolGroup && Sessions._liveLastToolItem) {
        _completeLastToolItem(Sessions._liveToolGroup, result);
        Sessions._liveLastToolItem = null;
      }
    },

    // Append stdout lines to the currently running tool-item.
    // Shows the stdout area automatically on first content.
    appendToolStdout(lines) {
      // Resolve the target tool-item.
      // After a session switch, _liveLastToolItem is null because the messages pane
      // was wiped and re-rendered from history.  In that case fall back to the last
      // .tool-item visible in the DOM — that is the in-flight tool the stdout belongs to.
      let toolItem = Sessions._liveLastToolItem;
      if (!toolItem) {
        const messages = $("messages");
        if (messages) {
          const items = messages.querySelectorAll(".tool-item");
          if (items.length > 0) toolItem = items[items.length - 1];
        }
      }

      // If no tool-item exists yet, history is still loading via HTTP.
      // Buffer the lines and they will be flushed once _fetchHistory appends its fragment.
      if (!toolItem) {
        if (!_pendingStdoutLines) _pendingStdoutLines = [];
        _pendingStdoutLines.push(...lines);
        return;
      }

      _applyStdoutToItem(toolItem, lines);
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
      if (!container) _scrollToBottomIfNeeded(messages); // only auto-scroll for live events
    },

    // Collapse the live tool group (call when AI starts responding or task ends).
    collapseToolGroup() {
      if (Sessions._liveToolGroup) {
        _collapseToolGroup(Sessions._liveToolGroup);
        Sessions._liveToolGroup    = null;
        Sessions._liveLastToolItem = null;
      }
    },

    appendMsg(type, html, { time } = {}) {
      // Starting a new assistant/user/info message: close any open tool group
      if (type !== "tool") Sessions.collapseToolGroup();

      const messages = $("messages");
      const el = document.createElement("div");
      el.className = `msg msg-${type}`;
      // Assistant messages are rendered as Markdown (raw text → HTML via marked).
      // All other types receive pre-escaped HTML strings and are inserted directly.
      el.innerHTML = type === "assistant" ? _renderMarkdown(html) : html;
      if (type === "user" && time) _appendMsgTime(el, time);
      messages.appendChild(el);
      // User messages: force scroll to bottom (user just sent a message)
      // Assistant/info: conditional scroll (preserve position if user is viewing history)
      if (type === "user") {
        messages.scrollTop = messages.scrollHeight;
      } else {
        _scrollToBottomIfNeeded(messages);
      }
    },

    appendInfo(text) {
      Sessions.collapseToolGroup();
      const messages = $("messages");
      const el = document.createElement("div");
      el.className   = "msg msg-info";
      el.textContent = text;
      messages.appendChild(el);
      _scrollToBottomIfNeeded(messages);
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
      _scrollToBottomIfNeeded(messages);
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
      _scrollToBottomIfNeeded(messages);
    },

    clearProgress() {
      if (Sessions._progressEl) {
        Sessions._progressEl.remove();
        Sessions._progressEl = null;
      }
    },

    _progressEl: null,

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
