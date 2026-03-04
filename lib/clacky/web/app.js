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
    case "subscribed": {
      Sessions.appendInfo("Connected to session");
      // If this session was created by Tasks.run(), fire the agent now that
      // we're guaranteed to receive its broadcasts.
      const pendingId = Sessions.takePendingRunTask();
      if (pendingId && pendingId === ev.session_id) {
        WS.send({ type: "run_task", session_id: pendingId });
      }
      break;
    }

    case "session_update": {
      // Payload: { type: "session_update", session: { id, name, status, ... } }
      const updated = ev.session;
      if (!updated) break;
      Sessions.patch(updated.id, updated);
      Sessions.renderList();
      if (updated.id === Sessions.activeId) {
        Sessions.updateStatusBar(updated.status);
      }
      // When a session finishes, refresh tasks (Agent may have created new ones)
      if (updated.status === "idle") Tasks.load();
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

// ── Image attachments ─────────────────────────────────────────────────────
// Pending images: array of { dataUrl, name } objects
const _pendingImages = [];
const MAX_IMAGE_SIZE = 5 * 1024 * 1024;  // 5 MB — same limit as CLI
const ACCEPTED_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];

/** Read a File object as a data: URL and add it to the pending list. */
function _addImageFile(file) {
  if (!ACCEPTED_TYPES.includes(file.type)) {
    alert(`Unsupported image type: ${file.type}\nSupported: PNG, JPEG, GIF, WEBP`);
    return;
  }
  if (file.size > MAX_IMAGE_SIZE) {
    alert(`Image too large: ${file.name} (max 5 MB)`);
    return;
  }
  const reader = new FileReader();
  reader.onload = e => {
    _pendingImages.push({ dataUrl: e.target.result, name: file.name });
    _renderImagePreviews();
  };
  reader.readAsDataURL(file);
}

/** Render thumbnail strip above the input bar. */
function _renderImagePreviews() {
  const strip = $("image-preview-strip");
  strip.innerHTML = "";
  if (_pendingImages.length === 0) {
    strip.style.display = "none";
    return;
  }
  strip.style.display = "flex";
  _pendingImages.forEach((img, idx) => {
    const item = document.createElement("div");
    item.className = "img-preview-item";
    item.title = img.name;
    const thumbnail = document.createElement("img");
    thumbnail.src = img.dataUrl;
    thumbnail.alt = img.name;
    const removeBtn = document.createElement("button");
    removeBtn.className = "img-preview-remove";
    removeBtn.textContent = "✕";
    removeBtn.title = "Remove";
    removeBtn.addEventListener("click", () => {
      _pendingImages.splice(idx, 1);
      _renderImagePreviews();
    });
    item.appendChild(thumbnail);
    item.appendChild(removeBtn);
    strip.appendChild(item);
  });
}

// ── Send message ──────────────────────────────────────────────────────────
let _sending = false;   // debounce guard — prevents double-send on rapid clicks

function sendMessage() {
  if (_sending) return;
  const input   = $("user-input");
  const content = input.value.trim();
  if (!content && _pendingImages.length === 0) return;
  if (!Sessions.activeId) return;

  _sending = true;

  // Build display HTML for the user bubble
  let bubbleHtml = content ? escapeHtml(content) : "";
  if (_pendingImages.length > 0) {
    const thumbs = _pendingImages
      .map(img => `<img src="${img.dataUrl}" alt="${escapeHtml(img.name)}" class="msg-image-thumb">`)
      .join("");
    bubbleHtml = thumbs + (bubbleHtml ? "<br>" + bubbleHtml : "");
  }
  Sessions.appendMsg("user", bubbleHtml);

  // Collect image data URLs and clear pending list
  const images = _pendingImages.map(img => img.dataUrl);
  _pendingImages.length = 0;
  _renderImagePreviews();

  WS.send({ type: "message", session_id: Sessions.activeId, content, images });
  input.value        = "";
  input.style.height = "auto";
  setTimeout(() => { _sending = false; }, 300);
}

// ── Panel switching helpers ───────────────────────────────────────────────
// All top-level panels in #main
const PANELS = ["welcome", "task-detail-panel", "chat-panel", "settings-panel"];

function showPanel(id) {
  PANELS.forEach(p => {
    const el = $(p);
    if (el) el.style.display = (p === id) ? "" : "none";
  });
}

// Open Settings: deselect session, show settings panel, load config
function openSettings() {
  Sessions.deselect();
  $("btn-settings").classList.add("active");
  showPanel("settings-panel");
  Settings.open();
}

// Called by Sessions / Tasks when they take over the main area
function closeSettings() {
  $("btn-settings").classList.remove("active");
}

// Expose so sessions.js / tasks.js can call closeSettings when navigating away
window._closeSettings = closeSettings;

// ── DOM event listeners ───────────────────────────────────────────────────
$("btn-new-session").addEventListener("click", () => { closeSettings(); Sessions.create(); });
$("btn-welcome-new").addEventListener("click", () => { closeSettings(); Sessions.create(); });
$("btn-send").addEventListener("click", sendMessage);
$("btn-interrupt").addEventListener("click", () =>
  WS.send({ type: "interrupt", session_id: Sessions.activeId })
);

// Click-to-upload: clicking 📎 opens the hidden file picker
$("btn-attach").addEventListener("click", () => $("image-file-input").click());
$("image-file-input").addEventListener("change", e => {
  Array.from(e.target.files).forEach(_addImageFile);
  e.target.value = "";  // reset so same file can be re-selected
});

// Drag-and-drop onto the input area
const inputArea = document.getElementById("input-area");
inputArea.addEventListener("dragover", e => {
  e.preventDefault();
  inputArea.classList.add("drag-over");
});
inputArea.addEventListener("dragleave", e => {
  if (!inputArea.contains(e.relatedTarget)) inputArea.classList.remove("drag-over");
});
inputArea.addEventListener("drop", e => {
  e.preventDefault();
  inputArea.classList.remove("drag-over");
  const files = Array.from(e.dataTransfer.files).filter(f => ACCEPTED_TYPES.includes(f.type));
  if (files.length === 0) return;
  files.forEach(_addImageFile);
});

// Ctrl+V / Cmd+V paste from clipboard
$("user-input").addEventListener("paste", e => {
  const items = Array.from(e.clipboardData?.items || []);
  const imageItems = items.filter(it => it.kind === "file" && ACCEPTED_TYPES.includes(it.type));
  if (imageItems.length === 0) return;
  // Prevent the default paste behaviour only when there are images
  e.preventDefault();
  imageItems.forEach(it => _addImageFile(it.getAsFile()));
});

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

// ── Settings button ───────────────────────────────────────────────────────
$("btn-settings").addEventListener("click", openSettings);

// ── Boot ──────────────────────────────────────────────────────────────────
Settings.init();
WS.connect();
Tasks.load();
