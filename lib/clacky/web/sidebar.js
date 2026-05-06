// ── sidebar.js — Left sidebar navigation ──────────────────────────────────
//
// Owns ONLY the left-rail navigation buttons whose sole job is to switch
// the main router view. Any "business action" button that happens to live
// in the sidebar (e.g. "new session") belongs to its own domain module
// (Sessions, Skills, …), not here.
//
// Contract:
//   Sidebar.init()   — attach click handlers. Must be called after DOM ready.
// ──────────────────────────────────────────────────────────────────────────

const Sidebar = (() => {
  function init() {
    // Settings button toggles between "settings" and "welcome" view.
    document.getElementById("btn-settings").addEventListener("click", () => {
      if (Router.current === "settings") {
        Router.navigate("welcome");
      } else {
        Router.navigate("settings");
      }
    });

    // Primary navigation items — each just swaps the current route.
    document.getElementById("tasks-sidebar-item").addEventListener("click", () => Router.navigate("tasks"));
    document.getElementById("skills-sidebar-item").addEventListener("click", () => Router.navigate("skills"));
    document.getElementById("channels-sidebar-item").addEventListener("click", () => Router.navigate("channels"));
    document.getElementById("trash-sidebar-item").addEventListener("click", () => Router.navigate("trash"));
    document.getElementById("profile-sidebar-item").addEventListener("click", () => Router.navigate("profile"));

    // memories-sidebar-item is retained as a hidden legacy placeholder — no click handler.

    // creator-sidebar-item is conditionally rendered (only when user_licensed).
    // This ?. is a legitimate business guard, not defensive padding — the
    // element genuinely may not exist in the DOM for unlicensed users.
    document.getElementById("creator-sidebar-item")?.addEventListener("click", () => Router.navigate("creator"));
  }

  return { init };
})();
