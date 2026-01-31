# frozen_string_literal: true

require "thor"
require "tty-prompt"
require_relative "ui2"

module Clacky
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    # Set agent as the default command
    default_task :agent

    desc "version", "Show clacky version"
    def version
      say "Clacky version #{Clacky::VERSION}"
    end

    desc "agent [MESSAGE]", "Run agent in interactive mode with autonomous tool use (default)"
    long_desc <<-LONGDESC
      Run an AI agent in interactive mode that can autonomously use tools to complete tasks.

      The agent runs in a continuous loop, allowing multiple tasks in one session.
      Each task is completed with its own React (Reason-Act-Observe) cycle.
      After completing a task, the agent waits for your next instruction.

      Permission modes:
        auto_approve    - Automatically execute all tools (use with caution)
        confirm_safes   - Auto-approve safe operations, confirm risky ones (default)
        confirm_edits   - Auto-approve read-only tools, confirm edits
        plan_only       - Generate plan without executing

      UI themes:
        hacker          - Matrix/hacker-style with bracket symbols (default)
        minimal         - Clean, simple symbols

      Session management:
        -c, --continue  - Continue the most recent session for this directory
        -l, --list      - List recent sessions
        -a, --attach N  - Attach to session by number (e.g., -a 2) or session ID prefix (e.g., -a b6682a87)

      Examples:
        $ clacky agent --mode=auto_approve --path /path/to/project
    LONGDESC
    option :mode, type: :string, default: "confirm_safes",
           desc: "Permission mode: auto_approve, confirm_safes, confirm_edits, plan_only"
    option :theme, type: :string, default: "hacker",
           desc: "UI theme: hacker, minimal (default: hacker)"
    option :verbose, type: :boolean, aliases: "-v", default: false, desc: "Show detailed output"
    option :path, type: :string, desc: "Project directory path (defaults to current directory)"
    option :continue, type: :boolean, aliases: "-c", desc: "Continue most recent session"
    option :list, type: :boolean, aliases: "-l", desc: "List recent sessions"
    option :attach, type: :string, aliases: "-a", desc: "Attach to session by number or keyword"
    option :help, type: :boolean, aliases: "-h", desc: "Show this help message"
    def agent(message = nil)
      # Handle help option
      if options[:help]
        invoke :help, ["agent"]
        return
      end
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
      is_session_load = false

      if options[:continue]
        agent = load_latest_session(client, agent_config, session_manager, working_dir)
        is_session_load = !agent.nil?
      elsif options[:attach]
        agent = load_session_by_number(client, agent_config, session_manager, working_dir, options[:attach])
        is_session_load = !agent.nil?
      end

      # Create new agent if no session loaded
      agent ||= Clacky::Agent.new(client, agent_config, working_dir: working_dir)

      # Change to working directory
      original_dir = Dir.pwd
      should_chdir = File.realpath(working_dir) != File.realpath(original_dir)
      Dir.chdir(working_dir) if should_chdir

      begin
        run_agent_with_ui2(agent, working_dir, agent_config, message, session_manager, client, is_session_load: is_session_load)
      rescue StandardError => e
        # Save session on error
        if session_manager
          session_manager.save(agent.to_session_data(status: :error, error_message: e.message))
        end

        # Report the error
        say "\n❌ Error: #{e.message}", :red
        say e.backtrace.first(5).join("\n"), :red if options[:verbose]

        # Show session saved message
        if session_manager&.last_saved_path
          say "\n📂 Session saved: #{session_manager.last_saved_path}", :yellow
        end

        # Guide user to recover
        say "\n💡 To recover and retry, run:", :yellow
        say "   clacky agent -c", :cyan

        exit 1
      ensure
        Dir.chdir(original_dir)
      end
    end

    desc "new PROJECT_NAME", "Create a new Rails project from the official template"
    long_desc <<-LONGDESC
      Create a new Rails project from the official template.

      This command will:
        1. Clone the template from git@github.com:clacky-ai/rails-template-7x-starter.git
        2. Change into the project directory
        3. Run bin/setup to install dependencies and configure the project

      Example:
        $ clacky new my_rails_app
    LONGDESC
    def new(project_name = nil)
      unless project_name
        say "Error: Project name is required.", :red
        say "Usage: clacky new <project_name>", :yellow
        exit 1
      end

      # Validate project name
      unless project_name.match?(/^[a-zA-Z][a-zA-Z0-9_-]*$/)
        say "Error: Invalid project name. Use only letters, numbers, underscores, and hyphens.", :red
        exit 1
      end

      template_repo = "git@github.com:clacky-ai/rails-template-7x-starter.git"
      current_dir = Dir.pwd
      target_dir = File.join(current_dir, project_name)

      # Check if target directory already exists
      if Dir.exist?(target_dir)
        say "Error: Directory '#{project_name}' already exists.", :red
        exit 1
      end

      say "Creating new Rails project: #{project_name}", :green

      # Clone the template repository
      say "\n📦 Cloning template repository...", :cyan
      clone_command = "git clone #{template_repo} #{project_name}"

      clone_result = system(clone_command)

      unless clone_result
        say "\n❌ Failed to clone repository. Please check your git configuration and network connection.", :red
        exit 1
      end

      say "✓ Repository cloned successfully", :green

      # Run bin/setup
      say "\n⚙️  Running bin/setup...", :cyan

      Dir.chdir(target_dir)

      setup_command = "./bin/setup"

      setup_result = system(setup_command)

      Dir.chdir(current_dir)

      unless setup_result
        say "\n❌ Failed to run bin/setup. Please check the setup script for errors.", :red
        say "You can try running it manually:", :yellow
        say "  cd #{project_name} && ./bin/setup", :cyan
        exit 1
      end

      say "\n✅ Project '#{project_name}' created successfully!", :green
      say "\nNext steps:", :green
      say "  cd #{project_name}", :cyan
      say "  clacky agent", :cyan
    end

    desc "price", "Show pricing information for AI models"
    def price
      say "\n💰 Model Pricing Information\n\n", :green

      say "Clacky supports three pricing modes when calculating API costs:\n\n", :white

      say "  1. ", :cyan
      say "API-provided cost", :bold
      say " (", :white
      say ":api", :yellow
      say ")", :white
      say "\n     The most accurate - uses actual cost data from the API response", :white
      say "\n     Supported by: OpenRouter, LiteLLM, and other compatible proxies\n\n"

      say "  2. ", :cyan
      say "Model-specific pricing", :bold
      say " (", :white
      say ":price", :yellow
      say ")", :white
      say "\n     Uses official pricing from model providers (Claude models)", :white
      say "\n     Includes tiered pricing and prompt caching discounts\n\n"

      say "  3. ", :cyan
      say "Default fallback pricing", :bold
      say " (", :white
      say ":default", :yellow
      say ")", :white
      say "\n     Conservative estimates for unknown models", :white
      say "\n     Input: $0.50/MTok, Output: $1.50/MTok\n\n"

      say "Priority order: API cost > Model pricing > Default pricing\n\n", :yellow

      say "Supported models with official pricing:\n", :green
      say "  • claude-opus-4.5\n", :cyan
      say "  • claude-sonnet-4.5\n", :cyan
      say "  • claude-haiku-4.5\n", :cyan
      say "  • claude-3-5-sonnet-20241022\n", :cyan
      say "  • claude-3-5-sonnet-20240620\n", :cyan
      say "  • claude-3-5-haiku-20241022\n\n", :cyan

      say "For detailed pricing information, visit:\n", :white
      say "https://www.anthropic.com/pricing\n\n", :blue
    end

    no_commands do
      def build_agent_config(config)
        AgentConfig.new(
          model: options[:model] || config.model,
          permission_mode: options[:mode].to_sym,
          verbose: options[:verbose]
        )
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

        # Don't print message here - will be shown by UI after banner
        Clacky::Agent.from_session(client, agent_config, session_data)
      end

      def load_session_by_number(client, agent_config, session_manager, working_dir, identifier)
        sessions = session_manager.list(current_dir: working_dir, limit: 10)

        if sessions.empty?
          say "No sessions found.", :yellow
          return nil
        end

        session_data = nil

        # Check if identifier is a number (index-based)
        if identifier.match?(/^\d+$/)
          index = identifier.to_i - 1
          if index < 0 || index >= sessions.size
            say "Invalid session number. Use -l to list available sessions.", :red
            exit 1
          end
          session_data = sessions[index]
        else
          # Treat as session ID prefix
          matching_sessions = sessions.select { |s| s[:session_id].start_with?(identifier) }

          if matching_sessions.empty?
            say "No session found matching ID prefix: #{identifier}", :red
            say "Use -l to list available sessions.", :yellow
            exit 1
          elsif matching_sessions.size > 1
            say "Multiple sessions found matching '#{identifier}':", :yellow
            matching_sessions.each_with_index do |session, idx|
              created_at = Time.parse(session[:created_at]).strftime("%Y-%m-%d %H:%M")
              session_id = session[:session_id][0..7]
              first_msg = session[:first_user_message] || "No message"
              say "  #{idx + 1}. [#{session_id}] #{created_at} - #{first_msg}", :cyan
            end
            say "\nPlease use a more specific prefix.", :yellow
            exit 1
          else
            session_data = matching_sessions.first
          end
        end

        # Don't print message here - will be shown by UI after banner
        Clacky::Agent.from_session(client, agent_config, session_data)
      end

      # Handle agent error/interrupt with cleanup
      def handle_agent_exception(ui_controller, agent, session_manager, exception)
        ui_controller.stop_progress_thread
        ui_controller.set_idle_status

        if exception.is_a?(Clacky::AgentInterrupted)
          session_manager&.save(agent.to_session_data(status: :interrupted))
          ui_controller.show_warning("Task interrupted by user")
        else
          error_message = "#{exception.message}\n#{exception.backtrace&.first(3)&.join("\n")}"
          session_manager&.save(agent.to_session_data(status: :error, error_message: error_message))
          ui_controller.show_error("Error: #{exception.message}")
        end
      end

      # Run agent with UI2 split-screen interface
      def run_agent_with_ui2(agent, working_dir, agent_config, initial_message = nil, session_manager = nil, client = nil, is_session_load: false)
        # Validate theme
        theme_name = options[:theme] || "hacker"
        available_themes = UI2::ThemeManager.available_themes.map(&:to_s)
        unless available_themes.include?(theme_name)
          say "Error: Unknown theme '#{theme_name}'. Available themes: #{available_themes.join(', ')}", :red
          exit 1
        end

        # Create UI2 controller with configuration
        ui_controller = UI2::UIController.new(
          working_dir: working_dir,
          mode: agent_config.permission_mode.to_s,
          model: agent_config.model,
          theme: theme_name
        )

        # Inject UI into agent
        agent.instance_variable_set(:@ui, ui_controller)

        # Track agent thread state
        agent_thread = nil

        # Set up mode toggle handler
        ui_controller.on_mode_toggle do |new_mode|
          agent_config.permission_mode = new_mode.to_sym
        end

        # Set up interrupt handler
        ui_controller.on_interrupt do |input_was_empty:|
          if (not agent_thread&.alive?) && input_was_empty
            # Save final session state before exit
            if session_manager && agent.total_tasks > 0
              session_data = agent.to_session_data(status: :exited)
              session_manager.save(session_data)

              # Show session saved message in output area (before stopping UI)
              session_id = session_data[:session_id][0..7]
              ui_controller.append_output("")
              ui_controller.append_output("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
              ui_controller.append_output("")
              ui_controller.append_output("Session saved: #{session_id}")
              ui_controller.append_output("Tasks completed: #{agent.total_tasks}")
              ui_controller.append_output("Total cost: $#{agent.total_cost.round(4)}")
              ui_controller.append_output("")
              ui_controller.append_output("To continue this session, run:")
              ui_controller.append_output("  clacky -a #{session_id}")
              ui_controller.append_output("")
            end

            # Stop UI and exit
            ui_controller.stop
            exit(0)
          end

          if agent_thread&.alive?
            agent_thread.raise(Clacky::AgentInterrupted, "User interrupted")
          end
          ui_controller.input_area.clear
          ui_controller.input_area.set_tips("Press Ctrl+C again to exit.", type: :info)
        end

        # Set up input handler
        ui_controller.on_input do |input, images|
          # Handle commands
          case input.downcase.strip
          when "/clear"
            # Clear session by creating a new agent
            agent = Clacky::Agent.new(client, agent_config, working_dir: working_dir, ui: ui_controller)
            ui_controller.show_info("Session cleared. Starting fresh.")
            # Update session bar with reset values
            ui_controller.update_sessionbar(tasks: agent.total_tasks, cost: agent.total_cost)
            # Clear todo area display
            ui_controller.update_todos([])
            next
          when "/exit", "/quit"
            ui_controller.stop
            exit(0)
          when "/help"
            ui_controller.show_help
            next
          end

          # If agent is already running, interrupt it first
          if agent_thread&.alive?
            agent_thread.raise(Clacky::AgentInterrupted, "New input received")
            agent_thread.join(2) # Wait up to 2 seconds for graceful shutdown
          end

          # Run agent in background thread
          agent_thread = Thread.new do
            begin
              # Set status to working when agent starts
              ui_controller.set_working_status

              # Run agent (Agent will call @ui methods directly)
              # Agent internally tracks total_tasks and total_cost
              result = agent.run(input, images: images)

              # Save session after each task
              if session_manager
                session_manager.save(agent.to_session_data(status: :success))
              end

              # Update session bar with agent's cumulative stats
              ui_controller.update_sessionbar(tasks: agent.total_tasks, cost: agent.total_cost)
            rescue Clacky::AgentInterrupted, StandardError => e
              handle_agent_exception(ui_controller, agent, session_manager, e)
            ensure
              agent_thread = nil
            end
          end
        end

        # Initialize UI screen first
        if is_session_load
          recent_user_messages = agent.get_recent_user_messages(limit: 5)
          ui_controller.initialize_and_show_banner(recent_user_messages: recent_user_messages)
          # Update session bar with restored agent stats
          ui_controller.update_sessionbar(tasks: agent.total_tasks, cost: agent.total_cost)
        else
          ui_controller.initialize_and_show_banner
        end

        # If there's an initial message, process it
        if initial_message && !initial_message.strip.empty?
          ui_controller.show_user_message(initial_message)

          begin
            # Set status to working when agent starts
            ui_controller.set_working_status

            result = agent.run(initial_message, images: [])

            if session_manager
              session_manager.save(agent.to_session_data(status: :success))
            end

            # Update session bar with agent's cumulative stats
            ui_controller.update_sessionbar(tasks: agent.total_tasks, cost: agent.total_cost)
          rescue Clacky::AgentInterrupted, StandardError => e
            handle_agent_exception(ui_controller, agent, session_manager, e)
          end
        end

        # Start input loop (blocks until exit)
        ui_controller.start_input_loop

        # Save final session state
        if session_manager && agent.total_tasks > 0
          session_manager.save(agent.to_session_data)
        end

        # Show goodbye message
        say "\n👋 Goodbye! Session stats:", :green
        say "   Tasks completed: #{agent.total_tasks}", :cyan
        say "   Total cost: $#{agent.total_cost.round(4)}", :cyan
      end

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
