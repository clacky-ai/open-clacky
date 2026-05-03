// i18n.js — Lightweight internationalization module
// Supports English (en) and Chinese (zh).
// Language is persisted in localStorage under the key "clacky-lang".
// Usage:
//   I18n.t("key")            → translated string
//   I18n.t("key", {name:"X"})→ translated string with {{name}} replaced
//   I18n.applyAll()          → apply data-i18n / data-i18n-placeholder to DOM

const I18n = (() => {
  const STORAGE_KEY = "clacky-lang";
  const DEFAULT_LANG = "en";

  // ── Translation dictionary ─────────────────────────────────────────────────
  const TRANSLATIONS = {
    en: {
      // ── Sidebar ──
      "sidebar.chat":     "Chat",
      "sidebar.config":   "Config",
      "sidebar.tasks":    "Task Management",
      "sidebar.skills":   "Skill Management",
      "sidebar.channels": "Channel Management",
      "sidebar.trash":    "File Recall",
      "sidebar.profile":  "Assistant Memory",
      "sidebar.memories": "Memories",
      "sidebar.dataSection": "My Data",
      "sidebar.creator":       "Creator Hub",
      "sidebar.creatorSection": "Creator",
      "sidebar.settings": "Settings",

      // ── Welcome screen ──
      "welcome.title":  "Welcome to {{brand}}",
      "welcome.body":   "Create a new session or select one from the sidebar.",
      "welcome.btn":    "New Session",

      // ── Chat panel ──
      "chat.status.idle":    "idle",
      "chat.status.running": "running",
      "chat.status.error":   "error",
      "chat.input.placeholder": "Message… (Enter to send, Shift+Enter for newline)",
      "chat.btn.send":       "Send",
      "chat.thinking":       "Thinking…",
      "chat.retrying":       "Retrying",
      "chat.history_load_failed": "Could not load history",
      "chat.history_start":       "No more history",
      "chat.image_expired": "Expired",
      "chat.done":           "Done — {{n}} iteration(s), ${{cost}}",
      "chat.interrupted":    "Interrupted.",
      "chat.feedback_hint":  "Or type your own answer below ↓",
      "chat.newMessageHint": "New messages ↓",
      "chat.retry":          "Retry",
      "chat.copy":           "Copy",
      "chat.copied":         "Copied",
      "chat.empty.title":    "Start the conversation",
      "chat.empty.subtitle": "Ask anything, or use a skill to get going.",
      "chat.empty.tip1":     "Type / to browse skills",
      "chat.empty.tip2":     "Attach images, PDFs, or docs for context",
      "chat.empty.tip3":     "Shift+Enter for a new line",

      // ── Session list ──
      "sessions.empty":         "No sessions yet",
      "sessions.confirmDelete": "Delete session \"{{name}}\"?\nThis cannot be undone.",
      "sessions.meta":          "{{tasks}} tasks · ${{cost}}",
      "sessions.metaTasks":     "{{n}} tasks",
      "sessions.deleteTitle":   "Delete session",
      "sessions.createError":   "Error: ",
      "sessions.dirNotEmpty":   "Directory already exists and is not empty.",
      "sessions.export.tooltip": "Download session files (session.json + chunks) for debugging",
      "sessions.export.failed":  "Failed to download session",
      "sessions.actions.tooltip":      "Click for session actions",
      "sessions.actions.download":     "Download session files",
      "sessions.actions.downloadHint": "for debugging",
      "sessions.thinking":      "Thinking…",
      "sessions.default_name":  "Session {{n}}",
      "sessions.badge.cron":    "Auto",
      "sessions.badge.channel": "Channel",
      "sessions.badge.coding":  "Coding",
      "sessions.badge.setup":   "Setup",
      "sessions.newSession":    "+ New Session",
      "sessions.actions.pin":   "Pin",
      "sessions.actions.unpin": "Unpin",
      "sessions.actions.rename": "Rename",
      "sessions.actions.delete": "Delete",
      "sessions.newSessionAdvanced": "More Options",
      "sessions.loadMore":      "Load more sessions",
      "sessions.loadingMore":   "Loading…",
      "sessions.search.placeholder": "Search sessions…",
      "sessions.search.typeAll":     "All types",
      "sessions.search.typeManual":  "Default",
      "sessions.search.typeCron":    "Scheduled",
      "sessions.search.typeChannel": "Channel",
      "sessions.search.typeCoding":  "Coding",
      "sessions.search.typeSetup":   "Setup",

      // ── Modal ──
      "modal.yes": "Yes",
      "modal.no":  "No",
      "modal.ok": "OK",
      "modal.cancel": "Cancel",

      // ── Auth ──
      "auth.accessKeyRequired": "Access key required:",
      "auth.rateLimited": "Too many failed attempts. Please try again in {{seconds}} seconds.",

      // ── New Session Modal ──
      "sessions.modal.title":       "Create New Session",
      "sessions.modal.agent":       "Agent",
      "sessions.modal.agent.general": "General",
      "sessions.modal.agent.coding":  "Coding",
      "sessions.modal.name":         "Session Name",
      "sessions.modal.name.placeholder": "Leave empty to auto-generate",
      "sessions.modal.model":        "Model",
      "sessions.modal.directory":    "Working Directory",
      "sessions.modal.directory.placeholder": "~/clacky_workspace",
      "sessions.modal.initProject":  "Initialize full-stack project (/new)",
      "sessions.modal.create":       "Create Session",

      // ── Offline banner ──
      "offline.banner":           "Server disconnected — reconnecting…",
      "chat.disconnected.hint":   "Server disconnected. Please wait for reconnection.",

      // ── Version / Upgrade ──
      "upgrade.desc":              "A new version is available. It will install in the background — you can keep using the app.",
      "upgrade.btn.upgrade":       "Upgrade Now",
      "upgrade.btn.cancel":        "Cancel",
      "upgrade.btn.restart":       "↻ Restart Now",
      "upgrade.installing":        "Installing…",
      "upgrade.done":              "Upgrade complete!",
      "upgrade.failed":            "Upgrade failed. Try again or run manually: gem update openclacky",
      "upgrade.reconnecting":      "Restarting server…",
      "upgrade.restart.success":   "✓ Restarted successfully!",
      "upgrade.tooltip.upgrading":    "Upgrading — click to see progress",
      "upgrade.tooltip.new":         "v{{latest}} available — click to upgrade",
      "upgrade.tooltip.ok":          "v{{current}} (up to date)",
      "upgrade.tooltip.needs_restart": "Upgrade complete — click to restart",
      "upgrade.tooltip.done":        "Restarted successfully",

      // ── Tasks panel ──
      "tasks.title":          "Scheduled Tasks",
      "tasks.subtitle":       "Manage and schedule automated tasks for your assistant",
      "tasks.btn.create":     "Create Task",
      "tasks.btn.createTask": "Create Task",
      "tasks.empty":          "(empty)",
      "tasks.noScheduled":    "No scheduled tasks.",
      "tasks.noTasks":        "No tasks",
      "tasks.count":          "{{n}} task(s)",
      "tasks.manual":         "Manual",
      "tasks.col.name":       "Name",
      "tasks.col.schedule":   "Schedule",
      "tasks.col.task":       "Task",
      "tasks.btn.run":        "Run",
      "tasks.btn.edit":       "Edit",
      "tasks.btn.pause":      "Pause",
      "tasks.btn.resume":     "Resume",
      "tasks.paused":         "Paused",
      "tasks.toggleError":    "Error updating task.",
      "tasks.runError":       "Error: ",
      "tasks.sessionError":   "Error creating session: ",
      "tasks.confirmDelete":  "Delete task \"{{name}}\"?",
      "tasks.deleteError":    "Error deleting task.",
      "tasks.label.active":   "Tasks",
      "tasks.label.none":     "No tasks",

      // ── Skills panel ──
      "skills.title":               "Skills",
      "skills.subtitle":            "Extend your assistant's capabilities with custom skills",

      // ── Creator panel ──
      "creator.title":    "Creator Hub",
      "creator.subtitle": "Manage and publish your skills to the platform",
      "creator.loading":  "Loading…",

      "creator.section.cloud":     "Cloud Skills",
      "creator.section.cloudHint": "Published to the platform",
      "creator.section.local":     "Local Skills",
      "creator.section.localHint": "Ready to publish",
      "creator.section.new":       "Create New Skill",

      "creator.cloud.empty": "No skills published yet.",
      "creator.local.empty": "All local skills are already published.",

      "creator.badge.published":   "Published",
      "creator.badge.unpublished": "Not published",

      "creator.changed":         "Has local changes",
      "creator.hasLocalChanges": "Local SKILL.md is newer than the last upload",
      "creator.downloads":       "Downloads",

      "creator.btn.publish":   "Publish",
      "creator.btn.update":    "Update",
      "creator.btn.upToDate":  "Up to date",
      "creator.btn.iterate":   "Iterate",
      "creator.iterate.prompt": "Update skill:",

      "creator.shadow.label":   "Local override",
      "creator.shadow.tooltip": "Local copy shadows a same-named brand skill",

      "creator.newSkill.label": "Create a new skill with /skill-creator",
      "creator.promo.text": "Publish your skills & build your own brand on OpenClacky.",
      "creator.promo.link": "Learn more →",
      "creator.cloud.locked": "Brand license required to publish cloud skills.",

      // ── Creator trash ──
      "trash.title":               "File Recall",
      "trash.subtitle":            "Files the agent moved to trash across all projects. Recall them back to where they were, or clear the ones you don't need.",
      "trash.refresh":     "Refresh",
      "trash.emptyOld":    "Empty >7 days",
      "trash.emptyOrphans":"Clean orphans",
      "trash.emptyAll":    "Empty all",
      "trash.empty":       "Nothing in the trash.",
      "trash.loading":     "Loading trash…",
      "trash.summary":     "{{count}} file(s), {{size}}",
      "trash.summaryOrphans": "{{count}} orphan(s)",
      "trash.orphan":      "orphan",
      "trash.orphanHint":  "Original project directory no longer exists (likely a test temp dir). Safe to permanently delete.",
      "trash.noOrphans":   "No orphan trash entries detected.",
      "trash.project":     "Project",
      "trash.deletedAt":   "Deleted",
      "trash.restore":     "Restore",
      "trash.delete":      "Delete",
      "trash.restoreOk":   "Restored: {{path}}",
      "trash.restoreFail": "Restore failed: {{msg}}",
      "trash.confirmDeleteOne":    "Permanently delete \"{{name}}\"?\nThis cannot be undone.",
      "trash.confirmEmptyOld":     "Permanently delete all trashed files older than 7 days?\nThis cannot be undone.",
      "trash.confirmEmptyAll":     "Permanently delete ALL trashed files across every project?\nThis cannot be undone.",
      "trash.confirmEmptyOrphans": "Permanently delete {{count}} orphan trash entries whose original project directory is gone?\nThis cannot be undone.",
      "trash.emptied":     "Permanently deleted {{count}} file(s), freed {{size}}.",
      "trash.orphansCleaned": "Cleaned {{count}} orphan entries, freed {{size}}. ({{failed}} failed)",
      "trash.nothingOld":  "No files older than 7 days.",

      // ── Profile (unified read-only view of USER.md / SOUL.md / memories) ──
      "profile.title":         "Assistant Memory",
      "profile.subtitle":      "A window into the assistant's inner life: who it is, who you are, and what it remembers about your work together.",
      "profile.whoIAm":        "Who I am",
      "profile.whoYouAre":     "Who you are",
      "profile.statusDefault": "Using built-in default",
      "profile.statusCustom":  "Custom override active",
      "profile.loadFail":      "Failed to load",
      "profile.emptyContent":  "(empty)",

      // Profile tabs
      "profile.tab.soul":        "Soul",
      "profile.tab.user":        "User",
      "profile.tab.memories":    "Memories",

      // Per-tab curate actions
      "profile.soul.curateHint": "Not quite right? Let the assistant curate this through a short conversation.",
      "profile.soul.curateBtn":  "Have the assistant curate this",
      "profile.user.curateHint": "Changed jobs? Picked up new interests? Let the assistant update your profile.",
      "profile.user.curateBtn":  "Have the assistant update this",
      "profile.curateFail":      "Could not start the curation session",
      "profile.curateName.soul": "Curate soul",
      "profile.curateName.user": "Curate profile",

      // Legacy update keys — retained for backward compat, no longer used by UI.
      "profile.update":          "Update profile",
      "profile.updateFail":      "Could not start the update session",
      // Legacy editor keys (still referenced by old tests / translations).
      "profile.user.placeholder": "Tell the assistant about yourself — name, role, preferences, working style…",
      "profile.soul.placeholder": "Describe the assistant's personality — tone, values, communication style…",
      "profile.save":          "Save",
      "profile.reset":         "Reset to default",
      "profile.savedOk":       "Saved ✓",
      "profile.resetOk":       "Reset to default ✓",
      "profile.saveFail":      "Save failed",
      "profile.confirmReset":  "Clear your custom override and fall back to the built-in default?",

      // ── Memories (shown inside Profile panel) ──
      "memories.title":         "Memories",
      "memories.subtitle":      "Long-term memories stored under ~/.clacky/memories/. Most recent first. Use \"Curate\" to let the assistant tidy a memory, or \"Delete\" to drop one.",
      "memories.curate":        "Curate",
      "memories.curateTitle":   "Open a session and let the assistant tidy this memory with you",
      "memories.curateFail":    "Could not start a memory session",
      "memories.curateName":    "Curate memory",
      "memories.delete":        "Delete",
      "memories.deleteTitle":   "Delete this memory",
      "memories.deleteFail":    "Delete failed",
      "memories.confirmDelete": "Delete memory \"{{name}}\"?\nIt will be moved to File Recall and can still be recovered from there.",
      "memories.expandTitle":   "Show full content",
      "memories.reloadList":    "↻ Reload",
      "memories.loading":       "Loading…",
      "memories.empty":         "No memories yet. The assistant will create them as you work.",
      "memories.emptyHint":     "",
      "memories.summary":       "{{count}} memory file(s)",
      // Legacy keys — kept for compatibility with any external callers.
      "memories.refresh":       "Curate",
      "memories.refreshTitle":  "Open a session and let the assistant tidy this memory with you",
      "memories.refreshFail":   "Could not start a memory session",
      "memories.new":           "+ New Memory",
      "memories.edit":          "Edit",
      "memories.save":          "Save",
      "memories.cancel":        "Cancel",
      "memories.filenamePh":    "topic-name.md",
      "memories.contentPh":     "Markdown content with optional YAML frontmatter…",
      "memories.filenameRequired": "Filename is required (e.g. topic-name.md).",

      "skills.btn.new":             "New Skill",
      "skills.btn.create":          "Create",
      "skills.btn.import":          "Import",
      "skills.import.placeholder":  "Paste ZIP or GitHub URL…",
      "skills.import.install":      "Install",
      "skills.tab.my":              "My Skills",
      "skills.tab.brand":           "Brand Skills",
      "skills.empty":               "No skills loaded.",
      "skills.empty.createBtn":     "Create a new skill with /skill-creator",
      "skills.noSkills":            "No skills",
      "skills.count":               "{{n}} skill(s)",
      "skills.loading":             "Loading…",
      "skills.brand.loadFailed":    "Failed to load brand skills.",
      "skills.brand.empty":         "No brand skills available for your license.",
      "skills.brand.needsActivation": "Activate your license to access brand skills.",
      "skills.brand.activateBtn":   "Activate License",
      "skills.brand.btn.install":   "Install",
      "skills.brand.btn.update":    "Update",
      "skills.brand.btn.installing":"Installing…",
      "skills.brand.btn.use":       "Use",
      "skills.brand.private":       "Private",
      "skills.brand.privateTip":    "Private — licensed to your organization",
      "skills.brand.installFailed": "Install failed: ",
      "skills.brand.unknownError":  "unknown error",
      "skills.brand.networkError":  "Network error during install.",
      "skills.brand.networkRetry":  "Connection timed out. The server may be slow — please try again in a moment.",
      "skills.brand.warning.remote_unavailable": "Could not reach the license server. Showing locally installed skills only.",
      "skills.badge.system":        "System",
      "skills.badge.custom":        "Custom",
      "skills.badge.invalid":       "Invalid",
      "skills.btn.use":             "Use",
      "skills.filter.showSystem":    "Show system skills",
      "skills.filter.showSystemShort": "Show System",
      "skills.systemDisabledTip":   "System skills cannot be disabled",
      "skills.invalid.reason":      "This skill has an invalid configuration and cannot be used.",
      "skills.invalid.toggleTip":   "Invalid skills cannot be enabled",
      "skills.warning.tooltip":     "This skill has a configuration issue but is still usable.\nReason: {{reason}}",
      "skills.toggle.disable":      "Disable skill",
      "skills.toggle.enable":       "Enable skill",
      "skills.toggle.disableDesc":  "AI can auto-invoke. Disable to prevent auto-triggering (manual use still available)",
      "skills.toggle.enableDesc":   "AI cannot auto-invoke. Enable to allow auto-triggering",
      "skills.toggleError":         "Error: ",
      "skills.ac.empty":            "No skills available",
      "skills.upload.uploading":    "Uploading…",
      "skills.upload.uploaded":     "Uploaded",
      "skills.upload.upload":       "Upload",
      "skills.upload.failed":       "Failed",
      "skills.upload.publishTip":   "Publish to cloud",
      "skills.btn.refresh":         "Refresh",

      // ── Channels panel ──
      "channels.title":           "Channels",
      "channels.subtitle":        "Connect IM platforms so your users can chat with the assistant via Feishu, WeCom or Weixin",
      "channels.loading":         "Loading…",
      "channels.badge.running":         "Running",
      "channels.badge.enabled":         "Enabled",
      "channels.badge.disabled":        "Not configured",
      "channels.badge.notConfigured":   "Not configured",
      "channels.hint.running":          "Adapter is running and accepting messages from users",
      "channels.hint.enabled":          "⚠ Enabled but not running — the adapter may have failed to connect. Run Diagnostics to investigate.",
      "channels.hint.enabledNotRunning":"Enabled but not running — the adapter may have failed to connect. Run Diagnostics to investigate.",
      "channels.hint.idle":             "Not configured yet. Click \"Set Up with Agent\" to get started.",
      "channels.hint.notConfigured":    "Not configured yet. Click \"Set Up with Agent\" to get started.",
      "channels.btn.test":        "Diagnostics",
      "channels.btn.setup":       "Set Up with Agent",
      "channels.btn.reconfig":    "Reconfigure",
      "channels.btn.reconfigure": "Reconfigure",
      "channels.loadError":       "Failed to load channels: {{msg}}",
      "channels.sessionError":    "unknown",
      "channels.noSession":       "No session returned",
      "channels.feishu.desc":     "Connect via Feishu open platform WebSocket long connection",
      "channels.wecom.desc":      "Connect via WeCom intelligent robot WebSocket",
      "channels.weixin.desc":     "Connect via WeChat iLink bot (QR login, HTTP long-poll)",

      // ── Settings panel ──
      "settings.title":           "Settings",
      "settings.models.title":    "AI Models",
      "settings.models.add":      "+ Add Model",
      "settings.models.loading":  "Loading models…",
      "settings.models.error":    "Failed to load: {{msg}}",
      "settings.models.empty":    "No models configured. Click \"+ Add Model\" to add one.",
      "settings.models.badge.default": "Default",
      "settings.models.badge.lite":    "Lite",
      "settings.models.field.quicksetup": "Quick Setup",
      "settings.models.field.model":      "Model",
      "settings.models.field.baseurl":    "Base URL",
      "settings.models.field.apikey":     "API Key",
      "settings.models.field.getApiKey":  "How to get →",
      "settings.models.placeholder.provider": "— Choose provider —",
      "settings.models.placeholder.model":    "e.g. claude-sonnet-4-5",
      "settings.models.placeholder.baseurl":  "https://api.anthropic.com",
      "settings.models.placeholder.apikey":   "sk-…",
      "settings.models.custom":               "Custom",
      "settings.models.btn.save":          "Save",
      "settings.models.btn.saving":        "Saving…",
      "settings.models.btn.saved":         "Saved ✓",
      "settings.models.btn.testing":       "Testing…",
      "settings.models.btn.set_default":   "Set as Default",
      "settings.models.btn.setDefault":    "Set as Default",
      "settings.models.btn.setting":       "Setting…",
      "settings.models.btn.done":          "Done ✓",
      "settings.models.test.ok":           "✓ Connected",
      "settings.models.test.fail":         "✗ Test fail: {{msg}}",
      "settings.models.badge.model":       "Model {{n}}",
      "settings.models.connected":         "Connected",
      "settings.models.testFail":          "Test fail",
      "settings.models.failed":            "Failed",
      "settings.models.saveFailed":        "Save failed",
      "settings.models.setDefaultFailed":  "Failed to set default model",
      "settings.models.errorPrefix":       "Error: ",
      "settings.models.confirmRemove":     "Remove model \"{{model}}\"?",
      "settings.personalize.title":        "Personalize",
      "settings.personalize.desc":         "Re-run the onboarding to update your assistant's personality and user profile (SOUL.md & USER.md).",
      "settings.personalize.btn":          "✨ Re-run Onboard",
      "settings.personalize.btn.starting": "Starting…",
      "settings.personalize.btn.rerun":    "✨ Re-run Onboard",
      "settings.browser.title":            "Browser",
      "settings.browser.desc":             "Connect your browser to enable browser automation.",
      "settings.browser.configured":       "✅ Browser connected",
      "settings.browser.disabled":         "⏸ Browser disabled",
      "settings.browser.btn":              "🌐 Configure Browser",
      "settings.browser.btn.reconfigure":  "🌐 Reconfigure Browser",
      "settings.browser.btn.starting":     "Starting…",
      "settings.brand.title":              "Brand & License",
      "settings.brand.label.brand":        "Brand",
      "settings.brand.label.status":       "Status",
      "settings.brand.label.expires":      "Expires",
      "settings.brand.label.homepage":     "Homepage",
      "settings.brand.label.supportContact": "Support",
      "settings.brand.label.supportQr":    "Tech Support",
      "settings.brand.label.qrHint":       "Scan with your phone camera",
      "settings.brand.btn.change":         "Change Serial Number",
      "settings.brand.btn.unbind":         "Unbind License",
      "settings.brand.confirmRebind":      "Warning: all previously installed brand skills will be deleted and cannot be used. Continue?",
      "settings.brand.confirmUnbind":      "Are you sure you want to unbind this license? All brand skills will be deleted and this device will no longer have access to branded features.",
      "settings.brand.unbindSuccess":      "License unbound successfully.",
      "settings.brand.unbindFailed":       "Failed to unbind license. Please try again.",
      "settings.brand.badge.active":       "Active",
      "settings.brand.badge.warning":      "Expiring Soon",
      "settings.brand.badge.expired":      "Expired",
      "settings.brand.desc":               "Have a serial number from a brand partner? Enter it below to activate branded mode.",
      "settings.brand.descNamed":          "Enter your {{name}} serial number to activate branded mode.",
      "settings.brand.btn.getSerial":      "Get a Serial Number",
      "settings.brand.getSerial.hint":     "Don't have one yet?",
      "settings.brand.btn.activate":       "Activate",
      "settings.brand.btn.activating":     "Activating…",
      "settings.brand.err.no_key":         "Please enter a serial number.",
      "settings.brand.enterKey":           "Please enter a serial number.",
      "settings.brand.invalidFormat":      "Invalid format. Expected: XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX",
      "settings.brand.activated":          "License activated! Brand: {{name}}",
      "settings.brand.activationFailed":   "Activation failed. Please try again.",
      "settings.brand.networkError":       "Network error: ",
      "settings.brand.networkRetry":       "Connection timed out. The server may be slow — please try again in a moment.",

      "settings.lang.title":               "Language",
      "settings.lang.en":                  "English",
      "settings.lang.zh":                  "中文",

      // ── Onboard ──
      "onboard.title":              "Welcome to {{brand}}",
      "onboard.subtitle":           "Let's get you set up in a minute.",
      "onboard.lang.prompt":        "Choose your language",
      "onboard.key.title":          "Connect your AI model",
      "onboard.key.provider":       "Provider",
      "onboard.key.provider.placeholder": "— Choose provider —",
      "onboard.key.model":          "Model",
      "onboard.key.baseurl":        "Base URL",
      "onboard.key.apikey":         "API Key",
      "onboard.key.getApiKey":      "How to get →",
      "onboard.key.btn.test":       "Test & Continue →",
      "onboard.key.btn.back":       "← Back",
      "onboard.provider.custom":    "Custom",
      "onboard.key.testing":        "Testing…",
      "onboard.key.saving":         "Saving…",
      "onboard.soul.title":         "Personalize your assistant",
      "onboard.soul.desc":          "Takes about 30 seconds. You'll be asked two quick questions via interactive cards.",
      "onboard.soul.btn.start":     "Let's go →",
      "onboard.soul.btn.skip":      "Skip for now",

      // ── Brand activation panel ──
      "brand.title":          "Activate Your License",
      "brand.subtitle":       "Enter your serial number to get started.",
      "brand.key.label":      "Serial Number",
      "brand.btn.activate":   "Activate",
      "brand.btn.skip":       "Skip for now",
      "brand.btn.activating": "Activating...",
      "brand.activate.title":    "Activate {{name}}",
      "brand.activate.subtitle": "Enter your serial number to get started.",
      "brand.activate.success":  "License activated successfully!",
      "brand.skip.warning":      "Brand license not activated — brand-exclusive skills are unavailable. You can activate your license anytime in Settings → Brand & License.",

      // ── Brand activation banner ──
      "brand.banner.prompt":      "{{name}} is not activated yet — some features are unavailable.",
      "brand.banner.defaultName": "Your license",
      "brand.banner.action":      "Activate Now",
      "brand.banner.sessionName": "License Activation",

      "header.owner.tooltip":     "Creator — click to open Creator Hub",

      // ── Session info bar / Model switcher benchmark ──
      "sib.bench.btn":        "Benchmark",
      "sib.bench.tooltip":    "Test response latency for every configured model",
      "sib.bench.running":    "Testing…",
      "sib.bench.done":       "done in {{t}}s",
      "sib.bench.failed":     "failed: {{msg}}",
      "sib.bench.latencyTooltip": "TTFT {{ttft}} · tested {{time}}",

      "onboard.welcome":         "Welcome to {{name}}",
    },

    zh: {
      // ── Sidebar ──
      "sidebar.chat":     "对话",
      "sidebar.config":   "配置",
      "sidebar.tasks":    "任务管理",
      "sidebar.skills":   "技能管理",
      "sidebar.channels": "频道管理",
      "sidebar.trash":    "文件召回",
      "sidebar.profile":  "助理记忆",
      "sidebar.memories": "记忆",
      "sidebar.dataSection": "我的数据",
      "sidebar.creator":       "创作者中心",
      "sidebar.creatorSection": "创作者",
      "sidebar.settings": "设置",

      // ── Welcome screen ──
      "welcome.title":  "欢迎使用 {{brand}}",
      "welcome.body":   "新建对话，或从左侧选择一个已有对话。",
      "welcome.btn":    "新建对话",

      // ── Chat panel ──
      "chat.status.idle":    "空闲",
      "chat.status.running": "运行中",
      "chat.status.error":   "出错",
      "chat.input.placeholder": "输入消息…（Enter 发送，Shift+Enter 换行）",
      "chat.btn.send":       "发送",
      "chat.thinking":       "思考中…",
      "chat.retrying":       "正在重试",
      "chat.history_load_failed": "历史记录加载失败",
      "chat.history_start":       "没有更多历史了",
      "chat.image_expired": "已过期",
      "chat.done":           "完成 — {{n}} 步，${{cost}}",
      "chat.interrupted":    "已中断。",
      "chat.feedback_hint":  "或在下方输入框自由作答 ↓",
      "chat.newMessageHint": "有新消息 ↓",
      "chat.retry":          "重试",
      "chat.copy":           "复制",
      "chat.copied":         "已复制",
      "chat.empty.title":    "开始新的对话",
      "chat.empty.subtitle": "直接提问，或用一个 Skill 启动。",
      "chat.empty.tip1":     "输入 / 浏览 Skill",
      "chat.empty.tip2":     "可粘贴或拖入图片、PDF、文档",
      "chat.empty.tip3":     "Shift+Enter 换行",

      // ── Session list ──
      "sessions.empty":         "暂无对话",
      "sessions.confirmDelete": "删除对话「{{name}}」？\n此操作不可撤销。",
      "sessions.meta":          "{{tasks}} 个任务 · ${{cost}}",
      "sessions.metaTasks":     "{{n}} 个任务",
      "sessions.deleteTitle":   "删除对话",
      "sessions.createError":   "错误：",
      "sessions.dirNotEmpty":   "该目录已存在且不为空，请换一个目录名。",
      "sessions.export.tooltip": "下载会话文件（session.json + 归档片段），用于调试",
      "sessions.export.failed":  "下载会话文件失败",
      "sessions.actions.tooltip":      "点击查看会话操作",
      "sessions.actions.download":     "下载会话文件",
      "sessions.actions.downloadHint": "用于调试",
      "sessions.thinking":      "思考中…",
      "sessions.default_name":  "对话 {{n}}",
      "sessions.badge.cron":    "定时",
      "sessions.badge.channel": "频道",
      "sessions.badge.coding":  "Coding",
      "sessions.badge.setup":   "配置",
      "sessions.newSession":    "+ 新会话",
      "sessions.newSessionAdvanced": "更多选项",
      "sessions.loadMore":      "加载更多会话",
      "sessions.actions.pin":   "置顶",
      "sessions.actions.unpin": "取消置顶",
      "sessions.actions.rename": "重命名",
      "sessions.actions.delete": "删除",
      "sessions.loadingMore":   "加载中…",
      "sessions.search.placeholder": "搜索会话…",
      "sessions.search.typeAll":     "全部类型",
      "sessions.search.typeManual":  "默认",
      "sessions.search.typeCron":    "定时",
      "sessions.search.typeChannel": "频道",
      "sessions.search.typeCoding":  "Coding",
      "sessions.search.typeSetup":   "配置",

      // ── Modal ──
      "modal.yes": "确认",
      "modal.no":  "取消",
      "modal.ok": "确定",
      "modal.cancel": "取消",

      // ── Auth ──
      "auth.accessKeyRequired": "请输入访问密钥：",
      "auth.rateLimited": "尝试次数过多，请 {{seconds}} 秒后再试。",

      // ── New Session Modal ──
      "sessions.modal.title":       "创建新会话",
      "sessions.modal.agent":       "助手类型",
      "sessions.modal.agent.general": "通用",
      "sessions.modal.agent.coding":  "编程",
      "sessions.modal.name":         "会话名称",
      "sessions.modal.name.placeholder": "留空自动生成",
      "sessions.modal.model":        "模型",
      "sessions.modal.directory":    "工作目录",
      "sessions.modal.directory.placeholder": "~/clacky_workspace",
      "sessions.modal.initProject":  "初始化全栈项目 (/new)",
      "sessions.modal.create":       "创建会话",

      // ── Offline banner ──
      "offline.banner":           "服务已断开，正在重连…",
      "chat.disconnected.hint":   "服务已断开，请等待重连后再发送。",

      // ── Version / Upgrade ──
      "upgrade.desc":              "有新版本可用，将在后台安装，升级期间可继续使用。",
      "upgrade.btn.upgrade":       "立即升级",
      "upgrade.btn.cancel":        "取消",
      "upgrade.btn.restart":       "↻ 立即重启",
      "upgrade.installing":        "安装中…",
      "upgrade.done":              "升级完成！",
      "upgrade.failed":            "升级失败，请重试或手动执行：gem update openclacky",
      "upgrade.reconnecting":      "服务重启中…",
      "upgrade.restart.success":   "✓ 重启成功！",
      "upgrade.tooltip.upgrading":    "升级中，点击查看进度",
      "upgrade.tooltip.new":         "v{{latest}} 可用，点击升级",
      "upgrade.tooltip.ok":          "v{{current}}（已是最新）",
      "upgrade.tooltip.needs_restart": "升级完成，点击重启",
      "upgrade.tooltip.done":        "重启成功",

      // ── Tasks panel ──
      "tasks.title":          "定时任务",
      "tasks.subtitle":       "管理和调度助手的自动化任务",
      "tasks.btn.create":     "创建任务",
      "tasks.btn.createTask": "创建任务",
      "tasks.empty":          "（空）",
      "tasks.noScheduled":    "暂无定时任务。",
      "tasks.noTasks":        "无任务",
      "tasks.count":          "{{n}} 个任务",
      "tasks.manual":         "手动",
      "tasks.col.name":       "名称",
      "tasks.col.schedule":   "计划",
      "tasks.col.task":       "任务内容",
      "tasks.btn.run":        "立即运行",
      "tasks.btn.edit":       "编辑",
      "tasks.btn.pause":      "暂停",
      "tasks.btn.resume":     "启用",
      "tasks.paused":         "已暂停",
      "tasks.toggleError":    "更新任务失败。",
      "tasks.runError":       "错误：",
      "tasks.sessionError":   "创建对话失败：",
      "tasks.confirmDelete":  "删除任务「{{name}}」？",
      "tasks.deleteError":    "删除任务失败。",
      "tasks.label.active":   "任务",
      "tasks.label.none":     "无任务",

      // ── Skills panel ──
      "skills.title":               "技能",
      "skills.subtitle":            "为助手添加自定义能力",

      // ── Creator panel ──
      "creator.title":    "创作者中心",
      "creator.subtitle": "管理并发布你的技能到平台",
      "creator.loading":  "加载中…",

      "creator.section.cloud":     "云端技能",
      "creator.section.cloudHint": "已发布到平台",
      "creator.section.local":     "本地技能",
      "creator.section.localHint": "准备好可以上传",
      "creator.section.new":       "创建新技能",

      "creator.cloud.empty": "还没有发布任何技能。",
      "creator.local.empty": "所有本地技能均已发布。",

      "creator.badge.published":   "已发布",
      "creator.badge.unpublished": "未发布",

      "creator.changed":         "有本地改动",
      "creator.hasLocalChanges": "本地 SKILL.md 比上次上传更新",
      "creator.downloads":       "下载量",

      "creator.btn.publish":   "发布",
      "creator.btn.update":    "更新",
      "creator.btn.upToDate":  "已是最新",
      "creator.btn.iterate":   "迭代",
      "creator.iterate.prompt": "更新技能：",

      "creator.shadow.label":   "本地优先",
      "creator.shadow.tooltip": "本地版本覆盖了同名的品牌加密技能",

      "creator.newSkill.label": "用 /skill-creator 创建新技能",
      "creator.promo.text": "发布你的 Skill，在 OpenClacky 上打造自己的品牌。",
      "creator.promo.link": "了解更多 →",
      "creator.cloud.locked": "需要品牌授权才能发布云端 Skill。",

      // ── Creator trash ──
      "trash.title":               "文件召回",
      "trash.subtitle":            "AI 代理在各个项目里丢进回收站的文件。可以把它们召回到原位置，或彻底清理不再需要的。",
      "trash.refresh":     "刷新",
      "trash.emptyOld":    "清理 >7 天",
      "trash.emptyOrphans":"清理孤儿",
      "trash.emptyAll":    "全部清空",
      "trash.empty":       "回收站空空如也。",
      "trash.loading":     "加载回收站…",
      "trash.summary":     "共 {{count}} 个文件，{{size}}",
      "trash.summaryOrphans": "其中 {{count}} 条孤儿",
      "trash.orphan":      "孤儿",
      "trash.orphanHint":  "原项目目录已不存在（通常来自测试临时目录）。可以安全地永久删除。",
      "trash.noOrphans":   "未检测到孤儿条目。",
      "trash.project":     "项目",
      "trash.deletedAt":   "删除于",
      "trash.restore":     "恢复",
      "trash.delete":      "删除",
      "trash.restoreOk":   "已恢复：{{path}}",
      "trash.restoreFail": "恢复失败：{{msg}}",
      "trash.confirmDeleteOne":    "永久删除 \"{{name}}\"？\n此操作不可撤销。",
      "trash.confirmEmptyOld":     "永久删除所有超过 7 天的回收站文件？\n此操作不可撤销。",
      "trash.confirmEmptyAll":     "永久删除所有项目的全部回收站文件？\n此操作不可撤销。",
      "trash.confirmEmptyOrphans": "永久删除 {{count}} 条原项目已消失的孤儿条目？\n此操作不可撤销。",
      "trash.emptied":     "已永久删除 {{count}} 个文件，释放 {{size}}。",
      "trash.orphansCleaned": "已清理 {{count}} 条孤儿，释放 {{size}}。（失败 {{failed}}）",
      "trash.nothingOld":  "没有超过 7 天的文件。",

      // ── Profile (助理记忆 — USER.md / SOUL.md / 记忆 统一只读视图) ──
      "profile.title":         "助理记忆",
      "profile.subtitle":      "这是一扇通往 AI 内心的窗口：它是谁、你是谁、以及它在和你共事中记住了什么。",
      "profile.whoIAm":        "我是谁",
      "profile.whoYouAre":     "你是谁",
      "profile.statusDefault": "当前使用内置默认",
      "profile.statusCustom":  "已启用自定义",
      "profile.loadFail":      "加载失败",
      "profile.emptyContent":  "（无内容）",

      // Profile tabs
      "profile.tab.soul":        "助理性格",
      "profile.tab.user":        "主人设定",
      "profile.tab.memories":    "记忆管理",

      // Per-tab curate actions
      "profile.soul.curateHint": "感觉不太对？让助理通过一段简短对话帮你调整。",
      "profile.soul.curateBtn":  "让助理整理性格",
      "profile.user.curateHint": "换工作了？有新兴趣了？让助理帮你更新主人档案。",
      "profile.user.curateBtn":  "让助理更新档案",
      "profile.curateFail":      "无法启动整理会话",
      "profile.curateName.soul": "整理性格",
      "profile.curateName.user": "整理主人档案",

      // 旧 keys（兼容保留）
      "profile.update":          "更新资料",
      "profile.updateFail":      "无法启动更新会话",
      "profile.user.placeholder": "告诉助手你的信息 —— 姓名、角色、偏好、工作风格……",
      "profile.soul.placeholder": "描述助手的性格 —— 语气、价值观、沟通风格……",
      "profile.save":          "保存",
      "profile.reset":         "恢复默认",
      "profile.savedOk":       "已保存 ✓",
      "profile.resetOk":       "已恢复默认 ✓",
      "profile.saveFail":      "保存失败",
      "profile.confirmReset":  "确认清空自定义内容，恢复为内置默认吗？",

      // ── Memories（嵌在助理记忆页） ──
      "memories.title":         "记忆",
      "memories.subtitle":      "保存在 ~/.clacky/memories/ 的长期记忆，按最近更新倒序。点击「整理」让助理帮你打理这条记忆，或点击「删除」丢弃。",
      "memories.curate":        "整理",
      "memories.curateTitle":   "开启一个会话，让助理和你一起整理这条记忆",
      "memories.curateFail":    "无法启动记忆会话",
      "memories.curateName":    "整理记忆",
      "memories.delete":        "删除",
      "memories.deleteTitle":   "删除这条记忆",
      "memories.deleteFail":    "删除失败",
      "memories.confirmDelete": "删除记忆 \"{{name}}\" 吗？\n会先放入「文件召回」，仍可从那里找回。",
      "memories.expandTitle":   "展开完整内容",
      "memories.reloadList":    "↻ 刷新列表",
      "memories.loading":       "加载中…",
      "memories.empty":         "还没有记忆。助手会在后续工作中自动创建。",
      "memories.emptyHint":     "",
      "memories.summary":       "共 {{count}} 条记忆",
      // 旧 keys（兼容保留）
      "memories.refresh":       "整理",
      "memories.refreshTitle":  "开启一个会话，让助理和你一起整理这条记忆",
      "memories.refreshFail":   "无法启动记忆会话",
      "memories.new":           "+ 新建记忆",
      "memories.edit":          "编辑",
      "memories.save":          "保存",
      "memories.cancel":        "取消",
      "memories.filenamePh":    "topic-name.md",
      "memories.contentPh":     "Markdown 内容，可带 YAML frontmatter…",
      "memories.filenameRequired": "请填写文件名（如 topic-name.md）。",

      "skills.btn.new":             "新建技能",
      "skills.btn.create":          "创建",
      "skills.btn.import":          "导入",
      "skills.import.placeholder":  "粘贴 ZIP 或 GitHub 链接…",
      "skills.import.install":      "安装",
      "skills.tab.my":              "我的技能",
      "skills.tab.brand":           "品牌技能",
      "skills.empty":               "暂无技能。",
      "skills.empty.createBtn":     "用 /skill-creator 创建新技能",
      "skills.noSkills":            "无技能",
      "skills.count":               "{{n}} 个技能",
      "skills.loading":             "加载中…",
      "skills.brand.loadFailed":    "加载品牌技能失败。",
      "skills.brand.empty":         "当前授权下暂无品牌技能。",
      "skills.brand.needsActivation": "请激活授权后使用品牌技能。",
      "skills.brand.activateBtn":   "激活授权",
      "skills.brand.btn.install":   "安装",
      "skills.brand.btn.update":    "更新",
      "skills.brand.btn.installing":"安装中…",
      "skills.brand.btn.use":       "使用",
      "skills.brand.private":       "私有",
      "skills.brand.privateTip":    "私有 — 仅授权给您的组织",
      "skills.brand.installFailed": "安装失败：",
      "skills.brand.unknownError":  "未知错误",
      "skills.brand.networkError":  "安装时网络错误。",
      "skills.brand.networkRetry":  "连接超时，服务器可能有点慢，请稍后重试。",
      "skills.brand.warning.remote_unavailable": "无法连接授权服务器，仅显示本地已安装的技能。",
      "skills.badge.system":        "系统",
      "skills.badge.custom":        "自定义",
      "skills.badge.invalid":       "无效",
      "skills.btn.use":             "使用",
      "skills.filter.showSystem":    "显示系统技能",
      "skills.filter.showSystemShort": "显示系统",
      "skills.systemDisabledTip":   "系统技能不可禁用",
      "skills.invalid.reason":      "该技能配置有误，无法使用。",
      "skills.invalid.toggleTip":   "无效技能无法启用",
      "skills.warning.tooltip":     "该技能配置有小问题，但仍然可以正常使用。\n原因：{{reason}}",
      "skills.toggle.disable":      "禁用技能",
      "skills.toggle.enable":       "启用技能",
      "skills.toggle.disableDesc":  "AI 可自动调用。关闭后 AI 不会主动触发（手动使用仍可用）",
      "skills.toggle.enableDesc":   "AI 不会自动调用。开启后允许 AI 主动触发",
      "skills.toggleError":         "错误：",
      "skills.ac.empty":            "暂无可用技能",
      "skills.upload.uploading":    "上传中…",
      "skills.upload.uploaded":     "已上传",
      "skills.upload.upload":       "上传",
      "skills.upload.failed":       "失败",
      "skills.upload.publishTip":   "发布到云端",
      "skills.btn.refresh":         "刷新",

      // ── Channels panel ──
      "channels.title":           "频道",
      "channels.subtitle":        "连接即时通讯平台，让用户通过飞书、企业微信或微信与助手对话",
      "channels.loading":         "加载中…",
      "channels.loadError":       "加载频道失败：{{msg}}",
      "channels.badge.running":         "运行中",
      "channels.badge.enabled":         "已启用",
      "channels.badge.disabled":        "未配置",
      "channels.badge.notConfigured":   "未配置",
      "channels.hint.running":          "适配器运行中，正在接受用户消息",
      "channels.hint.enabled":          "⚠ 已启用但未运行 — 适配器可能连接失败，请点击「诊断问题」排查。",
      "channels.hint.enabledNotRunning":"已启用但未运行 — 适配器可能连接失败，请点击「诊断问题」排查。",
      "channels.hint.idle":             "尚未配置。点击「用 Agent 配置」开始。",
      "channels.hint.notConfigured":    "尚未配置。点击「用 Agent 配置」开始。",
      "channels.btn.test":        "诊断问题",
      "channels.btn.setup":       "用 Agent 配置",
      "channels.btn.reconfig":    "重新配置",
      "channels.btn.reconfigure": "重新配置",
      "channels.sessionError":    "未知",
      "channels.noSession":       "未返回对话",
      "channels.feishu.desc":     "通过飞书开放平台 WebSocket 长连接接入",
      "channels.wecom.desc":      "通过企业微信智能机器人 WebSocket 接入",
      "channels.weixin.desc":     "通过微信 iLink 机器人接入（扫码登录，HTTP 长轮询）",

      // ── Settings panel ──
      "settings.title":           "设置",
      "settings.models.title":    "AI 模型",
      "settings.models.add":      "+ 添加模型",
      "settings.models.loading":  "加载模型中…",
      "settings.models.error":    "加载失败：{{msg}}",
      "settings.models.empty":    "暂未配置模型，点击「+ 添加模型」添加。",
      "settings.models.badge.default": "默认",
      "settings.models.badge.lite":    "轻量",
      "settings.models.field.quicksetup": "快速配置",
      "settings.models.field.model":      "Model",
      "settings.models.field.baseurl":    "Base URL",
      "settings.models.field.apikey":     "API Key",
      "settings.models.field.getApiKey":  "如何获取 →",
      "settings.models.placeholder.provider": "— 选择服务商 —",
      "settings.models.placeholder.model":    "如 claude-sonnet-4-5",
      "settings.models.placeholder.baseurl":  "https://api.anthropic.com",
      "settings.models.placeholder.apikey":   "sk-…",
      "settings.models.custom":               "自定义",
      "settings.models.btn.save":          "保存",
      "settings.models.btn.saving":        "保存中…",
      "settings.models.btn.saved":         "已保存 ✓",
      "settings.models.btn.testing":       "测试中…",
      "settings.models.btn.set_default":   "设为默认",
      "settings.models.btn.setDefault":    "设为默认",
      "settings.models.btn.setting":       "设置中…",
      "settings.models.btn.done":          "完成 ✓",
      "settings.models.test.ok":           "✓ 连接成功",
      "settings.models.test.fail":         "✗ 测试失败：{{msg}}",
      "settings.models.badge.model":       "模型 {{n}}",
      "settings.models.connected":         "已连接",
      "settings.models.testFail":          "测试失败",
      "settings.models.failed":            "失败",
      "settings.models.saveFailed":        "保存失败",
      "settings.models.setDefaultFailed":  "设置默认模型失败",
      "settings.models.errorPrefix":       "错误：",
      "settings.models.confirmRemove":     "删除模型「{{model}}」？",
      "settings.personalize.title":        "个性化",
      "settings.personalize.desc":         "重新运行引导流程，更新助手的个性和用户档案（SOUL.md & USER.md）。",
      "settings.personalize.btn":          "✨ 重新引导",
      "settings.personalize.btn.starting": "启动中…",
      "settings.personalize.btn.rerun":    "✨ 重新引导",
      "settings.browser.title":            "浏览器",
      "settings.browser.desc":             "连接浏览器以启用浏览器自动化功能。",
      "settings.browser.configured":       "✅ 浏览器已连接",
      "settings.browser.disabled":         "⏸ 浏览器已禁用",
      "settings.browser.btn":              "🌐 配置浏览器",
      "settings.browser.btn.reconfigure":  "🌐 重新配置浏览器",
      "settings.browser.btn.starting":     "启动中…",
      "settings.brand.title":              "品牌 & 授权",
      "settings.brand.label.brand":        "品牌",
      "settings.brand.label.status":       "状态",
      "settings.brand.label.expires":      "到期时间",
      "settings.brand.label.homepage":     "主页",
      "settings.brand.label.supportContact": "联系支持",
      "settings.brand.label.supportQr":    "技术支持",
      "settings.brand.label.qrHint":       "使用手机扫描二维码",
      "settings.brand.btn.change":         "更换序列号",
      "settings.brand.btn.unbind":         "解绑授权",
      "settings.brand.confirmRebind":      "警告：所有已安装的历史品牌技能将被删除，无法继续使用。确认继续？",
      "settings.brand.confirmUnbind":      "确定要解绑此授权吗？所有品牌技能将被删除，本设备将无法再访问品牌功能。",
      "settings.brand.unbindSuccess":      "授权解绑成功。",
      "settings.brand.unbindFailed":       "解绑授权失败，请重试。",
      "settings.brand.badge.active":       "已激活",
      "settings.brand.badge.warning":      "即将过期",
      "settings.brand.badge.expired":      "已过期",
      "settings.brand.desc":               "有品牌合作伙伴的序列号？在下方输入以激活品牌模式。",
      "settings.brand.descNamed":          "请输入 {{name}} 的序列号以激活品牌模式。",
      "settings.brand.btn.getSerial":      "获取序列号",
      "settings.brand.getSerial.hint":     "还没有序列号？",
      "settings.brand.btn.activate":       "激活",
      "settings.brand.btn.activating":     "激活中…",
      "settings.brand.err.no_key":         "请输入序列号。",
      "settings.brand.enterKey":           "请输入序列号。",
      "settings.brand.invalidFormat":      "格式错误。期望格式：XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX",
      "settings.brand.activated":          "授权激活成功！品牌：{{name}}",
      "settings.brand.activationFailed":   "激活失败，请重试。",
      "settings.brand.networkError":       "网络错误：",
      "settings.brand.networkRetry":       "连接超时，服务器可能有点慢，请稍后重试。",

      "settings.lang.title":               "语言",
      "settings.lang.en":                  "English",
      "settings.lang.zh":                  "中文",

      // ── Onboard ──
      "onboard.title":              "欢迎使用 {{brand}}",
      "onboard.subtitle":           "一分钟完成配置，马上开始。",
      "onboard.lang.prompt":        "选择您的语言",
      "onboard.key.title":          "连接 AI 模型",
      "onboard.key.provider":       "服务商",
      "onboard.key.provider.placeholder": "— 选择服务商 —",
      "onboard.key.model":          "模型",
      "onboard.key.baseurl":        "Base URL",
      "onboard.key.apikey":         "API Key",
      "onboard.key.getApiKey":      "如何获取 →",
      "onboard.key.btn.test":       "测试并继续 →",
      "onboard.key.btn.back":       "← 返回",
      "onboard.provider.custom":    "自定义",
      "onboard.key.testing":        "测试中…",
      "onboard.key.saving":         "保存中…",
      "onboard.soul.title":         "个性化助手",
      "onboard.soul.desc":          "大约 30 秒，通过两个快速问答卡片完成设置。",
      "onboard.soul.btn.start":     "开始 →",
      "onboard.soul.btn.skip":      "稍后再说",

      // ── Brand activation panel ──
      "brand.title":          "激活授权",
      "brand.subtitle":       "输入序列号以开始使用。",
      "brand.key.label":      "序列号",
      "brand.btn.activate":   "激活",
      "brand.btn.skip":       "稍后再说",
      "brand.btn.activating": "激活中...",
      "brand.activate.title":    "激活 {{name}}",
      "brand.activate.subtitle": "输入序列号以开始使用。",
      "brand.activate.success":  "授权激活成功！",
      "brand.skip.warning":      "品牌授权未激活 — 品牌专属技能暂不可用。可随时在「设置 → 品牌 & 授权」中激活。",

      // ── Brand activation banner ──
      "brand.banner.prompt":      "{{name}} 尚未激活授权 — 部分功能暂不可用。",
      "brand.banner.defaultName": "您的授权",
      "brand.banner.action":      "立即激活",
      "brand.banner.sessionName": "激活授权",

      "header.owner.tooltip":     "创作者 — 点击进入创作者中心",

      // ── 会话信息栏 / 模型切换器 测速 ──
      "sib.bench.btn":        "测速",
      "sib.bench.tooltip":    "测试所有已配置模型的响应延迟",
      "sib.bench.running":    "测速中…",
      "sib.bench.done":       "用时 {{t}} 秒",
      "sib.bench.failed":     "失败：{{msg}}",
      "sib.bench.latencyTooltip": "TTFT {{ttft}} · 测试于 {{time}}",

      "onboard.welcome":         "欢迎使用 {{name}}",
    }
  };

  // ── State ──────────────────────────────────────────────────────────────────
  let _lang = localStorage.getItem(STORAGE_KEY) || DEFAULT_LANG;

  // ── Core functions ─────────────────────────────────────────────────────────

  /** Return the current language code ("en" or "zh"). */
  function lang() { return _lang; }

  /** Set language, persist to localStorage, re-apply to DOM. */
  function setLang(code) {
    _lang = TRANSLATIONS[code] ? code : DEFAULT_LANG;
    localStorage.setItem(STORAGE_KEY, _lang);
    applyAll();
    document.dispatchEvent(new CustomEvent("langchange", { detail: { lang: _lang } }));
  }

  /**
   * Translate a key. Supports {{var}} interpolation.
   * Falls back to English, then to the key itself.
   */
  function t(key, vars = {}) {
    const dict = TRANSLATIONS[_lang] || TRANSLATIONS[DEFAULT_LANG];
    let str = dict[key] ?? TRANSLATIONS[DEFAULT_LANG][key] ?? key;
    Object.entries(vars).forEach(([k, v]) => {
      str = str.replaceAll(`{{${k}}}`, v);
    });
    return str;
  }

  /**
   * Scan the DOM and apply translations to:
   *   data-i18n="key"             → element.textContent
   *   data-i18n-placeholder="key" → element.placeholder
   *   data-i18n-title="key"       → element.title
   */
  function applyAll() {
    document.querySelectorAll("[data-i18n]").forEach(el => {
      const key  = el.getAttribute("data-i18n");
      const vars = _extractVars(el);
      el.textContent = t(key, vars);
    });
    document.querySelectorAll("[data-i18n-placeholder]").forEach(el => {
      const key  = el.getAttribute("data-i18n-placeholder");
      const vars = _extractVars(el);
      let ph = t(key, vars);
      // On mobile: strip the parenthetical hint so placeholder doesn't wrap
      if (window.innerWidth <= 768) {
        ph = ph.replace(/\s*[\(（].*[\)）]/, "").trim();
      }
      el.placeholder = ph;
    });
    document.querySelectorAll("[data-i18n-title]").forEach(el => {
      const key  = el.getAttribute("data-i18n-title");
      const vars = _extractVars(el);
      el.title = t(key, vars);
    });

    // Update <html lang=""> attribute
    document.documentElement.lang = _lang;
  }

  /** Read data-i18n-vars="brand=Foo;n=3" into an object. */
  function _extractVars(el) {
    const raw = el.getAttribute("data-i18n-vars");
    if (!raw) return {};
    return Object.fromEntries(
      raw.split(";").map(pair => pair.split("=").map(s => s.trim()))
    );
  }

  // ── Public API ─────────────────────────────────────────────────────────────
  return { lang, setLang, t, applyAll };
})();

// ── Thinking Verbs for Progress Animation ──────────────────────────────────
//
// The primary verb ("Thinking" / "思考中") is chosen 90% of the time inside
// getRandomThinkingVerb(). The lists below are ONLY the 10% flavor variants —
// do not include the primary verb here, and do not rely on duplicates for
// weighting (probability is controlled in code, not data).
const THINKING_VERBS = {
  en: [
    "Cogitating",
    "Pondering",
    "Ruminating",
    "Deliberating",
    "Contemplating",
    "Flibbertigibbeting",
    "Percolating",
    "Noodling",
    "Brewing",
    "Marinating",
    "Stewing",
    "Mulling",
    "Processing",
    "Computing",
    "Calculating",
    "Analyzing",
    "Synthesizing",
    "Ideating",
    "Brainstorming",
    "Reasoning"
  ],
  zh: [
    "推理中",
    "深度思考中",
    "分析中",
    "解析中",
    "拆解中",
    "推演中",
    "梳理中",
    "归纳中",
    "演算中",
    "验证中",
    "权衡中",
    "构思中",
    "酝酿中",
    "思忖中",
    "琢磨中"
  ]
};

// Get a random thinking verb based on current language.
//
// Behavior: 90% of the time return the primary verb ("思考中" / "Thinking"),
// 10% of the time pick a random variant from the list for a bit of flavor.
// The primary is intentionally kept outside the list so tuning the probability
// is a single-number change here, independent of the list contents.
function getRandomThinkingVerb() {
  const lang    = I18n.lang();
  const primary = lang === "zh" ? "思考中" : "Thinking";

  // 90% primary, 10% variant
  if (Math.random() < 0.9) return primary;

  const verbs = THINKING_VERBS[lang] || THINKING_VERBS.en;
  if (!verbs || verbs.length === 0) return primary;
  return verbs[Math.floor(Math.random() * verbs.length)];
}
