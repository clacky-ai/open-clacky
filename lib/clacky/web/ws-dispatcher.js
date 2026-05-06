// ── WS event dispatcher ───────────────────────────────────────────────────
//
// Consumes events emitted by WS (ws.js) and dispatches them to the right
// business module (Sessions, Tasks, Skills, Channels, Settings, Brand, ...).
//
// Kept as a separate file from ws.js on purpose:
//   - ws.js is a pure transport layer (connect / send / subscribe / reconnect)
//   - this file is the application-level router that knows about every
//     business module. Mixing the two would force ws.js to depend on every
//     other module, breaking layering.
//
// Depends on: WS (ws.js), Sessions, Tasks, Skills, Channels, Settings, Brand,
//             Router, I18n, global $ / escapeHtml / showConfirmModal helpers.
// ─────────────────────────────────────────────────────────────────────────
(function() {
  // Guard: restore hash routing only once after initial session_list arrives.
  let _initialRestoreDone = false;


WS.onEvent(ev => {
  console.log("[DEBUG] WS event received:", ev.type, ev);
  switch (ev.type) {

    // ── Internal WS lifecycle ──────────────────────────────────────────
    case "_ws_connected": {
      const banner = document.getElementById("offline-banner");
      if (banner) banner.style.display = "none";
      const hint = $("ws-disconnect-hint");
      if (hint) hint.style.display = "none";
      break;
    }

    case "_ws_disconnected": {
      const banner = document.getElementById("offline-banner");
      if (banner) {
        banner.textContent = I18n.t("offline.banner");
        banner.style.display = "block";
      }
      // Do NOT force status bar to "idle" here — on a brief WS hiccup the
      // agent may still be running, and reconnect will deliver a fresh
      // session snapshot that patches the real status. Forcing idle here
      // caused stuck UI after reconnect when the snapshot logic wasn't
      // re-asserting status on every reconnect.
      Sessions.clearAllProgress();
      break;
    }

    // ── Session list ───────────────────────────────────────────────────
    case "session_list": {
      Sessions.setAll(ev.sessions || [], !!ev.has_more);
      Sessions.renderList();

      // Restore URL hash once on initial connect; ignore subsequent session_list events.
      // Skip if we are already on a session view (e.g. onboard flow navigated there
      // before WS connected) — restoreFromHash would wrongly redirect to "welcome"
      // because there is no hash set during onboarding.
      if (!_initialRestoreDone) {
        _initialRestoreDone = true;
        if (Router.current !== "session") {
          Router.restoreFromHash();
        }
      } else {
        // If active session was deleted, go to welcome
        if (Sessions.activeId && !Sessions.find(Sessions.activeId)) {
          Router.navigate("welcome");
        }
      }
      break;
    }

    // ── Session lifecycle ──────────────────────────────────────────────
    case "subscribed": {
      // Re-enable send button now that the server has confirmed the subscription.
      $("btn-send").disabled = false;
      $("user-input").focus();
      // If this session was created by Tasks.run(), fire the agent now that
      // we're guaranteed to receive its broadcasts.
      const pendingId = Sessions.takePendingRunTask();
      if (pendingId && pendingId === ev.session_id) {
        WS.send({ type: "run_task", session_id: pendingId });
      }
      // If a slash-command was queued (e.g. /onboard from first-boot flow),
      // send it now — after restoreFromHash has settled — so appendMsg won't be wiped.
      const pendingMsg = Sessions.takePendingMessage();
      if (pendingMsg && pendingMsg.session_id === ev.session_id) {
        Sessions.appendMsg("user", escapeHtml(pendingMsg.content), { time: new Date() });
        WS.send({ type: "message", session_id: pendingMsg.session_id, content: pendingMsg.content });
      }
      break;
    }

    case "session_update": {
      // Two shapes arrive under this type:
      //   (1) Full session object from http_server broadcast_session_update:
      //       { type, session: { id, name, status, total_cost, total_tasks, ... } }
      //   (2) Partial real-time update from web_ui_controller (cost/tasks/status):
      //       { type, session_id, cost?, tasks?, status? }
      let sid, patch;
      if (ev.session) {
        // Shape (1): full session — use as-is
        sid   = ev.session.id;
        patch = ev.session;
      } else {
        // Shape (2): partial update — build patch from top-level fields
        sid   = ev.session_id;
        patch = {};
        if (ev.cost    !== undefined) patch.total_cost     = ev.cost;
        if (ev.tasks   !== undefined) patch.total_tasks    = ev.tasks;
        if (ev.status  !== undefined) patch.status         = ev.status;
        // Latency pushed by Agent after each LLM call (see update_sessionbar).
        // Stored under latest_latency — same field name the HTTP /api/sessions
        // list returns, so updateInfoBar doesn't need to branch on the source.
        if (ev.latency !== undefined) patch.latest_latency = ev.latency;
      }
      if (!sid) break;
      Sessions.patch(sid, patch);
      Sessions.renderList();
      if (sid === Sessions.activeId) {
        const current = Sessions.find(sid);
        if (patch.status !== undefined) Sessions.updateStatusBar(patch.status);
        Sessions.updateInfoBar(current);
        // Update chat title/subtitle in case session was renamed or working_dir changed
        Sessions.updateChatHeader(current);
      }
      // When a session finishes, refresh tasks and skills, and clear any progress state
      if (patch.status === "idle") {
        Tasks.load();
        Skills.load();
        // Clear progress state for this session (even if not currently active)
        Sessions.clearProgress(sid);
      }
      break;
    }

    case "session_renamed": {
      Sessions.patch(ev.session_id, { name: ev.name });
      Sessions.renderList();
      // Title is now shown only in the sidebar; chat-header element was removed.
      break;
    }

    case "session_deleted":
      Sessions.remove(ev.session_id);
      if (ev.session_id === Sessions.activeId) Router.navigate("welcome");
      Sessions.renderList();
      break;

    // ── Chat messages ──────────────────────────────────────────────────
    case "history_user_message":
      // Emitted only during history replay — never from live WS.
      // Rendered by Sessions._fetchHistory; nothing to do here.
      break;

    case "assistant_message":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendMsg("assistant", ev.content);
      break;

    case "tool_call":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendToolCall(ev.name, ev.args, ev.summary);
      break;

    case "tool_result":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendToolResult(ev.result);
      break;

    case "tool_stdout":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendToolStdout(ev.lines);
      break;

    case "tool_error":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendMsg("info", `⚠ Tool error: ${escapeHtml(ev.error)}`);
      break;

    case "token_usage":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendTokenUsage(ev);
      break;

    case "progress":
      console.log("[DEBUG] progress event:", ev);
      if (ev.session_id !== Sessions.activeId) break;
      if (ev.phase === "active" || ev.status === "start") {
        const progress_type = ev.progress_type || "thinking";
        const metadata = ev.metadata || {};
        console.log("[DEBUG] calling showProgress:", { message: ev.message, progress_type, metadata, started_at: ev.started_at });
        Sessions.showProgress(ev.message, progress_type, metadata, ev.started_at || null);
      } else {
        console.log("[DEBUG] calling clearProgress:", ev.message);
        Sessions.clearProgress(ev.message);
      }
      break;

    case "complete":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.collapseToolGroup();
      {
        const costSource = ev.cost_source;
        const costDisplay = (!costSource || costSource === "estimated")
          ? "N/A"
          : `$${(ev.cost || 0).toFixed(4)}`;
        Sessions.appendInfo(`✓ ${I18n.t("chat.done", { n: ev.iterations, cost: costDisplay })}`);
      }
      break;

    case "request_feedback":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.showFeedbackRequest(ev.question, ev.context, ev.options);
      break;

    case "request_confirmation":
      if (ev.session_id !== Sessions.activeId) break;
      showConfirmModal(ev.id, ev.message);
      break;

    case "interrupted":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.collapseToolGroup();
      Sessions.appendInfo(I18n.t("chat.interrupted"));
      break;

    // ── Info / errors ──────────────────────────────────────────────────
    case "info":
      Sessions.appendInfo(ev.message);
      break;

    case "warning":
      // Optimize retry messages for better UX
      const friendlyWarning = _transformRetryWarning(ev.message);
      if (friendlyWarning) {
        Sessions.appendInfo(friendlyWarning);
      }
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


})();
