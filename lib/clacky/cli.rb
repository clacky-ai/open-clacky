# frozen_string_literal: true

require "thor"
require "tty-prompt"
require "tty-spinner"

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

    desc "agent [MESSAGE]", "Run agent with autonomous tool use"
    long_desc <<-LONGDESC
      Run an AI agent that can autonomously use tools to complete tasks.

      Permission modes:
        auto_approve    - Automatically execute all tools (use with caution)
        confirm_edits   - Auto-approve read-only tools, confirm edits
        confirm_all     - Confirm every tool use (default)
        plan_only       - Generate plan without executing

      Examples:
        $ clacky agent "Calculate the sum of numbers from 1 to 100"
        $ clacky agent --mode=auto_approve "List all Ruby files"
        $ clacky agent --tools calculator shell
    LONGDESC
    option :mode, type: :string, default: "confirm_all",
           desc: "Permission mode: auto_approve, confirm_edits, confirm_all, plan_only"
    option :tools, type: :array, default: ["all"], desc: "Allowed tools"
    option :max_iterations, type: :numeric, default: 10, desc: "Maximum iterations"
    option :max_cost, type: :numeric, default: 1.0, desc: "Maximum cost in USD"
    option :verbose, type: :boolean, default: false, desc: "Show detailed output"
    def agent(message = nil)
      config = Clacky::Config.load

      unless config.api_key
        say "Error: API key not found. Please run 'clacky config set' first.", :red
        exit 1
      end

      # Build agent config
      agent_config = build_agent_config(config)
      client = Clacky::Client.new(config.api_key, base_url: config.base_url)
      agent = Clacky::Agent.new(client, agent_config)

      # Get user input
      user_input = if message && !message.strip.empty?
                     message
                   else
                     prompt_for_input
                   end

      say "\n🤖 Starting agent...\n", :green
      say "Mode: #{agent_config.permission_mode}", :yellow
      say "Max iterations: #{agent_config.max_iterations}", :yellow
      say "Max cost: $#{agent_config.max_cost_usd}", :yellow
      say "\n"

      # Run agent with event streaming
      begin
        result = agent.run(user_input) do |event|
          display_agent_event(event)
        end

        display_agent_result(result)
      rescue StandardError => e
        say "\n❌ Error: #{e.message}", :red
        say e.backtrace.first(5).join("\n"), :red if options[:verbose]
        exit 1
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
      prompt = TTY::Prompt.new

      loop do
        message = prompt.ask("You:", required: false)
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
