# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
