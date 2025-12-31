# frozen_string_literal: true

require "securerandom"
require "json"

module Clacky
  class Agent
    attr_reader :session_id, :messages, :iterations, :total_cost

    # Pricing per 1M tokens (approximate - adjust based on actual model)
    PRICING = {
      input: 0.50,  # $0.50 per 1M input tokens
      output: 1.50  # $1.50 per 1M output tokens
    }.freeze

    def initialize(client, config = {})
      @client = client
      @config = config.is_a?(AgentConfig) ? config : AgentConfig.new(config)
      @tool_registry = ToolRegistry.new
      @hooks = HookManager.new
      @session_id = SecureRandom.uuid
      @messages = []
      @iterations = 0
      @total_cost = 0.0
      @start_time = nil

      # Register built-in tools
      register_builtin_tools
    end

    def add_hook(event, &block)
      @hooks.add(event, &block)
    end

    def run(user_input, &block)
      @start_time = Time.now
      @messages << { role: "user", content: user_input }

      emit_event(:on_start, { input: user_input }, &block)
      @hooks.trigger(:on_start, user_input)

      begin
        loop do
          break if should_stop?

          @iterations += 1
          emit_event(:on_iteration, { iteration: @iterations }, &block)
          @hooks.trigger(:on_iteration, @iterations)

          # Think: LLM reasoning with tool support
          response = think(&block)

          # Check if done (no more tool calls needed)
          if response[:finish_reason] == "stop" || response[:tool_calls].nil?
            emit_event(:answer, { content: response[:content] }, &block)
            break
          end

          # Act: Execute tool calls
          tool_results = act(response[:tool_calls], &block)

          # Observe: Add tool results to conversation context
          observe(response, tool_results)
        end

        result = build_result(:success)
        emit_event(:on_complete, result, &block)
        @hooks.trigger(:on_complete, result)
        result
      rescue StandardError => e
        result = build_result(:error, error: e.message)
        emit_event(:on_complete, result, &block)
        raise
      end
    end

    private

    def think(&block)
      emit_event(:thinking, { iteration: @iterations }, &block)

      # Only send tools definitions if there are no tool results in messages
      # Some APIs (like DeepSeek) can't handle both tool results and tools definitions in the same request
      has_tool_results = @messages.any? { |msg| msg[:role] == "tool" }
      tools_to_send = has_tool_results ? nil : @tool_registry.allowed_definitions(@config.allowed_tools)

      response = @client.send_messages_with_tools(
        @messages,
        model: @config.model,
        tools: tools_to_send,
        max_tokens: @config.max_tokens,
        verbose: @config.verbose
      )

      track_cost(response[:usage])

      # Add assistant response to messages
      msg = { role: "assistant" }
      # Always include content field (some APIs require it even with tool_calls)
      # Use empty string instead of null for better compatibility
      msg[:content] = response[:content] || ""
      msg[:tool_calls] = format_tool_calls_for_api(response[:tool_calls]) if response[:tool_calls]
      @messages << msg

      if @config.verbose
        puts "\n[DEBUG] Assistant response added to messages:"
        puts JSON.pretty_generate(msg)
      end

      response
    end

    def act(tool_calls, &block)
      return [] unless tool_calls

      tool_calls.map do |call|
        # Hook: before_tool_use
        hook_result = @hooks.trigger(:before_tool_use, call)
        if hook_result[:action] == :deny
          emit_event(:tool_denied, call, &block)
          next build_error_result(call, hook_result[:reason] || "Tool use denied by hook")
        end

        # Permission check (if not in auto-approve mode)
        unless @config.should_auto_execute?(call[:name])
          if @config.is_plan_only?
            emit_event(:tool_planned, call, &block)
            next build_planned_result(call)
          end

          unless confirm_tool_use?(call, &block)
            emit_event(:tool_denied, call, &block)
            next build_denied_result(call)
          end
        end

        emit_event(:tool_call, call, &block)

        # Execute tool
        begin
          tool = @tool_registry.get(call[:name])
          args = JSON.parse(call[:arguments], symbolize_names: true)
          result = tool.execute(**args)

          # Hook: after_tool_use
          @hooks.trigger(:after_tool_use, call, result)

          emit_event(:observation, { tool: call[:name], result: result }, &block)
          build_success_result(call, result)
        rescue StandardError => e
          @hooks.trigger(:on_tool_error, call, e)
          emit_event(:tool_error, { call: call, error: e }, &block)
          build_error_result(call, e.message)
        end
      end.compact
    end

    def observe(response, tool_results)
      # Add tool results as messages
      tool_results.each do |result|
        @messages << {
          role: "tool",
          tool_call_id: result[:id],
          content: result[:content]
        }
      end
    end

    def should_stop?
      if @iterations >= @config.max_iterations
        puts "\n⚠️  Reached maximum iterations (#{@config.max_iterations})" if @config.verbose
        return true
      end

      if @total_cost >= @config.max_cost_usd
        puts "\n⚠️  Reached maximum cost ($#{@config.max_cost_usd})" if @config.verbose
        return true
      end

      if Time.now - @start_time > @config.timeout_seconds
        puts "\n⚠️  Reached timeout (#{@config.timeout_seconds}s)" if @config.verbose
        return true
      end

      false
    end

    def track_cost(usage)
      input_cost = (usage[:prompt_tokens] / 1_000_000.0) * PRICING[:input]
      output_cost = (usage[:completion_tokens] / 1_000_000.0) * PRICING[:output]
      @total_cost += input_cost + output_cost
    end

    def emit_event(type, data, &block)
      return unless block

      block.call({
        type: type,
        data: data,
        iteration: @iterations,
        cost: @total_cost
      })
    end

    def confirm_tool_use?(call, &block)
      emit_event(:tool_confirmation_required, call, &block)

      print "\n❓ Allow #{call[:name]}? "
      print "\n   Args: #{call[:arguments]}"
      print "\n   (y/n): "

      response = $stdin.gets
      return false if response.nil?  # Handle EOF/pipe input

      response = response.chomp.downcase
      response == "y" || response == "yes"
    end

    def build_success_result(call, result)
      {
        id: call[:id],
        content: result.to_json
      }
    end

    def build_error_result(call, error_message)
      {
        id: call[:id],
        content: JSON.generate({ error: error_message })
      }
    end

    def build_denied_result(call)
      {
        id: call[:id],
        content: JSON.generate({ error: "Tool use denied by user" })
      }
    end

    def build_planned_result(call)
      {
        id: call[:id],
        content: JSON.generate({ planned: true, message: "Tool execution skipped (plan mode)" })
      }
    end

    def build_result(status, error: nil)
      {
        status: status,
        session_id: @session_id,
        iterations: @iterations,
        duration_seconds: Time.now - @start_time,
        total_cost_usd: @total_cost.round(4),
        messages: @messages,
        error: error
      }
    end

    def format_tool_calls_for_api(tool_calls)
      return nil unless tool_calls

      tool_calls.map do |call|
        {
          id: call[:id],
          type: call[:type] || "function",
          function: {
            name: call[:name],
            arguments: call[:arguments]
          }
        }
      end
    end

    def register_builtin_tools
      @tool_registry.register(Tools::Calculator.new)
      @tool_registry.register(Tools::Shell.new)
      @tool_registry.register(Tools::FileReader.new)
      @tool_registry.register(Tools::Write.new)
      @tool_registry.register(Tools::Edit.new)
      @tool_registry.register(Tools::Glob.new)
      @tool_registry.register(Tools::Grep.new)
      @tool_registry.register(Tools::WebSearch.new)
      @tool_registry.register(Tools::WebFetch.new)
    end
  end
end
