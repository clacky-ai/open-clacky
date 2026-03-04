// ── app.js — Main entry point ──────────────────────────────────────────────
//
// Coordinates WS, Sessions, and Tasks modules.
// Handles WS event dispatch and wires up all DOM event listeners.
//
// Load order (in index.html):
//   ws.js → sessions.js → tasks.js → app.js
// ─────────────────────────────────────────────────────────────────────────

// ── DOM helper (shared by all modules loaded after this) ──────────────────
const $ = id => document.getElementById(id);

// Guard: auto-select the first session only once on initial page load.
// Prevents repeated subscribe/Connected loops triggered by subsequent
// session_list events (e.g. from subscribe responses, session updates, etc.)
let _initialSelectDone = false;

// ── Utilities (shared) ────────────────────────────────────────────────────
function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// ── Confirmation modal ────────────────────────────────────────────────────
function showConfirmModal(confId, message) {
  $("modal-message").textContent   = message;
  $("modal-overlay").style.display = "flex";

  const answer = result => {
    $("modal-overlay").style.display = "none";
    WS.send({ type: "confirmation", session_id: Sessions.activeId, id: confId, result });
  };
  $("modal-yes").onclick = () => answer("yes");
  $("modal-no").onclick  = () => answer("no");
}

// ── WS event dispatcher ───────────────────────────────────────────────────
WS.onEvent(ev => {
  switch (ev.type) {

    // ── Internal WS lifecycle ──────────────────────────────────────────
    case "_ws_connected":
      // WS module already sent list_sessions; nothing else needed here
      break;

    case "_ws_disconnected":
      // Could show a reconnecting banner if desired
      break;

    // ── Session list ───────────────────────────────────────────────────
    case "session_list": {
      Sessions.setAll(ev.sessions || []);
      Sessions.renderList();

      // If active session was deleted, go to welcome
      if (Sessions.activeId && !Sessions.find(Sessions.activeId)) {
        Sessions.deselect();
      }


      break;
    }

    // ── Session lifecycle ──────────────────────────────────────────────
    case "subscribed":
      Sessions.appendInfo("Connected to session");
      break;

    case "session_update": {
      Sessions.patch(ev.session_id, { status: ev.status });
      Sessions.renderList();
      if (ev.session_id === Sessions.activeId) {
        Sessions.updateStatusBar(ev.status);
      }
      // When a session finishes, refresh tasks (Agent may have created new ones)
      if (ev.status === "idle") Tasks.load();
      break;
    }

    case "session_deleted":
      Sessions.remove(ev.session_id);
      if (ev.session_id === Sessions.activeId) Sessions.deselect();
      Sessions.renderList();
      break;

    // ── Chat messages ──────────────────────────────────────────────────
    case "assistant_message":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendMsg("assistant", escapeHtml(ev.content));
      break;

    case "tool_call":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      const argStr = typeof ev.args === "object"
        ? JSON.stringify(ev.args, null, 2)
        : String(ev.args || "");
      Sessions.appendMsg(
        "tool",
        `<span class="tool-name">⚙ ${escapeHtml(ev.name)}</span>\n${escapeHtml(argStr)}`
      );
      break;

    case "tool_result":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendMsg("tool", `↩ ${escapeHtml(String(ev.result || "").slice(0, 300))}`);
      break;

    case "tool_error":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendMsg("error", `Tool error: ${escapeHtml(ev.error)}`);
      break;

    case "progress":
      if (ev.session_id !== Sessions.activeId) break;
      if (ev.status === "start") Sessions.showProgress(ev.message || "Thinking…");
      else Sessions.clearProgress();
      break;

    case "complete":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendInfo(`✓ Done — ${ev.iterations} iteration(s), $${(ev.cost || 0).toFixed(4)}`);
      break;

    case "request_confirmation":
      if (ev.session_id !== Sessions.activeId) break;
      showConfirmModal(ev.id, ev.message);
      break;

    case "interrupted":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendInfo("Interrupted.");
      break;

    // ── Info / errors ──────────────────────────────────────────────────
    case "info":
      Sessions.appendInfo(ev.message);
      break;

    case "warning":
      Sessions.appendInfo("⚠ " + ev.message);
      break;

    case "success":
      Sessions.appendMsg("success", "✓ " + escapeHtml(ev.message));
      break;

    case "error":
      if (!ev.session_id || ev.session_id === Sessions.activeId)
        Sessions.appendMsg("error", escapeHtml(ev.message));
      break;
  }
});

// ── Send message ──────────────────────────────────────────────────────────
let _sending = false;   // debounce guard — prevents double-send on rapid clicks

function sendMessage() {
  if (_sending) return;
  const input   = $("user-input");
  const content = input.value.trim();
  if (!content || !Sessions.activeId) return;

  _sending = true;
  Sessions.appendMsg("user", escapeHtml(content));
  WS.send({ type: "message", session_id: Sessions.activeId, content });
  input.value        = "";
  input.style.height = "auto";
  // Reset guard on next microtask so accidental double-clicks are swallowed
  // but a legitimate second message after the first completes works fine.
  setTimeout(() => { _sending = false; }, 300);
}

// ── DOM event listeners ───────────────────────────────────────────────────
$("btn-new-session").addEventListener("click", () => Sessions.create());
$("btn-welcome-new").addEventListener("click", () => Sessions.create());
$("btn-send").addEventListener("click", sendMessage);
$("btn-interrupt").addEventListener("click", () =>
  WS.send({ type: "interrupt", session_id: Sessions.activeId })
);

// Track IME composition state — prevents Enter from submitting mid-composition
// (e.g. typing Chinese/Japanese where Enter confirms a character, not sends)
let _composing = false;
$("user-input").addEventListener("compositionstart", () => { _composing = true; });
$("user-input").addEventListener("compositionend",   () => { _composing = false; });

$("user-input").addEventListener("keydown", e => {
  if (e.key === "Enter" && !e.shiftKey && !_composing) {
    e.preventDefault();
    sendMessage();
  }
});

$("user-input").addEventListener("input", () => {
  const el = $("user-input");
  el.style.height = "auto";
  el.style.height = Math.min(el.scrollHeight, 200) + "px";
});

// ── Boot ──────────────────────────────────────────────────────────────────
WS.connect();
Tasks.load();
