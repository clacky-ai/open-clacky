# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
