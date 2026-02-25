# OpenClacky

[![Build](https://img.shields.io/github/actions/workflow/status/clacky-ai/open-clacky/main.yml?label=build&style=flat-square)](https://github.com/clacky-ai/open-clacky/actions)
[![Release](https://img.shields.io/gem/v/openclacky?label=release&style=flat-square&color=blue)](https://rubygems.org/gems/openclacky)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1.0-red?style=flat-square)](https://www.ruby-lang.org)
[![Downloads](https://img.shields.io/gem/dt/openclacky?label=downloads&style=flat-square&color=brightgreen)](https://rubygems.org/gems/openclacky)
[![License](https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square)](LICENSE.txt)

OpenClacky = Lovable + Supabase

## Features

- 💬 Interactive chat sessions with AI models
- 🤖 Autonomous AI agent with tool use capabilities
- 📝 Enhanced input with multi-line support and Unicode (Chinese, etc.)
- 🖼️ Paste images from clipboard (macOS/Linux)
- 🚀 Single-message mode for quick queries
- 🔐 Secure API key management
- 📝 Multi-turn conversation support
- 🎨 Colorful terminal output
- 🌐 OpenAI-compatible API support (OpenAI, Gitee AI, DeepSeek, etc.)
- 🛠️ Rich built-in tools: file operations, web search, code execution, and more
- ⚡ Prompt caching support for Claude models (reduces costs up to 90%)

## Installation

### Quick Install (Recommended)

**One-line installation** (auto-detects your system):

```bash
curl -sSL https://raw.githubusercontent.com/clacky-ai/open-clacky/main/scripts/install.sh | bash
```

This script will:
- Check your Ruby version
- Install via Homebrew (macOS) if available
- Install via RubyGems if Ruby >= 3.1.0 is installed
- Guide you to install Ruby if needed

### Method 1: Homebrew (macOS/Linux)

**Best for macOS users** - Automatically handles Ruby dependencies:

```bash
brew tap clacky-ai/openclacky
brew install openclacky
```

### Method 2: RubyGems (If you already have Ruby >= 3.1.0)

```bash
gem install openclacky
```

### Method 3: From Source (For Development)

```bash
git clone https://github.com/clacky-ai/open-clacky.git
cd open-clacky
bundle install
bin/clacky
```

### System Requirements

- **Ruby**: >= 3.1.0 (automatically handled by Homebrew)
- **OS**: macOS, Linux, or Windows (WSL)

### Uninstallation

```bash
# Quick uninstall
curl -sSL https://raw.githubusercontent.com/clacky-ai/open-clacky/main/scripts/uninstall.sh | bash

# Or manually
brew uninstall openclacky  # If installed via Homebrew
gem uninstall openclacky   # If installed via gem
```

## Configuration

Before using Clacky, you need to configure your settings:

```bash
clacky config set
```

You'll be prompted to enter:
- **API Key**: Your API key from any OpenAI-compatible provider
- **Model**: Model name (e.g., `gpt-4`, `deepseek-chat`)
- **Base URL**: OpenAI-compatible API endpoint (e.g., `https://api.openai.com/v1`)

To view your current configuration:

```bash
clacky config show
```

## Usage

### AI Agent Mode (Interactive)

Run an autonomous AI agent in interactive mode. The agent can use tools to complete tasks and runs in a continuous loop, allowing you to have multi-turn conversations with tool use capabilities.

```bash
# Start interactive agent (will prompt for tasks)
clacky agent

# Start with an initial task, then continue interactively
clacky agent "Create a README.md file for my project"

# Auto-approve all tool executions
clacky agent --mode=auto_approve

# Work in a specific project directory
clacky agent --path /path/to/project

#### Permission Modes

- `auto_approve` - Automatically execute all tools (use with caution)
- `confirm_safes` - Auto-approve read-only tools, confirm edits
- `plan_only` - Generate plan without executing

#### Agent Options

```bash
--path PATH                    # Project directory (defaults to current directory)
--mode MODE                    # Permission mode
--verbose                      # Show detailed output
```

#### Cost Control & Memory Management

The agent includes intelligent cost control features:

- **Automatic Message Compression**: When conversation history grows beyond 100 messages, the agent automatically compresses older messages into a summary, keeping only the system prompt and the most recent 20 messages. This dramatically reduces token costs for long-running tasks (achieves ~60% compression ratio).

- **Compression Settings**:
  - `enable_compression`: Enable/disable automatic compression (default: true)
  - `keep_recent_messages`: Number of recent messages to preserve (default: 20)
  - Compression triggers at: ~100 messages (keep_recent_messages + 80)

### List Available Tools

View all built-in tools:

```bash
clacky tools
```

#### Built-in Tools

- **todo_manager** - Manage TODO items for task planning and tracking
- **file_reader** - Read file contents
- **write** - Create or overwrite files
- **edit** - Make precise edits to existing files
- **glob** - Find files by pattern matching
- **grep** - Search file contents with regex
- **shell** - Execute shell commands
- **web_search** - Search the web for information
- **web_fetch** - Fetch and parse web page content

### Available Commands

```bash
clacky agent [MESSAGE]    # Run autonomous agent with tool use
clacky tools              # List available tools
clacky config set         # Set your API key
clacky config show        # Show current configuration
clacky version            # Show clacky version
clacky help               # Show help information
```

## Examples

### Agent Examples

```bash
# Start interactive agent session
clacky agent
# Then type tasks interactively:
# > Create a TODO.md file with 3 example tasks
# > Now add more items to the TODO list
# > exit

# Auto-approve mode for trusted operations
clacky agent --mode=auto_approve --path ~/my-project
# > Count all lines of code
# > Create a summary report
# > exit

# Using TODO manager for complex tasks
clacky agent "Implement a new feature with user authentication"
# Agent will:
# 1. Use todo_manager to create a task plan
# 2. Add todos: "Research current auth patterns", "Design auth flow", etc.
# 3. Complete each todo step by step
# 4. Mark todos as completed as work progresses
# > exit
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

### Testing Agent Features

After making changes to agent-related functionality (tools, system prompts, agent logic, etc.), test with this command:

```bash
# Test agent with a complex multi-step task using auto-approve mode
echo "Create a simple calculator project with index.html, style.css, and script.js files" | \
  bin/clacky agent --mode=auto_approve --path=tmp --max-iterations=20

# Expected: Agent should plan tasks (add TODOs), execute them (create files),
# and track progress (mark TODOs as completed)
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/clacky-ai/open-clacky. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/clacky-ai/open-clacky/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the OpenClacky project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/clacky-ai/open-clacky/blob/main/CODE_OF_CONDUCT.md).
