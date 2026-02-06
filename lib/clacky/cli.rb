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
      client = Clacky::Client.new(config.api_key, base_url: config.base_url, anthropic_format: config.anthropic_format?)

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

    no_commands do
      private def handle_config_command(ui_controller, client, agent_config)
        config = Clacky::Config.load

        # Show modal dialog for configuration
        result = ui_controller.show_config_modal(config)

        # If user cancelled, return early
        if result.nil?
          ui_controller.show_warning("Configuration cancelled")
          return
        end

        # Update config with non-empty values
        config.api_key = result[:api_key] unless result[:api_key].to_s.empty?
        config.model = result[:model] unless result[:model].to_s.empty?
        config.base_url = result[:base_url] unless result[:base_url].to_s.empty?

        # Save configuration
        config.save

        # Update client with new config
        client.instance_variable_set(:@api_key, config.api_key)
        client.instance_variable_set(:@base_url, config.base_url)

        # Update agent config model
        agent_config.model = config.model

        # Show success message in output
        masked_key = "#{config.api_key[0..7]}#{'*' * 20}#{config.api_key[-4..]}"
        ui_controller.show_success("Configuration saved successfully!")
        ui_controller.append_output("  API Key: #{masked_key}")
        ui_controller.append_output("  Model: #{config.model}")
        ui_controller.append_output("  Base URL: #{config.base_url}")
        ui_controller.append_output("")
      end

      private def build_agent_config(config)
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
        # Get a larger list to search through (for ID prefix matching)
        sessions = session_manager.list(current_dir: working_dir, limit: 100)

        if sessions.empty?
          say "No sessions found.", :yellow
          return nil
        end

        session_data = nil

        # Check if identifier is a number (index-based)
        # Heuristic: If it's a small number (1-99), treat as index; otherwise treat as session ID prefix
        if identifier.match?(/^\d+$/) && identifier.to_i <= 99
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

        # Set skill loader for command suggestions
        ui_controller.set_skill_loader(agent.skill_loader)

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
              saved_path = session_manager.save(session_data)

              # Show session saved message in output area (before stopping UI)
              session_id = session_data[:session_id][0..7]
              ui_controller.append_output("")
              ui_controller.append_output("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
              ui_controller.append_output("")
              ui_controller.append_output("Session saved: #{saved_path}")
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
          when "/config"
            handle_config_command(ui_controller, client, agent_config)
            next
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
      end

    end
  end
end
