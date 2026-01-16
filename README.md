# OpenClacky

A command-line interface for interacting with AI models. OpenClacky supports OpenAI-compatible APIs, making it easy to chat with various AI models directly from your terminal.

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

Install the gem by executing:

```bash
gem install openclacky
```

Or add it to your Gemfile:

```bash
bundle add openclacky
```

For development from source:

```bash
git clone https://github.com/clacky-ai/open-clacky.git
cd open-clacky
bundle install
bin/clacky
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

### Interactive Chat Mode

Start an interactive chat session:

```bash
clacky chat
```

Type your messages and press Enter. Type `exit` or `quit` to end the session.

### Single Message Mode

Send a single message and get a response:

```bash
clacky chat "What is Ruby?"
```

### Specify Model

You can specify which model to use (overrides config):

```bash
clacky chat --model=gpt-4 "Hello!"
```

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

# Limit tools available to the agent
clacky agent --tools file_reader glob grep
```

The agent will:
1. Complete each task using its React (Reason-Act-Observe) cycle
2. Show you the results
3. Wait for your next instruction
4. Maintain conversation context across tasks
5. Type 'exit' or 'quit' to end the session

#### Permission Modes

- `confirm_all` (default) - Confirm every tool use
- `confirm_edits` - Auto-approve read-only tools, confirm edits
- `auto_approve` - Automatically execute all tools (use with caution)
- `plan_only` - Generate plan without executing

#### Agent Options

```bash
--path PATH                    # Project directory (defaults to current directory)
--mode MODE                    # Permission mode
--tools TOOL1 TOOL2            # Allowed tools (or "all")
--max-iterations N             # Maximum iterations (default: 50)
--max-cost N                   # Maximum cost in USD (default: 5.0)
--verbose                      # Show detailed output
```

#### Cost Control & Memory Management

The agent includes intelligent cost control features:

- **Automatic Message Compression**: When conversation history grows beyond 100 messages, the agent automatically compresses older messages into a summary, keeping only the system prompt and the most recent 20 messages. This dramatically reduces token costs for long-running tasks (achieves ~60% compression ratio).

- **Configurable Limits**:
  - `max_iterations`: Maximum number of agent loops (default: 200)
  - `max_cost_usd`: Maximum total cost in USD (default: $5.00)
  - `timeout_seconds`: Maximum execution time (default: none)

- **Compression Settings**:
  - `enable_compression`: Enable/disable automatic compression (default: true)
  - `keep_recent_messages`: Number of recent messages to preserve (default: 20)
  - Compression triggers at: ~100 messages (keep_recent_messages + 80)

Example with custom limits:
```bash
clacky agent --max-iterations=100 --max-cost=10.0 --verbose
```

### List Available Tools

View all built-in tools:

```bash
clacky tools

# Filter by category
clacky tools --category file_system
```

#### Built-in Tools

- **todo_manager** - Manage TODO items for task planning and tracking
- **file_reader** - Read file contents
- **write** - Create or overwrite files
- **edit** - Make precise edits to existing files
- **glob** - Find files by pattern matching
- **grep** - Search file contents with regex
- **shell** - Execute shell commands
- **calculator** - Perform mathematical calculations
- **web_search** - Search the web for information
- **web_fetch** - Fetch and parse web page content

### Available Commands

```bash
clacky chat [MESSAGE]     # Start a chat or send a single message
clacky agent [MESSAGE]    # Run autonomous agent with tool use
clacky tools              # List available tools
clacky config set         # Set your API key
clacky config show        # Show current configuration
clacky version            # Show clacky version
clacky help               # Show help information
```

## Examples

### Chat Examples

```bash
# Quick question
clacky chat "Explain closures in Ruby"

# Start interactive session
clacky chat

# Check version
clacky version
```

### Agent Examples

```bash
# Start interactive agent session
clacky agent
# Then type tasks interactively:
# > Create a TODO.md file with 3 example tasks
# > Now add more items to the TODO list
# > exit

# Start with initial task, then continue
clacky agent "Add a .gitignore file for Ruby projects"
# After completing, agent waits for next task
# > List all Ruby files
# > Count lines in each file
# > exit

# Auto-approve mode for trusted operations
clacky agent --mode=auto_approve --path ~/my-project
# > Count all lines of code
# > Create a summary report
# > exit

# Use specific tools only in interactive mode
clacky agent --tools file_reader glob grep
# > Find all TODO comments
# > Search for FIXME comments
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
