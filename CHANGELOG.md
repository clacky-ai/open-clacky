# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.9] - 2026-03-23

### Added
- **Real-time skill loading in Web UI**: the `/skill` autocomplete now fetches the live skill list on every trigger, so newly installed or updated skills appear immediately without a page reload
- **Skill source type in autocomplete**: each skill in the autocomplete now carries its source type (default / user / project / brand), making it easy to see where a skill comes from
- **Browser configure API**: a new `POST /api/browser/configure` endpoint writes `browser.yml` and hot-reloads the browser daemon — the browser-setup skill now configures the browser in one step without manual file editing
- **Brand skill path confidentiality**: temporary script paths used by encrypted brand skills are now hidden from the agent's output and never disclosed to the user

### Improved
- **Stale brand skills cleared on license switch**: activating a new license now automatically removes encrypted skill files from the previous brand, preventing decryption errors and stale skill behaviour
- **Brand skill confidentiality enforcement**: the system prompt and per-skill injection both include an explicit notice that internal script paths are runtime details and must never be shown to the user
- **Rebind license confirmation**: re-binding a license in Settings now shows a confirmation dialog before proceeding, preventing accidental license changes

### Fixed
- **HTTP server spec stability**: fixed flaky test assertions in `http_server_spec.rb` that caused intermittent CI failures

### More
- Updated `gem-release` skill with improved CHANGELOG writing guidelines

## [0.9.8] - 2026-03-23

### Added
- **Real browser automation via CDP**: the browser tool now drives a real Chromium browser using the Chrome DevTools Protocol — structured action schemas, snapshots, screenshots, and full page interaction are all supported
- **Browser DevTools MCP integration**: the browser connects to Chrome's DevTools via MCP, enabling deeper inspection and control beyond standard WebDriver capabilities
- **Browser manager in Web UI**: a new browser management panel lets you start, stop, restart, and monitor the connected browser session directly from the Web UI
- **WeChat (Weixin) channel support**: the agent can now receive and reply to messages via WeChat, including sending and receiving images
- **Feishu Docs integration**: the agent can now read and process Feishu (Lark) documents directly as context
- **PDF preview in Web UI**: PDFs attached to a conversation now render inline in the chat interface
- **Session source tracking**: sessions now track where they originated (Web UI, Feishu, WeCom, WeChat, CLI) and display the source in the sessions list
- **Sessions list in Web UI**: a dedicated sessions UI shows all your recent conversations with source badges and load-more pagination
- **Setup session type**: a special onboarding session type is available to guide new users through initial configuration
- **Personal website skill**: a built-in skill that generates and publishes a personal profile page (linktree-style) from your user profile
- **Sub-directory `.clackyrules` loading**: project rules files in subdirectories are now discovered and merged automatically
- **Self-improving response parser**: the parser now repairs itself when it encounters malformed tool-call sequences, improving reliability with all models
- **UJK format support**: the agent can now handle UJK-encoded content in file and channel inputs
- **Browser toggle in Web UI**: a toggle in the settings sidebar lets you enable or disable browser control without restarting
- **Logo and QR code on homepage**: the Web UI homepage now displays the product logo and a shareable QR code
- **Clear thinking in channel**: channel messages now strip internal `<thinking>` blocks before sending the reply to the user

### Fixed
- **`invoke_skill` tool-call sequence**: skill invocations via tool call now correctly follow the expected request/response order, preventing out-of-sequence tool results
- **URI parsing for edge cases**: fixed a crash when parsing certain malformed or unusual URIs
- **Doc reader parsing**: fixed an issue where some document formats were not correctly parsed by the doc reader tool
- **Zip skill location discovery**: fixed skill loading from zip files installed in non-standard locations
- **Install script compatibility**: the install script now explicitly uses bash to avoid failures on systems where `/bin/sh` is not bash

### More
- Rename `working` → `thinking` in agent status display
- Channel and Web UI now sync session state in real time
- Cost usage display improvements

## [0.9.7] - 2026-03-20

### Added
- **AWS Bedrock support**: the agent can now use Claude models hosted on AWS Bedrock (including the Japan region `bedrock-jp` provider with `jp.anthropic.claude-sonnet-4-6` and `jp.anthropic.claude-haiku-4-6`)
- **Brand skill confidentiality protection**: when a brand skill is injected, the agent is now instructed to never reveal, quote, or paraphrase the skill's proprietary instructions — keeping white-label content secure
- **Slash command guard in skill injection**: skills invoked via `/skill-name` commands now include a system notice that prevents the agent from calling `invoke_skill` a second time for the same request
- **"Show system skills" toggle in Web UI**: the Skills settings page now has a checkbox to show or hide built-in system skills, making it easier to find your own custom skills in a long list

### Fixed
- **Shell commands with non-UTF-8 output no longer crash**: output from commands that produce GBK, Latin-1, or binary bytes (e.g. some `cat` or legacy tool output) is now safely transcoded to UTF-8 instead of raising an encoding error
- **Task interruption no longer duplicates or garbles output**: a non-blocking progress-clear path ensures the user's message appears immediately on screen when a task is interrupted, without leaving stale progress lines behind
- **Terminal inline content resize no longer overflows into the fixed toolbar area**: when an inline block grows past the available output rows, the terminal now scrolls correctly instead of writing into the status bar region
- **Brand skills always show the latest version**: the skills list in the Web UI now correctly reflects the most recent version of a brand skill after an update

### More
- Rename brand skill `slug` field to `name` for consistency across the codebase
- Rename `brandname` → `productname` in brand config internals
- Unify skill injection into a shared `inject_skill_as_assistant_message` method
- Update built-in skill definitions

## [0.9.6] - 2026-03-18

### Added
- **Environment-aware context injection**: the agent now automatically detects your OS, desktop environment, and screen info and includes it in every session — so it can give OS-specific advice without you having to explain your setup
- **File attachments via IM channels**: you can now send images and documents directly through Feishu or WeCom to the agent, which processes them just like files sent via the Web UI
- **Unified file attachment pipeline for Web UI**: images and Office/PDF documents can now be attached in the web chat interface with automatic image compression before upload
- **Skills can now be installed from local zip files**: `skill-add` now accepts a local file path (not just a URL), so you can install skills from a downloaded zip without hosting it anywhere
- **Skill import bar in Web UI**: the Skills settings page now has an import bar where you can paste a URL or upload a local zip file directly — no terminal needed to install new skills
- **`$SKILL_DIR` available in skill instructions**: skill files can now reference `$SKILL_DIR` to get the absolute path to their own directory, making it easy to reference supporting files with correct paths
- **`product-help` built-in skill**: the agent can now answer questions about Clacky's own features, configuration, and usage through a dedicated built-in skill

### Fixed
- **PDF and Office files now appear in glob results**: file discovery tools no longer skip `.pdf`, `.docx`, and other document formats — they show up correctly in file listings
- **Chat history visible after message compression**: sessions where all user messages were compressed no longer show a blank history — prior conversation is now correctly replayed
- **Stale message reference in task history**: an internal bug (`@messages` vs `@history`) that could cause incorrect task history in compressed sessions is fixed
- **File-only messages handled correctly in channel UI**: sending a file without text via IM channels no longer causes a display issue in the channel UI
- **WeCom WebSocket client stability**: fixed async dispatch and frame acknowledgment in the WeCom WS client to reduce dropped messages and connection issues
- **Session serializer variable fix**: corrected a stale variable reference in session replay that could cause errors when restoring sessions
- **`web_fetch` compatibility improved**: better request headers make web page fetching more reliable across more sites
- **Reasoning content preserved in API messages**: `reasoning_content` fields are no longer stripped from messages, fixing potential issues with reasoning-capable models

### More
- Markdown links in chat now open in a new tab
- Removed public skill store tab from the Skills panel (store content is now integrated differently)
- Reduce WebSocket ping log noise in HTTP server
- Centralize message cleanup logic in `MessageHistory`

## [0.9.5] - 2026-03-17

### Added
- **License activation now navigates directly to Brand Skills tab**: after entering a valid license key, the UI automatically opens the Brand Skills settings tab — no extra steps needed to find and load your skills
- **Version badge always clickable**: clicking the version number in the sidebar now always works regardless of update state; when already on the latest version, a small "up to date" popover appears and auto-dismisses

### Improved
- **MessageHistory domain object**: agent message handling is now encapsulated in a dedicated `MessageHistory` class, making the codebase cleaner and message operations (compression, caching, transient marking) more reliable and testable
- **Brand skill isolation via transient message marking**: brand skill subagent calls no longer spin up a separate isolated agent; instead, messages are marked as transient and stripped after the call — simpler architecture with the same isolation guarantees
- **License activation flow simplified**: the `activate-license` skill is replaced with direct in-UI navigation and settings highlighting, reducing round-trips and making activation feel more native

### Fixed
- **Tilde (`~`) in file paths now expanded correctly**: tool preview checks now expand `~` to the home directory before checking file existence, so paths like `~/Documents/file.txt` no longer falsely report as missing
- **Subagent with empty arguments no longer crashes**: when a skill invocation passes empty arguments, a safe placeholder message is used instead of raising an error
- **Version popover shows "up to date" state**: clicking the version badge when already on the latest version now shows a friendly confirmation instead of silently falling through to open the settings panel

### More
- Simplify error messages in brand config decryption
- Update test matchers to match simplified error messages

## [0.9.4] - 2026-03-16

### Fixed
- **Prompt cache strategy reverted to simple last-message anchoring**: the experimental assistant-message-anchored cache strategy introduced in v0.9.3 was causing regressions; caching is now restored to a simpler, proven approach where the last message is used as the cache breakpoint

## [0.9.3] - 2026-03-16

### Added
- **Brand logo banner on web server startup**: a styled block-font logo now displays in the terminal when `clacky server` launches, giving a polished startup experience
- **BlockFont renderer replaces artii dependency**: the gem now ships its own high-quality block-font engine for rendering large ASCII logos, removing the external `artii` dependency and enabling full offline use
- **Hover-to-expand token usage and session info bar**: hovering over the token usage line or session info bar in the WebUI now expands it to show full details, keeping the UI compact by default
- **Redesigned setup panel with Back button and Custom provider support**: the model setup flow now includes a Back button for navigation and a dedicated "Custom provider" path, making it easier to configure non-standard API endpoints; also fixes a dropdown re-entry bug
- **License activation via non-blocking top banner**: the brand activation flow no longer blocks the entire UI with a full-screen panel — it now shows a slim top banner, and activation is handled through a dedicated skill
- **`startSoulSession` exposed on Onboard public interface**: third-party integrations can now trigger soul session initialization directly from the onboard module

### Improved
- **Browser tool simplified and config-driven**: the browser tool setup is now handled through a unified config object, removing ~250 lines of complex auto-restart logic and making the tool more predictable and maintainable
- **Prompt caching more stable**: cache anchoring now uses the last assistant message as the stable boundary, reducing cache misses caused by system prompt variations; caching is correctly restored for both Anthropic and OpenRouter paths
- **Message format extracted to dedicated modules**: OpenAI and Anthropic message formatting now live in separate modules (`Clacky::MessageFormat::OpenAI` and `Clacky::MessageFormat::Anthropic`), making the client code easier to read and test
- **WeCom channel reliability**: auth failure handling is improved with proper reconnection logic; the `channel-setup` skill guidance is also updated for clarity
- **Install script and license expiry handling**: the install script is streamlined, license-expired states are handled gracefully, and encrypted skills are decrypted at load time

### Fixed
- **Prompt cache stability across turns**: cache was occasionally invalidated between turns due to message boundary drift; now anchored reliably to the last assistant message
- **`request_user_feedback` missing from session history replay**: feedback prompts sent during a session were not rendered when replaying history in the WebUI; they now appear correctly as assistant messages
- **Brand activation banner not shown when API key is missing**: the banner now correctly appears even when no API key is configured, with a translated skip warning
- **Zip extraction security**: zip files are now read in chunks with size verification, preventing potential zip-bomb or oversized-file issues

### More
- Remove browser tool auto-restart logic that was causing instability in headless environments
- Add security design documentation

## [0.9.2] - 2026-03-15

### Fixed
- **Version upgrade button now appears reliably**: the new version check now queries RubyGems directly instead of relying on local gem mirror sources (which often lag behind by hours or days), so the upgrade badge shows up promptly when a new version is available. Falls back to the local mirror if RubyGems is unreachable.
- **Edit confirmation diff output restored**: the file diff was not displaying correctly when the input area paused during an edit confirmation prompt; this is now fixed.

## [0.9.1] - 2026-03-15

### Added
- **Session context auto-injection**: the agent now automatically injects the current date and active model name into each conversation turn, so it always knows what day it is and which model it's running — helpful for time-sensitive tasks and multi-model setups
- **Kimi/Moonshot extended thinking support**: reasoning content is now preserved and echoed back correctly in message history, fixing HTTP 400 errors when using Kimi's extended thinking API

### Improved
- **Browser tool install UX**: the `agent-browser` setup flow has been redesigned with a dedicated install script and clearer guidance, making first-time setup smoother

## [0.9.0] - 2026-03-14

### Added
- **Version check and one-click upgrade in WebUI**: a version badge in the sidebar shows when a newer gem is available; clicking it opens an upgrade popover with a live install log and a restart button — no terminal needed
- **Upgrade badge state machine**: the badge cycles through four visual states — amber pulsing dot (update available), spinning ring (installing), orange bouncing dot (restart needed), green check (restarted successfully)
- **Markdown rendering in WebUI chat**: assistant responses are now rendered as rich markdown — headings, bold, code blocks, lists, and inline code are all formatted properly instead of displayed as raw text
- **Session naming with auto-name and inline rename**: sessions are automatically named after the first exchange; users can double-click any session in the sidebar to rename it inline
- **Session info bar with live status animation**: a slim bar below the chat header shows the session name, working directory, and a pulsing animation while the agent is thinking or executing tools
- **Restore last 5 sessions on startup**: the WebUI now reopens the five most recent sessions on startup instead of just the last one
- **Image and file support for Feishu and WeCom**: users can now send images and file attachments through Feishu and WeCom IM channels; the agent reads and processes them like any other input
- **Idle compression in WebUI**: the agent now compresses long conversation history automatically when the session has been idle, keeping context efficient without manual intervention

### Improved
- **Glob tool recursive search**: bare pattern names like `controller` are now automatically expanded to `**/*controller*` so searches always return results across all subdirectories
- **Onboard flow**: soul setup is now non-blocking; the confirmation page is skipped for a faster first-run experience; onboard now asks the user to name the AI first, then collects the user profile
- **Token usage display ordering**: the token usage line in WebUI now always appears below the assistant message bubble, not above it
- **i18n coverage**: settings panel dynamically-rendered fields are now translated correctly at render time

### Fixed
- **Upgrade popover stays open during install and reconnect**: the popover is now locked while a gem install or server restart is in progress, preventing accidental dismissal that would leave the badge stuck in a spinning state
- **Session auto-name respects default placeholders**: session names are now assigned based on message history only, not the agent's internal name field, so placeholder names like "Session 1" no longer block the auto-naming logic
- **Token usage line disappears after page refresh**: token usage data is now persisted in session history and correctly re-rendered when the page is reloaded
- **Shell tool hangs on background commands**: commands containing `&` (background operator) no longer cause the shell tool to block indefinitely
- **White flash on page load**: the page is now hidden until boot completes, preventing a flash of unstyled content or the wrong view on startup
- **Theme flash on refresh**: the theme (dark/light) is now initialized inline in `<head>` so the correct colours are applied before any content renders
- **Onboard flash on reload**: the onboard panel no longer briefly appears when a session already exists during soul setup

### More
- Rename channels "Test" button to "Diagnostics" for clarity
- Default-highlight the first item in skill autocomplete

## [0.8.8] - 2026-03-13

### Added
- **i18n system with zh/en runtime switching**: WebUI now supports Chinese and English; all UI text is served through an `I18n` module and switches instantly without a page reload
- **Onboard language selection step**: first-time setup now opens with a language picker (中文 / English) before any configuration, so the entire onboard experience is conducted in the user's chosen language
- **Onboard "what's your name" step**: onboard flow now asks for the user's preferred name early on and addresses them by name throughout the rest of the setup
- **Chinese SOUL.md default**: when a user onboards in Chinese and skips the soul-setup conversation, a Chinese-language SOUL.md is written automatically so the assistant responds in Chinese by default

### Fixed
- **Onboard WS race condition**: fixed a bug where the first auto-triggered `/onboard` command was silently lost — the WebSocket `session_list` event arrived before the session view was active and redirected the UI to the welcome screen, hiding the agent's response

## [0.8.7] - 2026-03-13

### Added
- **PDF file upload and reading**: users can now upload PDF files directly in the WebUI chat; the agent reads and analyzes the content via the built-in `pdf-reader` skill
- **WebUI favicon and SVG icons**: browser tab now shows the Clacky icon
- **Public skill store install**: skills from the public store can be installed directly via the WebUI without a GitHub URL
- **Auto-kill previous server on startup**: launching `clacky serve` now automatically kills any previously running instance via pidfile, preventing port conflicts

### Improved
- **Brand skill loading speed**: loading brand skills no longer triggers a network decryption request — name and description are now read from the local `brand_skills.json` cache, making New Session significantly faster
- **Memory update UX**: memory update step now shows a spinner and info-style message instead of a bare log line
- **Browser snapshot output**: snapshot output is compressed to reduce token cost when the agent uses browser tools
- **Subagent output**: subagent task completion now shows a brief info line instead of a full "Task Complete" block, reducing noise in the parent agent's context

### Fixed
- **Subagent token delta on first iteration**: subagent now inherits `previous_total_tokens` correctly, fixing an inflated token count on the first tool iteration
- **Chrome DevTools inspect URL**: updated the remote debugging URL to include the `#remote-debugging` fragment for correct navigation
- **Shell output token explosion**: long lines in shell output are now truncated to prevent excessive token usage

### More
- Binary file size limit lowered from 5 MB to 512 KB to reduce accidental token cost
- `kill_existing_server` logic moved from CLI into `HttpServer` for cleaner separation
- Browser tool prefers `snapshot -i` over `screenshot` for lower token cost
- Cross-platform PID file path using `Dir.tmpdir` instead of hardcoded `/tmp`

## [0.8.6] - 2026-03-12

### Added
- **Channel system with Feishu & WeCom support**: integrated IM platform adapters — agents can now receive and reply to messages via Feishu (WebSocket) and WeCom channels
- **Skill encryption (brand skills)**: brand skills can be distributed as encrypted `.enc` files, decrypted on-the-fly using license keys; includes a full key management and manifest system
- **Cron task creator & skill creator default skills**: two new built-in skills for creating scheduled tasks and new skills directly from chat
- **Image messages in session history restore**: session restore now correctly replays image-containing messages, including thumbnail display in the UI
- **Skill auto-upload to cloud**: skills can be uploaded to the cloud store from within the UI

### Improved
- **WeCom setup flow**: improved step-by-step WeCom channel configuration UX (#11)
- **Skill autocomplete UI**: enhanced slash-command autocomplete interaction — better keyboard navigation, input behavior, and visual feedback (#6)
- **Chrome setup UX**: simplified Chrome installation flow with improved error messages and progress indicators (#8)
- **WebUI colors and layout**: polished light/dark mode colors, sidebar alignment, and badge styles for a more consistent look
- **Test suite speed**: `CLACKY_TEST` guard prevents brand skill network calls during tests — suite now runs ~60× faster per example

### Fixed
- **Duplicate user bubble on skill install**: prevented an extra chat bubble appearing when installing a skill from the store
- **Image thumbnails in session replay**: restored missing image thumbnails when replaying historical sessions
- **WebUI permission mode**: Web UI sessions now correctly use `confirm_all` permission mode
- **Feishu WS log noise**: removed emoji characters from WebSocket connection log messages

### More
- Subagent memory update disabled to reduce noise
- Ping request `max_tokens` bumped from 10 to 16
- WebUI updated to use new cron-task-creator and skill-creator skills

## [0.8.5] - 2026-03-11

### Fixed
- **SSL connection on mise/Homebrew Ruby**: disabled SSL certificate verification in Faraday HTTP client to fix `SSL_connect` errors that affected users who installed Ruby via `mise` + Homebrew on macOS (where the system CA bundle is not linked automatically)
- **ChannelManager startup crash**: fixed `NoMethodError` for undefined `Clacky.logger` — now correctly calls `Clacky::Logger`

## [0.8.4] - 2026-03-10

### Added
- **License verify & download skills**: brand distribution can now push skills to clients via license heartbeat — skills are downloaded and installed automatically on activation and heartbeat
- **Web UI theme system**: dark/light mode toggle with full CSS variable theming, persistent across sessions; all UI components (sessions, tasks, settings) updated to use theme variables

### Improved
- **Skill loader default agent**: `SkillLoader` now applies a sensible default agent value, simplifying skill configuration for common cases
- **Web UI modernized**: redesigned session and task lists with active indicators, improved hover effects, and inline SVG icons (removed Lucide CDN dependency)

### Fixed
- **UTF-8 input handling**: invalid UTF-8 bytes in terminal UI input and output are now scrubbed cleanly instead of raising encoding errors
- **UI thread deadlock**: progress and fullscreen threads now stop gracefully on shutdown, preventing rare deadlocks
- **IME composition input**: slash `/` command button is now disabled during IME composition (e.g. Chinese input), preventing double-submit on Enter
- **CLI `clear` command**: fixed a regression that broke the `clacky clear` command

### More
- Refactor: rename `set_skill_loader` to `set_agent` in `UiController` for clarity
- Chore: update onboard skill default AI identity wording
- Fix: append user shim after skill injection for Claude API compatibility

## [0.8.3] - 2026-03-09

### Added
- **Slash command skill injection**: skill content is now injected as an assistant message for all `/skill-name` commands, giving the agent full context of the skill instructions at invocation time
- **Collapsible `<think>` blocks** in web UI: model reasoning enclosed in `<think>…</think>` tags is rendered as a collapsible "Thinking…" section instead of raw text

### Improved
- **Web UI settings panel**: refined layout and styles for the settings modal
- **Session state restored on page refresh**: "Thinking…" progress indicator and error messages are now restored from session status after a page reload instead of disappearing

### Fixed
- **AgentConfig shallow-copy bug**: switching models in Settings no longer pollutes existing sessions — `deep_copy` (JSON round-trip) is now used everywhere instead of `dup` to prevent shared `@models` hash mutation across sessions

## [0.8.2] - 2026-03-09

### Added
- **Skill count limits**: two-layer guard to keep context tokens bounded — at most 50 skills loaded from disk (`MAX_SKILLS`) and at most 30 injected into the system prompt (`MAX_CONTEXT_SKILLS`); excess skills are skipped and a warning is written to the file logger

### Improved
- Skill `agent` field is now self-declared in each `SKILL.md` instead of being listed in `profile.yml` — makes skill-to-profile assignment portable and removes the need to edit profile config when adding skills
- Slash command autocomplete in the web UI now filters by the active session's agent profile, so only relevant skills appear

### Fixed
- CLI startup crash: `ui: nil` keyword argument now correctly passed to `Agent.new`

## [0.8.1] - 2026-03-09

### Added
- **Agent profile system**: define named agent profiles (`--agent coding|general`) with custom system prompts and skill whitelists via `profile.yml`; built-in `coding` and `general` profiles included
- **Skill autocomplete dropdown** in the web UI: type `/` in the chat input to see a filtered list of available skills
- **File-based logger** (`Clacky::Logger`): thread-safe structured logging to `~/.clacky/logs/` for debugging agent sessions
- **Session persistence on startup**: server now restores the most recent session for the working directory automatically on boot
- **Long-term memory update system**: agent automatically updates `~/.clacky/memories/` after sessions using a whitelist-driven approach; memories persist across restarts and are injected into agent context on startup
- **recall-memory skill with smart meta injection**: the `recall-memory` skill now receives a pre-built index of all memory files (topic, description, last updated) so the agent can selectively load only relevant memories without reading every file
- **Compressed message archiving**: older messages are compressed and archived to chunk Markdown files to keep context window manageable
- **Network pre-flight check**: connection is verified before agent starts; helpful VPN/proxy suggestions shown on failure
- **Encrypted brand skills**: white-label brand skills can now be shipped as encrypted `.enc` files for privacy

### Improved
- Memory update logic tightened: whitelist-driven approach, raised trigger threshold, and dynamic prompt — reduces false writes and improves reliability
- Slash commands in onboarding (`/create-task`, `/skill-add`) now use the pending-message pattern so they work correctly before WS connects
- Sidebar shows "No sessions yet" placeholder during onboarding
- Session delete is now optimistic — UI updates immediately without waiting for WS broadcast, and 404 ghost sessions are cleaned up automatically
- Tool call summaries from `format_call` are now rendered in the web UI for cleaner tool output display
- Agent error handling and memory update flow stabilized

### Fixed
- Create Task / Create Skill buttons during onboarding now correctly send the command after WS connects (previously messages were silently dropped)
- Pending slash commands are now queued until the session WS subscription is confirmed
- `working_dir: nil` added to all tool `execute` signatures to fix unknown keyword errors

### More
- `clacky` install script robustness and UX improvements
- Disabled rdoc/ri generation on gem install for faster installs
- Strip `.git/.svn/.hg` directories from glob results

## [0.8.0] - 2026-03-06

### Added
- **Browser tool**: AI agent can now control the user's Chrome browser via Chrome DevTools Protocol (CDP) — click, fill forms, take screenshots, scroll, and interact with pages using the user's real login session
- White-label brand licensing system: customize the web UI with your own name, logo, colors, and skills via `brand_config.yml`
- Brand skills tab in the web UI with private badge, shown only when brand skills are configured
- Slash command prompt rule: skill invocations (e.g. `/skill-name`) are now expanded inside the agent at run time, enabling mid-session skill triggering

### Improved
- Server-side brand name rendering eliminates the first-paint brand name flash in the web UI
- Collapsible tool call blocks in the web UI — long tool outputs are now grouped and collapsed by default
- `safe_shell` now catches `ArgumentError` in addition to `BadQuotedString` for more robust command parsing
- Eliminated `Dir.chdir` global state in session handling, fixing race conditions in concurrent sessions

### Fixed
- Skill slash commands are now expanded inside `agent.run` so that `/onboard` and similar commands work correctly when triggered mid-session
- Observer state machine handles `awaiting` state transitions properly

### More
- Disabled ClaudeCode `ANTHROPIC_API_KEY` environment variable fallback in `AgentConfig` for cleaner env isolation
- Updated gemspec, lockfile, and install script
- Added web asset syntax specs and brand config specs

## [0.7.9] - 2026-03-07

### Added
- Cursor-paginated message history in web UI for large session navigation
- `confirm_all` permission mode for WebUI human sessions
- Re-run onboard entry in settings panel

### Fixed
- Expand `~` in file system tools path arguments (file_reader, glob, grep, write, edit)
- Sort sessions newest-first with scheduled sessions at bottom
- Tasks and skills sidebar items now static — no longer disappear on scroll
- Delete task now also removes associated schedules

### More
- Add frontmatter (`name`, `description`, `disable-model-invocation`, `user-invocable`) to onboard skill

## [0.7.8] - 2026-03-06

### Added
- Skills panel in web UI: list all skills, enable/disable with toggle, view skill details
- Hash-based routing (`#session/:id`, `#tasks`, `#skills`, `#settings`) with deep-link and refresh support
- REST API endpoints for skills management (`GET /api/skills`, `PATCH /api/skills/:name/toggle`)
- `disabled?` helper on `Skill` model for quick enabled/disabled state checks

### Improved
- Centralized `Router` object in web UI — single source of truth for all panel switching and sidebar highlight state
- Web UI frontend split further: `skills.js` extracted as standalone module
- Ctrl-C in web server now exits immediately via `StartCallback` trap override
- Skill enable/disable now writes `disable-model-invocation: false` (retains field) instead of deleting it

### Fixed
- Sidebar highlight for Tasks and Skills stuck active after navigating away
- Router correctly restores last view on page refresh via hash URL

### Changed
- Removed `plan_only` permission mode from agent, CLI, and web UI

## [0.7.7] - 2026-03-04

### Added
- Web UI server with WebSocket support for real-time agent interaction in the browser (`clacky serve`)
- Task scheduler with cron-based automation, REST API, and scheduled task execution
- Settings panel in web UI for viewing and editing AI model configurations (API keys, base URL, provider presets)
- Image upload support in web UI with attach button for multimodal prompts
- Create Task button in the task list panel for quick task creation from the web UI
- `create-task` default skill for guided automated task creation

### Improved
- Web UI frontend split into modular files (`ws.js`, `sessions.js`, `tasks.js`, `settings.js`) for maintainability
- Web session agents now run in `auto_approve` mode for unattended execution
- Session management moved to client-side for faster, round-trip-free navigation
- User message rendering moved to the UI layer for cleaner architecture
- No-cache headers for static file serving to ensure fresh asset delivery

### Fixed
- `DELETE`/`PUT`/`PATCH` HTTP methods now supported via custom WEBrick servlet
- Task run broadcasts correctly after WebSocket subscription; table button visibility fixed
- Mutex deadlock in scheduler `stop` method when called from a signal trap context
- `split` used instead of `shellsplit` for skill arguments to avoid parsing errors

### More
- Add HTTP server spec and scheduler spec with full test coverage
- Minor web UI style improvements and reduced mouse dependency

## [0.7.6] - 2026-03-02

### Added
- Non-interactive `--message`/`-m` CLI mode for scripting and automation (run a single prompt and exit)
- Real-time refresh and thread-safety improvements to fullscreen UI mode

### Improved
- Extract string matching logic into `Utils::StringMatcher` for cleaner, reusable edit diffing
- Glob tool now uses force mode in system prompt for more reliable file discovery
- VCS directories (`.git`, `.svn`, etc.) defined as `ALWAYS_IGNORED_DIRS` constant

### Fixed
- Subagent fork now injects assistant acknowledgment to fix conversation structure issues
- Tool-denial message clarified; added `action_performed` flag for better control flow

### More
- Add memory architecture documentation
- Minor whitespace cleanup in `agent_config.rb`

## [0.7.5] - 2026-02-28

### Fixed
- Tool errors now display in low-key style (same as tool result) to avoid alarming users for non-critical errors the agent can retry
- Session list now shows last message instead of first message for better context
- Shell tool uses login shell (`-l`) instead of interactive shell (`-i`) for proper environment variable loading

### Improved
- Shell tool now reliably loads user environment (PATH, rbenv, nvm, etc.) on every execution
- Session list shows resume tip (`clacky -a <session_id>`) to help users continue previous sessions

### More
- Add GitHub Release creation step to gem-release skill
- Remove debug logging from API client

## [0.7.4] - 2026-02-27

### Added
- Real-time command output viewing with Ctrl+O hotkey
- GitHub skill installation support in skill-add
- Rails project creation scripts in new skill
- Auto-create ~/clacky_workspace when starting from home directory

### Improved
- System prompt with glob tool usage guidance
- Commit skill with holistic grouping strategy and purpose-driven commits
- Theme color support for light backgrounds (bright mode refinements)
- Shell output handling and preview functionality
- Message compressor optimization (reduced to 200)

### Fixed
- UI2 output re-rendering on modal close and height changes
- Double render issue in inline input cleanup
- Small terminal width handling for logo display
- Extra newline in question display

### More
- Commented out idle timer debug logs for cleaner output

## [0.7.3] - 2026-02-26

### Fixed
- Modal component validation result handling after form submission
- Modal height calculation for dynamic field count in form mode

### Improved
- Provider ordering prioritizes well-tested providers (OpenRouter, Minimax) first
- Updated Minimax to use new base URL (api.minimaxi.com) and M2.5 as default
- Updated model versions: Claude Sonnet 4.6, OpenRouter Sonnet 4-6, Haiku 4.5
- Minimax model list now includes M2.1 and M2.5 (removed deprecated Text-01)

## [0.7.2] - 2026-02-26

### Added
- Cross-platform auto-install script with mise and WSL support
- Built-in provider presets for quick model configuration
- Terminal restart reminder after installation
- More bin commands for improved CLI experience
- Shields.io badges to README

### Improved
- Install script robustness and user experience
- Code-explorer workflow with forked subagent mode explanation
- README with features, usage scenarios, and comparison table
- Installation section with clearer instructions

### Fixed
- Binary file detection using magic bytes only (prevents false positives on multibyte text)
- Display user input before executing callback in handle_submit
- Install script now uses gem-only approach (removed homebrew dependency)

### More
- Minor formatting fixes in install script and README
- Removed skill emoji for cleaner UI
- Removed test-skill
- Updated install script configuration

## [0.7.1] - 2026-02-24

This release brings significant user experience improvements, new interaction modes, and enhanced agent capabilities.

### 🎯 Major Features

**Subagent System**
- Deploy subagent for parallel task execution
- Subagent mode with invoke_skill tool and code-explorer skill integration
- Environment variable support and model type system

**Command Experience**
- Tab completion for slash commands
- Ctrl+O toggle expand in diff view
- JSON mode for structured output
- Streamlined command selection workflow with improved filtering

**Agent Improvements**
- Idle compression with auto-trigger (180s timer)
- Improved interrupt handling for tool execution
- Preview display for edit and write tools in auto-approve mode
- Enable preview display in auto-approve mode

**Configuration UI**
- Auto-save to config modal
- Improved model management UI
- Better error handling and validation

### Added
- Quick start guides in English and Chinese
- Config example and tests for AgentConfig

### Improved
- Refactored agent architecture (split agent.rb, moved file locations)
- Simplified thread management in chat command
- Dynamic width ratio instead of fixed MAX_CONTENT_WIDTH
- API error messages with HTML detection and truncation
- Help command handling

### Changed
- Removed deprecated Config class (replaced by AgentConfig)
- Removed confirm_edits permission mode
- Removed keep_recent_messages configuration
- Removed default model value

### Fixed
- Use ToolCallError instead of generic Error in tool registry
- Handle AgentInterrupted exception during idle compression
- Handle XML tag contamination in JSON tool parameters
- Prevent modal flickering on validation failure
- Update agent client when switching models to prevent stale config
- Update is_safe_operation to not use removed editing_tool? method

### More
- Optimize markdown horizontal rule rendering
- Add debug logging throughout codebase

## [0.7.0] - 2026-02-06

This is a major release with significant improvements to skill system, conversation memory management, and user experience.

### 🎯 Major Features

**Skill System**
- Complete skill framework allowing users to extend AI capabilities with custom workflows
- Skills can be invoked using shorthand syntax (e.g., `/commit`, `/gem-release`)
- Support for user-created skills in `.clacky/skills/` directory
- Built-in skills: commit (smart Git helper), gem-release (automated publishing)

**Memory Compression**
- Intelligent message compression to handle long conversations efficiently
- LLM-based compression strategy that preserves context while reducing tokens
- Automatic compression triggered based on message count and token usage
- Significant reduction in API costs for extended sessions

**Configuration Improvements**
- API key validation on startup with helpful prompts
- Interactive configuration UI with modal components
- Source tracking for configuration (file, environment, defaults)
- Better error messages and user guidance

### Added
- Request user feedback tool for interactive prompts during execution
- Version display in welcome banner
- File size limits for file_reader tool to prevent performance issues
- Debug logging throughout the codebase

### Improved
- CLI output formatting and readability
- Error handling with comprehensive debug information
- Test coverage with 367 passing tests
- Tool call output optimization for cleaner logs

### Changed
- Simplified CLI architecture by removing unused code
- Enhanced modal component with new configuration features

### Fixed
- Message compression edge cases
- Various test spec improvements

## [0.6.4] - 2026-02-03

### Added
- Anthropic API support with full Claude model integration
- ClaudeCode environment compatibility (ANTHROPIC_API_KEY support)
- Model configuration with Anthropic defaults (claude-3-5-sonnet-20241022)
- Enhanced error handling with AgentError and ToolCallError classes
- format_tool_results for tool result formatting in agent execution
- Comprehensive test suite for Anthropic API and configuration
- Absolute path handling in glob tool

### Improved
- API client architecture for multi-provider support (OpenAI + Anthropic)
- Config loading with source tracking (file, ClaudeCode, default)
- Agent execution loop with improved tool result handling
- Edit tool with improved pattern matching
- User tip display in terminal

### Changed
- Refactored Error class to AgentError base class
- Renamed connection methods for clarity (connection → openai_connection)

### Fixed
- Handle absolute paths correctly in glob tool

## [0.6.3] - 2026-02-01

### Added
- Complete skill system with loader and core functionality
- Default skill support with auto-loading mechanism
- Skills CLI command for skill management (`clacky skills list/show/create`)
- Command suggestions UI component for better user guidance
- Skip safety check option for safe_shell tool
- UI2 component comprehensive test suite
- Token output control for file_reader and shell tools
- Grep max files limit configuration
- File_reader tool index support
- Web fetch content length limiting

### Improved
- File_reader line range handling logic
- Message compression strategy (100 message compress)
- Inline input wrap line handling
- Cursor position calculation for multi-line inline input
- Theme adjustments for better visual experience
- Skill system integration with agent
- Gem-release skill metadata standardization
- Skill documentation with user experience summaries

### Fixed
- Skill commands now properly pass through to agent
- Session restore data loading with -a or -c flags
- Inline input cursor positioning for wrapped lines
- Multi-line inline input cursor calculation

## [0.6.2] - 2026-01-30

### Added
- `--theme` CLI option to switch UI themes (hacker, minimal)
- Support for reading binary files (with 5MB limit)
- Cost color coding for better visibility
- Install script for easier installation
- New command handling improvements

### Improved
- User input style enhancements
- Tool execution output simplification
- Thinking mode output improvements
- Diff format display with cleaner line numbers
- Terminal resize handling

### Fixed
- BadQuotedString parsing error
- Token counting for every new task
- Shell output max characters limit
- Inline input cursor positioning
- Compress message display (now hidden)

### Removed
- Redundant output components for cleaner architecture

## [0.6.1] - 2026-01-29

### Added
- User tips for better guidance and feedback
- Batch TODO operations for improved task management
- Markdown output support for better formatted responses
- Text style customization options

### Improved
- Tool execution with slow progress indicators for long-running operations
- Progress UI refinements for better visual feedback
- Session restore now shows recent messages for context
- TODO area UI enhancements with auto-hide when all tasks completed
- Work status bar styling improvements
- Text wrapping when moving input to output area
- Safe shell output improvements for better readability
- Task info display optimization (only show essential information)
- TODO list cleanup and organization

### Fixed
- Double paste bug causing duplicate input
- Double error message display issue
- TODO clear functionality
- RSpec test hanging issues

### Removed
- Tool emoji from output for cleaner display

## [0.6.0] - 2026-01-28

### Added
- **New UI System (UI2)**: Complete component-based UI rewrite with modular architecture (InputArea, OutputArea, TodoArea, ToolComponent, ScreenBuffer, LayoutManager)
- **Slash Commands**: `/help`, `/clear`, `/exit` for quick actions
- **Prompt Caching**: Significantly improved performance and reduced API costs
- **Theme System**: Support for multiple UI themes (base, hacker, minimal)
- **Session Management**: Auto-keep last 10 sessions with datetime naming

### Improved
- Advanced inline input with Unicode support, multi-line handling, smooth scrolling, and rapid paste detection
- Better terminal resize handling and flicker-free rendering
- Work/idle status indicators with token cost display
- Enhanced tool execution feedback and multiple tool rejection handling
- Tool improvements: glob limits, grep performance, safe shell security, UTF-8 encoding fixes

### Fixed
- Input flickering, output scrolling, Ctrl+C behavior, image copying, base64 warnings, prompt cache issues

### Removed
- Legacy UI components (Banner, EnhancedPrompt, Formatter, StatusBar)
- Max cost/iteration limits for better flexibility

## [0.5.6] - 2026-01-18

### Added
- **Image Support**: Added support for image handling with cost tracking and display
- **Enhanced Input Controls**: Added Emacs-like Ctrl+A/E navigation for input fields
- **Session Management**: Added `/clear` command to clear session history
- **Edit Mode Switching**: New feature to switch between different edit modes
- **File Operations**: Support for reading from home directory (`~/`) and current directory (`.`)
- **Image Management**: Ctrl+D hotkey to delete images functionality

### Improved
- **Cost Tracking**: Display detailed cost information at every turn for better transparency
- **Performance**: Test suite speed optimizations and performance improvements
- **Token Efficiency**: Reduced token usage in grep operations for cost savings

### Fixed
- Fixed system Cmd+V copy functionality for multi-line text
- Fixed input flickering issues during text editing
- Removed unnecessary blank lines from image handling

## [0.5.4] - 2026-01-16

### Added
- **Automatic Paste Detection**: Rapid input detection automatically identifies paste operations
- **Word Wrap Display**: Long input lines automatically wrap with scroll indicators (up to 15 visible lines)
- **Full-width Terminal Display**: Enhanced prompt box uses full terminal width for better visibility

### Improved
- **Smart Ctrl+C Handling**: First press clears content, second press (within 2s) exits
- **UTF-8 Encoding**: Better handling of multi-byte characters in clipboard operations
- **Cursor Positioning**: Improved cursor tracking in wrapped lines
- **Multi-line Paste**: Better display for pasted content with placeholder support

## [0.5.0] - 2026-01-11

### Added
- **Agent Mode**: Autonomous AI agent with tool execution capabilities
- **Built-in Tools**:
  - `safe_shell` - Safe shell command execution with security checks
  - `file_reader` - Read file contents
  - `write` - Create/overwrite files with diff preview
  - `edit` - Precise file editing with string replacement
  - `glob` - Find files using glob patterns
  - `grep` - Search file contents with regex
  - `web_search` - Search the web for information
  - `web_fetch` - Fetch and parse web pages
  - `todo_manager` - Task planning and tracking
  - `run_project` - Project dev server management
- **Session Management**: Save, resume, and list conversation sessions
- **Permission Modes**:
  - `auto_approve` - Automatically execute all tools
  - `confirm_safes` - Auto-execute safe operations, confirm risky ones
  - `confirm_edits` - Confirm file edits only
  - `confirm_all` - Confirm every tool execution
  - `plan_only` - Plan without executing
- **Cost Control**: Track and limit API usage costs
- **Message Compression**: Automatic conversation history compression
- **Project Rules**: Support for `.clackyrules`, `.cursorrules`, and `CLAUDE.md`
- **Interactive Confirmations**: Preview diffs and shell commands before execution
- **Hook System**: Extensible event hooks for customization

### Changed
- Refactored architecture to support autonomous agent capabilities
- Enhanced CLI with agent command and session management
- Improved error handling and retry logic for network failures
- Better progress indicators during API calls and compression

### Fixed
- API compatibility issues with different providers
- Session restoration with error recovery
- Tool execution feedback loop
- Safe shell command validation
- Edit tool string matching and preview

## [0.1.0] - 2025-12-27

### Added
- Initial release of Clacky
- Interactive chat mode for conversations with Claude
- Single message mode for quick queries
- Configuration management for API keys
- Support for Claude 3.5 Sonnet model
- Colorful terminal output with TTY components
- Secure API key storage in `~/.clacky/config.yml`
- Multi-turn conversation support with context preservation
- Command-line interface powered by Thor
- Comprehensive test suite with RSpec

### Features
- `clacky chat [MESSAGE]` - Start interactive chat or send single message
- `clacky config set` - Configure API key
- `clacky config show` - Display current configuration
- `clacky version` - Show version information
- Model selection via `--model` option

[Unreleased]: https://github.com/yafeilee/clacky/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/yafeilee/clacky/compare/v0.1.0...v0.5.0
[0.1.0]: https://github.com/yafeilee/clacky/releases/tag/v0.1.0
