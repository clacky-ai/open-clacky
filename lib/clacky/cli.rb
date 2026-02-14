# frozen_string_literal: true

require "thor"
require "tty-prompt"
require_relative "ui2"
require_relative "json_ui_controller"

module Clacky
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    # Set agent as the default command
    default_task :agent

    desc "agent", "Run agent in interactive mode with autonomous tool use (default)"
    long_desc <<-LONGDESC
      Run an AI agent in interactive mode that can autonomously use tools to complete tasks.

      The agent runs in a continuous loop, allowing multiple tasks in one session.
      Each task is completed with its own React (Reason-Act-Observe) cycle.
      After completing a task, the agent waits for your next instruction.

      Permission modes:
        auto_approve    - Automatically execute all tools (use with caution)
        confirm_safes   - Auto-approve safe operations, confirm risky ones (default)
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
           desc: "Permission mode: auto_approve, confirm_safes, plan_only"
    option :theme, type: :string, default: "hacker",
           desc: "UI theme: hacker, minimal (default: hacker)"
    option :verbose, type: :boolean, aliases: "-v", default: false, desc: "Show detailed output"
    option :path, type: :string, desc: "Project directory path (defaults to current directory)"
    option :continue, type: :boolean, aliases: "-c", desc: "Continue most recent session"
    option :list, type: :boolean, aliases: "-l", desc: "List recent sessions"
    option :attach, type: :string, aliases: "-a", desc: "Attach to session by number or keyword"
    option :json, type: :boolean, default: false, desc: "Output NDJSON to stdout (for scripting/piping)"
    option :help, type: :boolean, aliases: "-h", desc: "Show this help message"
    def agent
      # Handle help option
      if options[:help]
        invoke :help, ["agent"]
        return
      end
      agent_config = Clacky::AgentConfig.load

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

      # Update agent config with CLI options
      agent_config.permission_mode = options[:mode].to_sym if options[:mode]
      agent_config.verbose = options[:verbose] if options[:verbose]

      # Create client for current model
      client = Clacky::Client.new(agent_config.api_key, base_url: agent_config.base_url, anthropic_format: agent_config.anthropic_format?)

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
        if options[:json]
          run_agent_with_json(agent, working_dir, agent_config, session_manager, client)
        else
          run_agent_with_ui2(agent, working_dir, agent_config, session_manager, client, is_session_load: is_session_load)
        end
      ensure
        Dir.chdir(original_dir)
      end
    end

    no_commands do
      private def handle_config_command(ui_controller, client, agent_config, agent)
        config = agent_config

        # Create test callback
        test_callback = lambda do |test_config|
          # Create a temporary client with new config to test
          test_client = Clacky::Client.new(
            test_config.api_key,
            base_url: test_config.base_url,
            anthropic_format: test_config.anthropic_format?
          )

          # Test connection
          test_client.test_connection(model: test_config.model_name)
        end

        # Show modal dialog for configuration with test callback
        result = ui_controller.show_config_modal(config, test_callback: test_callback)

        # If user closed modal without changes, return early
        if result.nil?
          return
        end

        # Config was changed (either switch or edit), update client, agent, and UI
        # Update client with current model's config
        client.instance_variable_set(:@api_key, config.api_key)
        client.instance_variable_set(:@base_url, config.base_url)
        client.instance_variable_set(:@use_anthropic_format, config.anthropic_format?)

        # Update agent's client (agent has its own @client instance variable)
        agent.instance_variable_set(:@client, Clacky::Client.new(
          config.api_key,
          base_url: config.base_url,
          anthropic_format: config.anthropic_format?
        ))

        # Update agent's message compressor with new client
        agent.instance_variable_set(:@message_compressor,
          Clacky::MessageCompressor.new(agent.instance_variable_get(:@client), model: config.model_name)
        )

        # Update UI controller's model display
        ui_controller.config[:model] = config.model_name
        ui_controller.update_sessionbar(
          tasks: agent.total_tasks,
          cost: agent.total_cost
        )

        # Show success message in output
        masked_key = "#{config.api_key[0..7]}#{'*' * 20}#{config.api_key[-4..]}"
        ui_controller.show_success("Configuration updated!")
        ui_controller.append_output("  Current Model: #{config.model_name}")
        ui_controller.append_output("  API Key: #{masked_key}")
        ui_controller.append_output("  Base URL: #{config.base_url}")
        ui_controller.append_output("  Format: #{config.anthropic_format? ? 'Anthropic' : 'OpenAI'}")
        ui_controller.append_output("")
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
          last_msg = session[:last_user_message] || "No message"
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
              last_msg = session[:last_user_message] || "No message"
              say "  #{idx + 1}. [#{session_id}] #{created_at} - #{last_msg}", :cyan
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
        ui_controller.clear_progress
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

      # Run agent with JSON (NDJSON) output mode — persistent process.
      # Reads JSON messages from stdin, writes NDJSON events to stdout.
      # Stays alive until "/exit", {"type":"exit"}, or stdin EOF.
      #
      # Input protocol (one JSON per line on stdin):
      #   {"type":"message","content":"..."}          — run agent with this message
      #   {"type":"message","content":"...","images":["path"]} — with images
      #   {"type":"exit"}                             — graceful shutdown
      #   {"type":"confirmation","id":"conf_1","result":"yes"} — answer to request_confirmation
      #
      # If a bare string line is received it is treated as a message content.
      def run_agent_with_json(agent, working_dir, agent_config, session_manager, client)
        json_ui = Clacky::JsonUIController.new
        agent.instance_variable_set(:@ui, json_ui)

        json_ui.emit("system", message: "Agent started", model: agent_config.model_name, working_dir: working_dir)

        # Persistent input loop — read JSON lines from stdin
        while (line = $stdin.gets)
          line = line.strip
          next if line.empty?

          # Parse input
          input = begin
                    JSON.parse(line)
                  rescue JSON::ParserError
                    # Treat bare string as a message
                    { "type" => "message", "content" => line }
                  end

          type = input["type"] || "message"

          case type
          when "message"
            content = input["content"].to_s.strip
            if content.empty?
              json_ui.emit("error", message: "Empty message content")
              next
            end

            # Handle built-in commands
            case content.downcase
            when "/exit", "/quit"
              break
            when "/clear"
              agent = Clacky::Agent.new(client, agent_config, working_dir: working_dir)
              agent.instance_variable_set(:@ui, json_ui)
              json_ui.emit("info", message: "Session cleared. Starting fresh.")
              next
            end

            images = input["images"] || []
            run_json_task(agent, json_ui, session_manager) { agent.run(content, images: images) }
          when "exit"
            break
          else
            json_ui.emit("error", message: "Unknown input type: #{type}")
          end
        end

        # Final session save and shutdown
        if session_manager && agent.total_tasks > 0
          session_manager.save(agent.to_session_data(status: :exited))
        end
        json_ui.emit("done", total_cost: agent.total_cost, total_tasks: agent.total_tasks)
      end

      # Execute a single agent task inside the JSON loop, with error handling.
      def run_json_task(agent, json_ui, session_manager)
        json_ui.set_working_status
        yield
        session_manager&.save(agent.to_session_data(status: :success))
        json_ui.update_sessionbar(tasks: agent.total_tasks, cost: agent.total_cost)
      rescue Clacky::AgentInterrupted
        json_ui.emit("interrupted")
      rescue => e
        json_ui.emit("error", message: e.message)
      ensure
        json_ui.set_idle_status
      end

      # Run agent with UI2 split-screen interface
      def run_agent_with_ui2(agent, working_dir, agent_config, session_manager = nil, client = nil, is_session_load: false)
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
          model: agent_config.model_name,
          theme: theme_name
        )

        # Inject UI into agent
        agent.instance_variable_set(:@ui, ui_controller)

        # Set skill loader for command suggestions
        ui_controller.set_skill_loader(agent.skill_loader)

        # Track current working thread (agent or idle compression that can be interrupted)
        # idle_timer is tracked separately because it should not be interrupted during sleep
        current_task_thread = nil
        idle_timer_thread = nil

        # Set up mode toggle handler
        ui_controller.on_mode_toggle do |new_mode|
          agent_config.permission_mode = new_mode.to_sym
        end

        # Set up interrupt handler
        ui_controller.on_interrupt do |input_was_empty:|
          if (not current_task_thread&.alive?) && input_was_empty
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

          if current_task_thread&.alive?
            current_task_thread.raise(Clacky::AgentInterrupted, "User interrupted")
          end
          ui_controller.clear_input
          ui_controller.set_input_tips("Press Ctrl+C again to exit.", type: :info)
        end

        # Set up input handler
        ui_controller.on_input do |input, images, display: nil|
          # Handle commands
          case input.downcase.strip
          when "/config"
            handle_config_command(ui_controller, client, agent_config, agent)
            next
          when "/clear"
            # Show user input first
            ui_controller.append_output(display) if display
            sleep 0.1
            # Clear output area
            ui_controller.layout.clear_output
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
            # Show user input first
            ui_controller.append_output(display) if display
            sleep 0.1
            ui_controller.show_help
            next
          end

          # If any task thread is running, interrupt it first
          if current_task_thread&.alive?
            current_task_thread.raise(Clacky::AgentInterrupted, "New input received")
            current_task_thread.join(2) # Wait up to 2 seconds for graceful shutdown
            ui_controller.set_idle_status
          end

          # Cancel idle timer if running (new input means user is active)
          if idle_timer_thread&.alive?
            idle_timer_thread.kill
            idle_timer_thread = nil
          end

          # Helper method to start idle timer after agent completes
          start_idle_timer = lambda do
            # Start idle timer - trigger compression after 60 seconds of inactivity
            idle_timer_thread = Thread.new do
              # Sleep outside of rescue block - if interrupted here, let it propagate and exit
              sleep 60 * 3

              # After sleep completes, switch to current_task_thread for compression
              # (so it can be interrupted by Ctrl+C)
              current_task_thread = Thread.new do
                begin
                  # After 60 seconds, start idle compression
                  ui_controller.set_working_status
                  success = agent.trigger_idle_compression

                  if success
                    # Update session bar after compression
                    ui_controller.update_sessionbar(tasks: agent.total_tasks, cost: agent.total_cost)
                    # Save session after compression
                    session_manager&.save(agent.to_session_data(status: :success))
                  end
                rescue Clacky::AgentInterrupted
                  # Compression was interrupted by user
                  ui_controller.append_output("")
                  ui_controller.show_info("Idle compression cancelled")
                rescue => e
                  ui_controller.log("Idle compression error: #{e.message}", level: :error)
                ensure
                  ui_controller.set_idle_status
                  current_task_thread = nil
                end
              end

              # Wait for compression to complete
              current_task_thread.join
              idle_timer_thread = nil
            end
          end

          # Run agent in background thread
          current_task_thread = Thread.new do
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
              current_task_thread = nil
              # Start idle timer after agent completes
              start_idle_timer.call
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

        # Start input loop (blocks until exit)
        ui_controller.start_input_loop

        # Cleanup: kill any running thread
        current_task_thread&.kill

        # Save final session state
        if session_manager && agent.total_tasks > 0
          session_manager.save(agent.to_session_data)
        end
      end



    end
  end
end
