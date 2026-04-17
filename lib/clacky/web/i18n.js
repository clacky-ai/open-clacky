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

      // ── Session list ──
      "sessions.empty":         "No sessions yet",
      "sessions.confirmDelete": "Delete session \"{{name}}\"?\nThis cannot be undone.",
      "sessions.meta":          "{{tasks}} tasks · ${{cost}}",
      "sessions.deleteTitle":   "Delete session",
      "sessions.createError":   "Error: ",
      "sessions.dirNotEmpty":   "Directory already exists and is not empty.",
      "sessions.thinking":      "Thinking…",
      "sessions.default_name":  "Session {{n}}",
      "sessions.badge.cron":    "Auto",
      "sessions.badge.channel": "Channel",
      "sessions.badge.coding":  "Coding",
      "sessions.badge.setup":   "Setup",
      "sessions.newSession":    "+ New Session",
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

      "skills.btn.new":             "New Skill",
      "skills.btn.create":          "Create",
      "skills.btn.import":          "Import",
      "skills.import.placeholder":  "Paste ZIP or GitHub URL…",
      "skills.import.install":      "Install",
      "skills.tab.my":              "My Skills",
      "skills.tab.brand":           "Brand Skills",
      "skills.empty":               "No skills loaded.",
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
      "settings.brand.btn.change":         "Change License Key",
      "settings.brand.confirmRebind":      "Warning: all previously installed brand skills will be deleted and cannot be used. Continue?",
      "settings.brand.badge.active":       "Active",
      "settings.brand.badge.warning":      "Expiring Soon",
      "settings.brand.badge.expired":      "Expired",
      "settings.brand.desc":               "Have a license key from a brand partner? Enter it below to activate branded mode.",
      "settings.brand.descNamed":          "Enter your {{name}} license key to activate branded mode.",
      "settings.brand.btn.activate":       "Activate",
      "settings.brand.btn.activating":     "Activating…",
      "settings.brand.err.no_key":         "Please enter a license key.",
      "settings.brand.enterKey":           "Please enter a license key.",
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
      "brand.subtitle":       "Enter your license key to get started.",
      "brand.key.label":      "License Key",
      "brand.btn.activate":   "Activate",
      "brand.btn.skip":       "Skip for now",
      "brand.btn.activating": "Activating...",
      "brand.activate.title":    "Activate {{name}}",
      "brand.activate.subtitle": "Enter your license key to get started.",
      "brand.activate.success":  "License activated successfully!",
      "brand.skip.warning":      "Brand license not activated — brand-exclusive skills are unavailable. You can activate your license anytime in Settings → Brand & License.",

      // ── Brand activation banner ──
      "brand.banner.prompt":      "{{name}} is not activated yet — some features are unavailable.",
      "brand.banner.defaultName": "Your license",
      "brand.banner.action":      "Activate Now",
      "brand.banner.sessionName": "License Activation",

      "onboard.welcome":         "Welcome to {{name}}",
    },

    zh: {
      // ── Sidebar ──
      "sidebar.chat":     "对话",
      "sidebar.config":   "配置",
      "sidebar.tasks":    "任务管理",
      "sidebar.skills":   "技能管理",
      "sidebar.channels": "频道管理",
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

      // ── Session list ──
      "sessions.empty":         "暂无对话",
      "sessions.confirmDelete": "删除对话「{{name}}」？\n此操作不可撤销。",
      "sessions.meta":          "{{tasks}} 个任务 · ${{cost}}",
      "sessions.deleteTitle":   "删除对话",
      "sessions.createError":   "错误：",
      "sessions.dirNotEmpty":   "该目录已存在且不为空，请换一个目录名。",
      "sessions.thinking":      "思考中…",
      "sessions.default_name":  "对话 {{n}}",
      "sessions.badge.cron":    "自动",
      "sessions.badge.channel": "频道",
      "sessions.badge.coding":  "Coding",
      "sessions.badge.setup":   "配置",
      "sessions.newSession":    "+ 新会话",
      "sessions.loadMore":      "加载更多会话",
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

      "skills.btn.new":             "新建技能",
      "skills.btn.create":          "创建",
      "skills.btn.import":          "导入",
      "skills.import.placeholder":  "粘贴 ZIP 或 GitHub 链接…",
      "skills.import.install":      "安装",
      "skills.tab.my":              "我的技能",
      "skills.tab.brand":           "品牌技能",
      "skills.empty":               "暂无技能。",
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
      "settings.brand.btn.change":         "更换授权码",
      "settings.brand.confirmRebind":      "警告：所有已安装的历史品牌技能将被删除，无法继续使用。确认继续？",
      "settings.brand.badge.active":       "已激活",
      "settings.brand.badge.warning":      "即将过期",
      "settings.brand.badge.expired":      "已过期",
      "settings.brand.desc":               "有品牌合作伙伴的授权码？在下方输入以激活品牌模式。",
      "settings.brand.descNamed":          "请输入 {{name}} 的授权码以激活品牌模式。",
      "settings.brand.btn.activate":       "激活",
      "settings.brand.btn.activating":     "激活中…",
      "settings.brand.err.no_key":         "请输入授权码。",
      "settings.brand.enterKey":           "请输入授权码。",
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
      "brand.subtitle":       "输入授权码以开始使用。",
      "brand.key.label":      "授权码",
      "brand.btn.activate":   "激活",
      "brand.btn.skip":       "稍后再说",
      "brand.btn.activating": "激活中...",
      "brand.activate.title":    "激活 {{name}}",
      "brand.activate.subtitle": "输入授权码以开始使用。",
      "brand.activate.success":  "授权激活成功！",
      "brand.skip.warning":      "品牌授权未激活 — 品牌专属技能暂不可用。可随时在「设置 → 品牌 & 授权」中激活。",

      // ── Brand activation banner ──
      "brand.banner.prompt":      "{{name}} 尚未激活授权 — 部分功能暂不可用。",
      "brand.banner.defaultName": "您的授权",
      "brand.banner.action":      "立即激活",
      "brand.banner.sessionName": "激活授权",

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
    "思考中",      // 5x weight (appears 5 times for higher probability)
    "思考中",
    "思考中",
    "思考中",
    "思考中",
    "琢磨中",      // 2x weight
    "琢磨中",
    "思忖中",
    "盘算中",
    "酝酿中",
    "捋一捋",
    "理理头绪",
    "掂量掂量",
    "寻思中",
    "琢磨琢磨",
    "想想办法",
    "推演中",
    "解析中",
    "拆解中",
    "组装中",
    "梳理中",
    "验证中",
    "演算中",
    "分析中",
    "推理中",
    "构思中"
  ]
};

// Get a random thinking verb based on current language
function getRandomThinkingVerb() {
  const lang = I18n.lang();
  const verbs = THINKING_VERBS[lang] || THINKING_VERBS.en;
  return verbs[Math.floor(Math.random() * verbs.length)];
}
