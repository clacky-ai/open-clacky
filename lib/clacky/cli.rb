# frozen_string_literal: true

require "thor"
require "tty-prompt"
require "tty-spinner"
require "readline"

module Clacky
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    desc "chat [MESSAGE]", "Start a chat with Claude or send a single message"
    long_desc <<-LONGDESC
      Start an interactive chat session with Claude AI.

      If MESSAGE is provided, send it as a single message and exit.
      If no MESSAGE is provided, start an interactive chat session.

      Examples:
        $ clacky chat "What is Ruby?"
        $ clacky chat
    LONGDESC
    option :model, type: :string, desc: "Model to use (default from config)"
    def chat(message = nil)
      config = Clacky::Config.load

      unless config.api_key
        say "Error: API key not found. Please run 'clacky config set' first.", :red
        exit 1
      end

      if message
        # Single message mode
        send_single_message(message, config)
      else
        # Interactive mode
        start_interactive_chat(config)
      end
    end

    desc "version", "Show clacky version"
    def version
      say "Clacky version #{Clacky::VERSION}"
    end

    desc "agent [MESSAGE]", "Run agent in interactive mode with autonomous tool use"
    long_desc <<-LONGDESC
      Run an AI agent in interactive mode that can autonomously use tools to complete tasks.

      The agent runs in a continuous loop, allowing multiple tasks in one session.
      Each task is completed with its own React (Reason-Act-Observe) cycle.
      After completing a task, the agent waits for your next instruction.

      Permission modes:
        auto_approve    - Automatically execute all tools (use with caution)
        confirm_edits   - Auto-approve read-only tools, confirm edits
        confirm_all     - Confirm every tool use (default)
        plan_only       - Generate plan without executing

      Session management:
        -c, --continue  - Continue the most recent session for this directory
        -l, --list      - List recent sessions
        -a, --attach N  - Attach to session number N from the list

      Examples:
        $ clacky agent
        $ clacky agent "Create a README file"
        $ clacky agent --mode=auto_approve --path /path/to/project
        $ clacky agent --tools file_reader glob grep
        $ clacky agent -c
        $ clacky agent -l
        $ clacky agent -a 2
    LONGDESC
    option :mode, type: :string, default: "confirm_edits",
           desc: "Permission mode: auto_approve, confirm_edits, confirm_all, plan_only"
    option :tools, type: :array, default: ["all"], desc: "Allowed tools"
    option :max_iterations, type: :numeric, desc: "Maximum iterations (default: 50)"
    option :max_cost, type: :numeric, desc: "Maximum cost in USD (default: 5.0)"
    option :verbose, type: :boolean, default: false, desc: "Show detailed output"
    option :path, type: :string, desc: "Project directory path (defaults to current directory)"
    option :continue, type: :boolean, aliases: "-c", desc: "Continue most recent session"
    option :list, type: :boolean, aliases: "-l", desc: "List recent sessions"
    option :attach, type: :numeric, aliases: "-a", desc: "Attach to session by number"
    def agent(message = nil)
      config = Clacky::Config.load

      unless config.api_key
        say "Error: API key not found. Please run 'clacky config set' first.", :red
        exit 1
      end

      # Handle session listing
      if options[:list]
        list_sessions
        return
      end

      # Handle Ctrl+C gracefully - raise exception to be caught in the loop
      Signal.trap("INT") do
        Thread.main.raise(Clacky::AgentInterrupted, "Interrupted by user")
      end

      # Validate and get working directory
      working_dir = validate_working_directory(options[:path])

      # Build agent config
      agent_config = build_agent_config(config)
      client = Clacky::Client.new(config.api_key, base_url: config.base_url)

      # Handle session loading/continuation
      session_manager = Clacky::SessionManager.new
      agent = nil

      if options[:continue]
        agent = load_latest_session(client, agent_config, session_manager, working_dir)
      elsif options[:attach]
        agent = load_session_by_number(client, agent_config, session_manager, working_dir, options[:attach])
      end

      # Create new agent if no session loaded
      agent ||= Clacky::Agent.new(client, agent_config, working_dir: working_dir)

      # Change to working directory
      original_dir = Dir.pwd
      should_chdir = File.realpath(working_dir) != File.realpath(original_dir)
      Dir.chdir(working_dir) if should_chdir

      begin
        # Always run in interactive mode
        run_agent_interactive(agent, working_dir, agent_config, message, session_manager)
      rescue StandardError => e
        say "\n❌ Error: #{e.message}", :red
        say e.backtrace.first(5).join("\n"), :red if options[:verbose]
        exit 1
      ensure
        Dir.chdir(original_dir)
      end
    end

    desc "tools", "List available tools"
    option :category, type: :string, desc: "Filter by category"
    def tools
      registry = ToolRegistry.new
      registry.register(Tools::Calculator.new)
      registry.register(Tools::Shell.new)
      registry.register(Tools::FileReader.new)
      registry.register(Tools::Write.new)
      registry.register(Tools::Edit.new)
      registry.register(Tools::Glob.new)
      registry.register(Tools::Grep.new)
      registry.register(Tools::WebSearch.new)
      registry.register(Tools::WebFetch.new)

      say "\n📦 Available Tools:\n\n", :green

      tools_to_show = if options[:category]
                        registry.by_category(options[:category])
                      else
                        registry.all
                      end

      tools_to_show.each do |tool|
        say "  #{tool.name}", :cyan
        say "    #{tool.description}", :white
        say "    Category: #{tool.category}", :yellow

        if tool.parameters[:properties]
          say "    Parameters:", :yellow
          tool.parameters[:properties].each do |name, spec|
            required = tool.parameters[:required]&.include?(name.to_s) ? " (required)" : ""
            say "      - #{name}: #{spec[:description]}#{required}", :white
          end
        end
        say ""
      end

      say "Total: #{tools_to_show.size} tools\n", :green
    end

    no_commands do
      def build_agent_config(config)
        AgentConfig.new(
          model: options[:model] || config.model,
          permission_mode: options[:mode].to_sym,
          allowed_tools: options[:tools],
          max_iterations: options[:max_iterations],
          max_cost_usd: options[:max_cost],
          verbose: options[:verbose]
        )
      end

      def prompt_for_input
        prompt = TTY::Prompt.new
        prompt.ask("What would you like the agent to do?", required: true)
      end

      def display_agent_event(event)
      case event[:type]
      when :thinking
        print "💭 Thinking... "
      when :tool_call
        data = event[:data]
        say "\n🔧 Using tool: #{data[:name]}", :yellow
        say "   Arguments: #{data[:arguments]}", :white if options[:verbose]
      when :observation
        data = event[:data]
        say "👀 Result from #{data[:tool]}:", :cyan
        result_preview = data[:result].to_s[0..200]
        say "   #{result_preview}#{'...' if data[:result].to_s.length > 200}", :white
      when :answer
        say "\n✅ Agent: #{event[:data][:content]}", :green
      when :tool_denied
        say "\n🚫 Tool denied: #{event[:data][:name]}", :red
      when :tool_planned
        say "\n📋 Planned: #{event[:data][:name]}", :blue
      when :tool_error
        say "\n❌ Tool error: #{event[:data][:error].message}", :red
      when :on_iteration
        say "\n--- Iteration #{event[:data][:iteration]} ---", :yellow if options[:verbose]
      end
    end

      def display_agent_result(result)
        say "\n" + ("=" * 60), :cyan
        say "Agent Session Complete", :green
        say "=" * 60, :cyan
        say "Status: #{result[:status]}", :green
        say "Iterations: #{result[:iterations]}", :yellow
        say "Duration: #{result[:duration_seconds].round(2)}s", :yellow
        say "Total Cost: $#{result[:total_cost_usd]}", :yellow
        say "=" * 60, :cyan
      end

      def validate_working_directory(path)
        working_dir = path || Dir.pwd

        # Expand path to absolute path
        working_dir = File.expand_path(working_dir)

        # Validate directory exists
        unless Dir.exist?(working_dir)
          say "Error: Directory does not exist: #{working_dir}", :red
          exit 1
        end

        # Validate it's a directory
        unless File.directory?(working_dir)
          say "Error: Path is not a directory: #{working_dir}", :red
          exit 1
        end

        working_dir
      end

      def run_in_directory(directory)
        original_dir = Dir.pwd

        begin
          Dir.chdir(directory)
          yield
        ensure
          Dir.chdir(original_dir)
        end
      end

      def run_agent_interactive(agent, working_dir, agent_config, initial_message = nil, session_manager = nil)
        # Show session info if continuing
        if agent.total_tasks > 0
          say "📂 Continuing session: #{agent.session_id[0..7]}", :green
          say "   Created: #{Time.parse(agent.created_at).strftime('%Y-%m-%d %H:%M')}", :cyan
          say "   Tasks completed: #{agent.total_tasks}", :cyan
          say "   Total cost: $#{agent.total_cost.round(4)}", :cyan
          say ""

          # Show recent conversation history
          display_recent_messages(agent.messages, limit: 5)
        end

        say "🤖 Starting interactive agent mode...", :green
        say "Working directory: #{working_dir}", :cyan
        say "Mode: #{agent_config.permission_mode}", :yellow
        say "Max iterations: #{agent_config.max_iterations} per task", :yellow
        say "Max cost: $#{agent_config.max_cost_usd} per task", :yellow
        say "\nType 'exit' or 'quit' to end the session.\n", :yellow

        prompt = TTY::Prompt.new
        total_tasks = agent.total_tasks
        total_cost = agent.total_cost

        # Process initial message if provided
        current_message = initial_message

        loop do
          # Get message from user if not provided
          unless current_message && !current_message.strip.empty?
            say "\n" if total_tasks > 0

            # Use Readline for better Unicode/CJK support
            current_message = Readline.readline("You: ", true)

            break if current_message.nil? || %w[exit quit].include?(current_message&.downcase&.strip)
            next if current_message.strip.empty?
          end

          total_tasks += 1
          say "\n"

          begin
            result = agent.run(current_message) do |event|
              display_agent_event(event)
            end

            total_cost += result[:total_cost_usd]

            # Save session after each task
            if session_manager
              session_manager.save(agent.to_session_data)
            end

            # Show brief task completion
            say "\n" + ("-" * 60), :cyan
            say "✓ Task completed", :green
            say "  Iterations: #{result[:iterations]}", :white
            say "  Cost: $#{result[:total_cost_usd].round(4)}", :white
            say "  Session total: #{total_tasks} tasks, $#{total_cost.round(4)}", :yellow
            say "-" * 60, :cyan
          rescue Clacky::AgentInterrupted
            # Save session on interruption
            if session_manager
              session_manager.save(agent.to_session_data)
            end

            # User pressed Ctrl+C - stop current task but don't exit
            say "\n\n⚠️  Task interrupted by user (Ctrl+C)", :yellow
            say "Session saved. You can start a new task or type 'exit' to quit.\n", :yellow
          rescue StandardError => e
            say "\n❌ Error: #{e.message}", :red
            say e.backtrace.first(3).join("\n"), :white if options[:verbose]
            say "\nYou can continue with a new task or type 'exit' to quit.", :yellow
          end

          # Clear current_message to prompt for next input
          current_message = nil
        end

        # Save final session state
        if session_manager
          session_manager.save(agent.to_session_data)
        end

        say "\n👋 Agent session ended", :green
        say "Total tasks completed: #{total_tasks}", :cyan
        say "Total cost: $#{total_cost.round(4)}", :cyan
      end

      def list_sessions
        session_manager = Clacky::SessionManager.new
        working_dir = validate_working_directory(options[:path])
        sessions = session_manager.list(current_dir: working_dir, limit: 5)

        if sessions.empty?
          say "No sessions found.", :yellow
          return
        end

        say "\n📋 Recent sessions:\n", :green
        sessions.each_with_index do |session, index|
          created_at = Time.parse(session[:created_at]).strftime("%Y-%m-%d %H:%M")
          session_id = session[:session_id][0..7]
          tasks = session.dig(:stats, :total_tasks) || 0
          cost = session.dig(:stats, :total_cost_usd) || 0.0
          first_msg = session[:first_user_message] || "No message"
          is_current_dir = session[:working_dir] == working_dir

          dir_marker = is_current_dir ? "📍" : "  "
          say "#{dir_marker} #{index + 1}. [#{session_id}] #{created_at} (#{tasks} tasks, $#{cost.round(4)}) - #{first_msg}", :cyan
        end
        say ""
      end

      def load_latest_session(client, agent_config, session_manager, working_dir)
        session_data = session_manager.latest_for_directory(working_dir)

        if session_data.nil?
          say "No previous session found for this directory.", :yellow
          return nil
        end

        say "Loading latest session: #{session_data[:session_id][0..7]}", :green
        Clacky::Agent.from_session(client, agent_config, session_data)
      end

      def load_session_by_number(client, agent_config, session_manager, working_dir, number)
        sessions = session_manager.list(current_dir: working_dir, limit: 10)

        if sessions.empty?
          say "No sessions found.", :yellow
          return nil
        end

        index = number - 1
        if index < 0 || index >= sessions.size
          say "Invalid session number. Use -l to list available sessions.", :red
          exit 1
        end

        session_data = sessions[index]
        say "Loading session: #{session_data[:session_id][0..7]}", :green
        Clacky::Agent.from_session(client, agent_config, session_data)
      end

      def display_recent_messages(messages, limit: 5)
        # Filter out user and assistant messages (exclude system and tool messages)
        conversation_messages = messages.select { |m| m[:role] == "user" || m[:role] == "assistant" }

        # Get the last N messages
        recent = conversation_messages.last(limit * 2) # *2 to get user+assistant pairs

        if recent.empty?
          return
        end

        say "📜 Recent conversation history:\n", :yellow
        say "-" * 60, :white

        recent.each do |msg|
          case msg[:role]
          when "user"
            content = truncate_message(msg[:content], 150)
            say "\n👤 You: #{content}", :cyan
          when "assistant"
            content = truncate_message(msg[:content], 200)
            say "🤖 Assistant: #{content}", :green
          end
        end

        say "\n" + ("-" * 60), :white
        say ""
      end

      def truncate_message(content, max_length)
        return "" if content.nil? || content.empty?

        # Remove excessive whitespace
        cleaned = content.strip.gsub(/\s+/, ' ')

        if cleaned.length > max_length
          cleaned[0...max_length] + "..."
        else
          cleaned
        end
      end
    end

    private

    def send_single_message(message, config)
      spinner = TTY::Spinner.new("[:spinner] Thinking...", format: :dots)
      spinner.auto_spin

      client = Clacky::Client.new(config.api_key, base_url: config.base_url)
      response = client.send_message(message, model: options[:model] || config.model)

      spinner.success("Done!")
      say "\n#{response}", :cyan
    rescue StandardError => e
      spinner.error("Failed!")
      say "Error: #{e.message}", :red
      exit 1
    end

    def start_interactive_chat(config)
      say "Starting interactive chat with Claude...", :green
      say "Type 'exit' or 'quit' to end the session.\n\n", :yellow

      conversation = Clacky::Conversation.new(
        config.api_key,
        model: options[:model] || config.model,
        base_url: config.base_url
      )

      loop do
        # Use Readline for better Unicode/CJK support
        message = Readline.readline("You: ", true)

        break if message.nil? || %w[exit quit].include?(message.downcase.strip)
        next if message.strip.empty?

        spinner = TTY::Spinner.new("[:spinner] Claude is thinking...", format: :dots)
        spinner.auto_spin

        begin
          response = conversation.send_message(message)
          spinner.success("Claude:")
          say response, :cyan
          say "\n"
        rescue StandardError => e
          spinner.error("Error!")
          say "Error: #{e.message}", :red
        end
      end

      say "\nGoodbye!", :green
    end
  end

  class ConfigCommand < Thor
    desc "set", "Set configuration values"
    def set
      prompt = TTY::Prompt.new

      config = Clacky::Config.load

      # API Key
      api_key = prompt.mask("Enter your Claude API key:")
      config.api_key = api_key

      # Model
      model = prompt.ask("Enter model:", default: config.model)
      config.model = model

      # Base URL
      base_url = prompt.ask("Enter base URL:", default: config.base_url)
      config.base_url = base_url

      config.save

      say "\nConfiguration saved successfully!", :green
      say "API Key: #{api_key[0..7]}#{'*' * 20}#{api_key[-4..]}", :cyan
      say "Model: #{config.model}", :cyan
      say "Base URL: #{config.base_url}", :cyan
    end

    desc "show", "Show current configuration"
    def show
      config = Clacky::Config.load

      if config.api_key
        masked_key = config.api_key[0..7] + ("*" * 20) + config.api_key[-4..]
        say "API Key: #{masked_key}", :cyan
        say "Model: #{config.model}", :cyan
        say "Base URL: #{config.base_url}", :cyan
      else
        say "No configuration found. Run 'clacky config set' to configure.", :yellow
      end
    end
  end

  # Register subcommands after all classes are defined
  CLI.register(ConfigCommand, "config", "config SUBCOMMAND", "Manage configuration")
end
