# frozen_string_literal: true

require "securerandom"
require "json"
require "tty-prompt"
require "set"
require "base64"
require_relative "utils/arguments_parser"

module Clacky
  class Agent
    attr_reader :session_id, :messages, :iterations, :total_cost, :working_dir, :created_at, :total_tasks, :todos,
                :cache_stats, :cost_source, :ui

    # System prompt for the coding agent
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are OpenClacky, an AI coding assistant and technical co-founder, designed to help non-technical
      users complete software development projects. You are responsible for development in the current project.

      Your role is to:
      - Understand project requirements and translate them into technical solutions
      - Write clean, maintainable, and well-documented code
      - Follow best practices and industry standards
      - Explain technical concepts in simple terms when needed
      - Proactively identify potential issues and suggest improvements
      - Help with debugging, testing, and deployment

      Working process:
      1. **For complex tasks with multiple steps**:
         - Use todo_manager to create a complete TODO list FIRST
         - After creating the TODO list, START EXECUTING each task immediately
         - Don't stop after planning - continue to work on the tasks!
      2. Always read existing code before making changes (use file_reader/glob/grep)
      3. Ask clarifying questions if requirements are unclear
      4. Break down complex tasks into manageable steps
      5. **USE TOOLS to create/modify files** - don't just return code
      6. Write code that is secure, efficient, and easy to understand
      7. Test your changes using the shell tool when appropriate
      8. **IMPORTANT**: After completing each step, mark the TODO as completed and continue to the next one
      9. Keep working until ALL TODOs are completed or you need user input
      10. Provide brief explanations after completing actions

      IMPORTANT: You should frequently refer to the existing codebase. For unclear instructions,
      prioritize understanding the codebase first before answering or taking action.
      Always read relevant code files to understand the project structure, patterns, and conventions.

      CRITICAL RULE FOR TODO MANAGER:
      When using todo_manager to add tasks, you MUST continue working immediately after adding ALL todos.
      Adding todos is NOT completion - it's just the planning phase!
      Workflow: add todo 1 → add todo 2 → add todo 3 → START WORKING on todo 1 → complete(1) → work on todo 2 → complete(2) → etc.
      NEVER stop after just adding todos without executing them!
    PROMPT

    def initialize(client, config = {}, working_dir: nil, ui: nil)
      @client = client
      @config = config.is_a?(AgentConfig) ? config : AgentConfig.new(config)
      @tool_registry = ToolRegistry.new
      @hooks = HookManager.new
      @session_id = SecureRandom.uuid
      @messages = []
      @todos = []  # Store todos in memory
      @iterations = 0
      @total_cost = 0.0
      @cache_stats = {
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        total_requests: 0,
        cache_hit_requests: 0,
        raw_api_usage_samples: []  # Store raw API usage for debugging
      }
      @start_time = nil
      @working_dir = working_dir || Dir.pwd
      @created_at = Time.now.iso8601
      @total_tasks = 0
      @cost_source = :estimated  # Track whether cost is from API or estimated
      @task_cost_source = :estimated  # Track cost source for current task
      @previous_total_tokens = 0  # Track tokens from previous iteration for delta calculation
      @interrupted = false  # Flag for user interrupt
      @ui = ui  # UIController for direct UI interaction
      @debug_logs = []  # Debug logs for troubleshooting

      # Register built-in tools
      register_builtin_tools
    end

    # Restore from a saved session
    def self.from_session(client, config, session_data, ui: nil)
      agent = new(client, config, ui: ui)
      agent.restore_session(session_data)
      agent
    end

    def restore_session(session_data)
      @session_id = session_data[:session_id]
      @messages = session_data[:messages]
      @todos = session_data[:todos] || []  # Restore todos from session
      @iterations = session_data.dig(:stats, :total_iterations) || 0
      @total_cost = session_data.dig(:stats, :total_cost_usd) || 0.0
      @working_dir = session_data[:working_dir]
      @created_at = session_data[:created_at]
      @total_tasks = session_data.dig(:stats, :total_tasks) || 0

      # Restore cache statistics if available
      @cache_stats = session_data.dig(:stats, :cache_stats) || {
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        total_requests: 0,
        cache_hit_requests: 0
      }

      # Check if the session ended with an error
      last_status = session_data.dig(:stats, :last_status)
      last_error = session_data.dig(:stats, :last_error)

      if last_status == "error" && last_error
        # Find and remove the last user message that caused the error
        # This allows the user to retry with a different prompt
        last_user_index = @messages.rindex { |m| m[:role] == "user" }
        if last_user_index
          @messages = @messages[0...last_user_index]

          # Trigger a hook to notify about the rollback
          @hooks.trigger(:session_rollback, {
            reason: "Previous session ended with error",
            error_message: last_error,
            rolled_back_message_index: last_user_index
          })
        end
      end
    end

    def add_hook(event, &block)
      @hooks.add(event, &block)
    end

    def run(user_input, images: [])
      @start_time = Time.now
      @task_cost_source = :estimated  # Reset for new task
      @previous_total_tokens = 0  # Reset token tracking for new task

      # Add system prompt as the first message if this is the first run
      if @messages.empty?
        system_prompt = build_system_prompt
        system_message = { role: "system", content: system_prompt }

        # Note: Don't set cache_control on system prompt
        # System prompt is usually < 1024 tokens (minimum for caching)
        # Cache control will be set on tools and conversation history instead

        @messages << system_message
      end

      # Format user message with images if provided
      user_content = format_user_content(user_input, images)
      @messages << { role: "user", content: user_content }
      @total_tasks += 1

      @hooks.trigger(:on_start, user_input)

      begin
        loop do
          break if should_stop?

          @iterations += 1
          @hooks.trigger(:on_iteration, @iterations)

          # Think: LLM reasoning with tool support
          response = think

          # Debug: check for potential infinite loops
          if @config.verbose
            @ui&.log("Iteration #{@iterations}: finish_reason=#{response[:finish_reason]}, tool_calls=#{response[:tool_calls]&.size || 'nil'}", level: :debug)
          end

          # Check if done (no more tool calls needed)
          if response[:finish_reason] == "stop" || response[:tool_calls].nil? || response[:tool_calls].empty?
            @ui&.show_assistant_message(response[:content]) if response[:content] && !response[:content].empty?
            break
          end

          # Show assistant message if there's content before tool calls
          if response[:content] && !response[:content].empty?
            @ui&.show_assistant_message(response[:content])
          end

          # Act: Execute tool calls
          action_result = act(response[:tool_calls])

          # Observe: Add tool results to conversation context
          observe(response, action_result[:tool_results])

          # Check if user denied any tool
          if action_result[:denied]
            # If user provided feedback, treat it as a user question/instruction
            if action_result[:feedback] && !action_result[:feedback].empty?
              # Add user feedback as a new user message
              @messages << {
                role: "user",
                content: "STOP. The user has a question/feedback for you: #{action_result[:feedback]}\n\nPlease respond to the user's question/feedback before continuing with any actions."
              }
              # Continue loop to let agent respond to feedback
              next
            else
              # User just said "no" without feedback - stop and wait
              @ui&.show_assistant_message("Tool execution was denied. Please give more instructions...")
              break
            end
          end
        end

        result = build_result(:success)
        @ui&.show_complete(
          iterations: result[:iterations],
          cost: result[:total_cost_usd],
          duration: result[:duration_seconds],
          cache_stats: result[:cache_stats]
        )
        @hooks.trigger(:on_complete, result)
        result
      rescue Clacky::AgentInterrupted
        # Let CLI handle the interrupt message
        raise
      rescue StandardError => e
        # Build error result for session data, but let CLI handle error display
        result = build_result(:error, error: e.message)
        raise
      end
    end

    # Generate session data for saving
    # @param status [Symbol] Status of the last task: :success, :error, or :interrupted
    # @param error_message [String] Error message if status is :error
    def to_session_data(status: :success, error_message: nil)
      # Get last real user message for preview (skip compressed system messages)
      last_user_msg = @messages.reverse.find do |m|
        m[:role] == "user" && !m[:content].to_s.start_with?("[SYSTEM]")
      end

      # Extract preview text from last user message
      last_message_preview = if last_user_msg
        content = last_user_msg[:content]
        if content.is_a?(String)
          # Truncate to 100 characters for preview
          content.length > 100 ? "#{content[0..100]}..." : content
        else
          "User message (non-string content)"
        end
      else
        "No messages"
      end

      stats_data = {
        total_tasks: @total_tasks,
        total_iterations: @iterations,
        total_cost_usd: @total_cost.round(4),
        duration_seconds: @start_time ? (Time.now - @start_time).round(2) : 0,
        last_status: status.to_s,
        cache_stats: @cache_stats,
        debug_logs: @debug_logs
      }

      # Add error message if status is error
      stats_data[:last_error] = error_message if status == :error && error_message

      {
        session_id: @session_id,
        created_at: @created_at,
        updated_at: Time.now.iso8601,
        working_dir: @working_dir,
        todos: @todos,  # Include todos in session data
        config: {
          model: @config.model,
          permission_mode: @config.permission_mode.to_s,
          enable_compression: @config.enable_compression,
          enable_prompt_caching: @config.enable_prompt_caching,
          keep_recent_messages: @config.keep_recent_messages,
          max_tokens: @config.max_tokens,
          verbose: @config.verbose
        },
        stats: stats_data,
        messages: @messages,
        first_user_message: last_message_preview
      }
    end

    private

    def should_auto_execute?(tool_name, tool_params = {})
      case @config.permission_mode
      when :auto_approve
        true
      when :confirm_safes
        # Use SafeShell integration for safety check
        is_safe_operation?(tool_name, tool_params)
      when :confirm_edits
        !editing_tool?(tool_name)
      when :plan_only
        false
      else
        false
      end
    end

    def editing_tool?(tool_name)
      AgentConfig::EDITING_TOOLS.include?(tool_name.to_s.downcase)
    end

    def is_safe_operation?(tool_name, tool_params = {})
      # For shell commands, use SafeShell to check safety
      if tool_name.to_s.downcase == 'shell' || tool_name.to_s.downcase == 'safe_shell'
        begin
          require_relative 'tools/safe_shell'

          # Parse tool_params if it's a JSON string
          params = tool_params.is_a?(String) ? JSON.parse(tool_params) : tool_params
          command = params[:command] || params['command']
          return false unless command

          # Use SafeShell to analyze the command
          return Tools::SafeShell.command_safe_for_auto_execution?(command)
        rescue LoadError
          # If SafeShell not available, be conservative
          return false
        rescue => e
          # In case of any error, be conservative
          return false
        end
      end

      # For non-shell tools, consider them safe for now
      # You can extend this logic for other tools
      !editing_tool?(tool_name)
    end

    def build_system_prompt
      prompt = SYSTEM_PROMPT.dup

      # Try to load project rules from multiple sources (in order of priority)
      rules_files = [
        { path: ".clackyrules", name: ".clackyrules" },
        { path: ".cursorrules", name: ".cursorrules" },
        { path: "CLAUDE.md", name: "CLAUDE.md" }
      ]

      rules_content = nil
      rules_source = nil

      rules_files.each do |file_info|
        full_path = File.join(@working_dir, file_info[:path])
        if File.exist?(full_path)
          content = File.read(full_path).strip
          unless content.empty?
            rules_content = content
            rules_source = file_info[:name]
            break
          end
        end
      end

      # Add rules to prompt if found
      if rules_content && rules_source
        prompt += "\n\n" + "=" * 80 + "\n"
        prompt += "PROJECT-SPECIFIC RULES (from #{rules_source}):\n"
        prompt += "=" * 80 + "\n"
        prompt += rules_content
        prompt += "\n" + "=" * 80 + "\n"
        prompt += "⚠️ IMPORTANT: Follow these project-specific rules at all times!\n"
        prompt += "=" * 80
      end

      prompt
    end

    def think
      @ui&.show_progress

      # Compress messages if needed to reduce cost
      compress_messages_if_needed

      # Always send tools definitions to allow multi-step tool calling
      tools_to_send = @tool_registry.all_definitions

      # Retry logic for network failures
      max_retries = 10
      retry_delay = 5
      retries = 0

      begin
        response = @client.send_messages_with_tools(
          @messages,
          model: @config.model,
          tools: tools_to_send,
          max_tokens: @config.max_tokens,
          enable_caching: @config.enable_prompt_caching
        )
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
        retries += 1
        if retries <= max_retries
          @ui&.show_warning("Network failed: #{e.message}. Retry #{retries}/#{max_retries}...")
          sleep retry_delay
          retry
        else
          @ui&.show_error("Network failed after #{max_retries} retries: #{e.message}")
          raise Error, "Network connection failed after #{max_retries} retries: #{e.message}"
        end
      end

      # Stop progress thread (but keep progress line visible)
      @ui&.stop_progress_thread

      track_cost(response[:usage], raw_api_usage: response[:raw_api_usage])

      # Handle truncated responses (when max_tokens limit is reached)
      if response[:finish_reason] == "length"
        # Count recent truncations to prevent infinite loops
        recent_truncations = @messages.last(5).count { |m|
          m[:role] == "user" && m[:content]&.include?("[SYSTEM] Your response was truncated")
        }

        if recent_truncations >= 2
          # Too many truncations - task is too complex
          @ui&.show_error("Response truncated multiple times. Task is too complex.")

          # Create a response that tells the user to break down the task
          error_response = {
            content: "I apologize, but this task is too complex to complete in a single response. " \
                     "Please break it down into smaller steps, or reduce the amount of content to generate at once.\n\n" \
                     "For example, when creating a long document:\n" \
                     "1. First create the file with a basic structure\n" \
                     "2. Then use edit() to add content section by section",
            finish_reason: "stop",
            tool_calls: nil
          }

          # Add this as an assistant message so it appears in conversation
          @messages << {
            role: "assistant",
            content: error_response[:content]
          }

          return error_response
        end

        # Insert system message to guide LLM to retry with smaller steps
        @messages << {
          role: "user",
          content: "[SYSTEM] Your response was truncated due to length limit. Please retry with a different approach:\n" \
                   "- For long file content: create the file with structure first, then use edit() to add content section by section\n" \
                   "- Break down large tasks into multiple smaller steps\n" \
                   "- Avoid putting more than 2000 characters in a single tool call argument\n" \
                   "- Use multiple tool calls instead of one large call"
        }

        @ui&.show_warning("Response truncated. Retrying with smaller steps...")

        # Recursively retry
        return think
      end

      # Add assistant response to messages
      msg = { role: "assistant" }
      # Always include content field (some APIs require it even with tool_calls)
      # Use empty string instead of null for better compatibility
      msg[:content] = response[:content] || ""
      msg[:tool_calls] = format_tool_calls_for_api(response[:tool_calls]) if response[:tool_calls]
      @messages << msg

      response
    end

    def act(tool_calls)
      return { denied: false, feedback: nil, tool_results: [] } unless tool_calls

      denied = false
      feedback = nil
      results = []

      tool_calls.each_with_index do |call, index|
        # Hook: before_tool_use
        hook_result = @hooks.trigger(:before_tool_use, call)
        if hook_result[:action] == :deny
          @ui&.show_warning("Tool #{call[:name]} denied by hook")
          results << build_error_result(call, hook_result[:reason] || "Tool use denied by hook")
          next
        end

        # Permission check (if not in auto-approve mode)
        unless should_auto_execute?(call[:name], call[:arguments])
          if @config.is_plan_only?
            @ui&.show_info("Planned: #{call[:name]}")
            results << build_planned_result(call)
            next
          end

          confirmation = confirm_tool_use?(call)
          unless confirmation[:approved]
            @ui&.show_warning("Tool #{call[:name]} denied")
            denied = true
            user_feedback = confirmation[:feedback]
            feedback = user_feedback if user_feedback
            results << build_denied_result(call, user_feedback)

            # Auto-deny all remaining tools
            remaining_calls = tool_calls[(index + 1)..-1] || []
            remaining_calls.each do |remaining_call|
              reason = user_feedback && !user_feedback.empty? ?
                       user_feedback :
                       "Auto-denied due to user rejection of previous tool"
              results << build_denied_result(remaining_call, reason)
            end
            break
          end
        end

        @ui&.show_tool_call(call[:name], call[:arguments])

        # Execute tool
        begin
          tool = @tool_registry.get(call[:name])

          # Parse and validate arguments with JSON repair capability
          args = Utils::ArgumentsParser.parse_and_validate(call, @tool_registry)

          # Special handling for TodoManager: inject todos array
          if call[:name] == "todo_manager"
            args[:todos_storage] = @todos
          end

          result = tool.execute(**args)

          # Hook: after_tool_use
          @hooks.trigger(:after_tool_use, call, result)

          # Update todos display after todo_manager execution
          if call[:name] == "todo_manager"
            @ui&.update_todos(@todos.dup)
          end

          @ui&.show_tool_result(tool.format_result(result))
          results << build_success_result(call, result)
        rescue StandardError => e
          @hooks.trigger(:on_tool_error, call, e)
          @ui&.show_tool_error(e)
          results << build_error_result(call, e.message)
        end
      end

      {
        denied: denied,
        feedback: feedback,
        tool_results: results
      }
    end

    def observe(response, tool_results)
      # Add tool results as messages
      # Using OpenAI format which is compatible with most APIs through LiteLLM

      # CRITICAL: Tool results must be in the same order as tool_calls in the response
      # Claude/Bedrock API requires this strict ordering
      return if tool_results.empty?

      # Create a map of tool_call_id -> result for quick lookup
      results_map = tool_results.each_with_object({}) do |result, hash|
        hash[result[:id]] = result
      end

      # Add results in the same order as the original tool_calls
      response[:tool_calls].each do |tool_call|
        result = results_map[tool_call[:id]]
        if result
          @messages << {
            role: "tool",
            tool_call_id: result[:id],
            content: result[:content]
          }
        else
          # This shouldn't happen, but add a fallback error result
          @messages << {
            role: "tool",
            tool_call_id: tool_call[:id],
            content: JSON.generate({ error: "Tool result missing" })
          }
        end
      end
    end

    # Interrupt the agent's current run
    # Called when user presses Ctrl+C during agent execution
    def interrupt!
      @interrupted = true
    end

    # Check if agent is currently running
    def running?
      @start_time != nil && !should_stop?
    end

    def should_stop?
      if @interrupted
        @interrupted = false  # Reset for next run
        return true
      end


      false
    end

    def track_cost(usage, raw_api_usage: nil)
      # Priority 1: Use API-provided cost if available (OpenRouter, LiteLLM, etc.)
      iteration_cost = nil
      if usage[:api_cost]
        @total_cost += usage[:api_cost]
        @cost_source = :api
        @task_cost_source = :api
        iteration_cost = usage[:api_cost]
        @ui&.log("Using API-provided cost: $#{usage[:api_cost]}", level: :debug) if @config.verbose
      else
        # Priority 2: Calculate from tokens using ModelPricing
        result = ModelPricing.calculate_cost(model: @config.model, usage: usage)
        cost = result[:cost]
        pricing_source = result[:source]

        @total_cost += cost
        iteration_cost = cost
        # Map pricing source to cost source: :price or :default
        @cost_source = pricing_source
        @task_cost_source = pricing_source

        if @config.verbose
          source_label = pricing_source == :price ? "model pricing" : "default pricing"
          @ui&.log("Calculated cost for #{@config.model} using #{source_label}: $#{cost.round(6)}", level: :debug)
          @ui&.log("Usage breakdown: prompt=#{usage[:prompt_tokens]}, completion=#{usage[:completion_tokens]}, cache_write=#{usage[:cache_creation_input_tokens] || 0}, cache_read=#{usage[:cache_read_input_tokens] || 0}", level: :debug)
        end
      end

      # Display token usage statistics for this iteration
      display_iteration_tokens(usage, iteration_cost)

      # Track cache usage statistics
      @cache_stats[:total_requests] += 1

      if usage[:cache_creation_input_tokens]
        @cache_stats[:cache_creation_input_tokens] += usage[:cache_creation_input_tokens]
      end

      if usage[:cache_read_input_tokens]
        @cache_stats[:cache_read_input_tokens] += usage[:cache_read_input_tokens]
        @cache_stats[:cache_hit_requests] += 1
      end

      # Store raw API usage samples (keep last 3 for debugging)
      if raw_api_usage
        @cache_stats[:raw_api_usage_samples] ||= []
        @cache_stats[:raw_api_usage_samples] << raw_api_usage
        @cache_stats[:raw_api_usage_samples] = @cache_stats[:raw_api_usage_samples].last(3)
      end
    end

    # Display token usage for current iteration
    private def display_iteration_tokens(usage, cost)
      prompt_tokens = usage[:prompt_tokens] || 0
      completion_tokens = usage[:completion_tokens] || 0
      total_tokens = usage[:total_tokens] || (prompt_tokens + completion_tokens)
      cache_write = usage[:cache_creation_input_tokens] || 0
      cache_read = usage[:cache_read_input_tokens] || 0

      # Calculate token delta from previous iteration
      delta_tokens = total_tokens - @previous_total_tokens
      @previous_total_tokens = total_tokens  # Update for next iteration

      # Prepare data for UI to format and display
      token_data = {
        delta_tokens: delta_tokens,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens,
        cache_write: cache_write,
        cache_read: cache_read,
        cost: cost
      }

      # Let UI handle formatting and display
      @ui&.show_token_usage(token_data)
    end

    def compress_messages_if_needed
      # Check if compression is enabled
      return unless @config.enable_compression

      # Only compress if we have more messages than threshold
      threshold = @config.keep_recent_messages + 80 # +80 to trigger at ~100 messages
      return if @messages.size <= threshold

      original_size = @messages.size
      target_size = @config.keep_recent_messages + 2

      @ui&.show_info("Compressing history (#{original_size} -> ~#{target_size} messages)...")

      # Find the system message (should be first)
      system_msg = @messages.find { |m| m[:role] == "system" }

      # Get the most recent N messages, ensuring tool_calls/tool results pairs are kept together
      recent_messages = get_recent_messages_with_tool_pairs(@messages, @config.keep_recent_messages)

      # Get messages to compress (everything except system and recent)
      messages_to_compress = @messages.reject { |m| m[:role] == "system" || recent_messages.include?(m) }

      return if messages_to_compress.empty?

      # Create summary of compressed messages
      summary = summarize_messages(messages_to_compress)

      # Rebuild messages array: [system, summary, recent_messages]
      rebuilt_messages = [system_msg, summary, *recent_messages].compact

      @messages = rebuilt_messages

      final_size = @messages.size

      @ui&.show_info("Compressed (#{original_size} -> #{final_size} messages)")
    end

    def get_recent_messages_with_tool_pairs(messages, count)
      # This method ensures that assistant messages with tool_calls are always kept together
      # with ALL their corresponding tool_results, maintaining the correct order.
      # This is critical for Bedrock Claude API which validates the tool_calls/tool_results pairing.

      return [] if messages.empty?

      # Track which messages to include
      messages_to_include = Set.new

      # Start from the end and work backwards
      i = messages.size - 1
      messages_collected = 0

      while i >= 0 && messages_collected < count
        msg = messages[i]

        # Skip if already marked for inclusion
        if messages_to_include.include?(i)
          i -= 1
          next
        end

        # Mark this message for inclusion
        messages_to_include.add(i)
        messages_collected += 1

        # If this is an assistant message with tool_calls, we MUST include ALL corresponding tool results
        if msg[:role] == "assistant" && msg[:tool_calls]
          tool_call_ids = msg[:tool_calls].map { |tc| tc[:id] }

          # Find all tool results that belong to this assistant message
          # They should be in the messages immediately following this assistant message
          j = i + 1
          while j < messages.size
            next_msg = messages[j]

            # If we find a tool result for one of our tool_calls, include it
            if next_msg[:role] == "tool" && tool_call_ids.include?(next_msg[:tool_call_id])
              messages_to_include.add(j)
            elsif next_msg[:role] != "tool"
              # Stop when we hit a non-tool message (start of next turn)
              break
            end

            j += 1
          end
        end

        # If this is a tool result, make sure its assistant message is also included
        if msg[:role] == "tool"
          # Find the corresponding assistant message
          j = i - 1
          while j >= 0
            prev_msg = messages[j]
            if prev_msg[:role] == "assistant" && prev_msg[:tool_calls]
              # Check if this assistant has the matching tool_call
              has_matching_call = prev_msg[:tool_calls].any? { |tc| tc[:id] == msg[:tool_call_id] }
              if has_matching_call
                unless messages_to_include.include?(j)
                  messages_to_include.add(j)
                  messages_collected += 1
                end

                # Also include all other tool results for this assistant message
                tool_call_ids = prev_msg[:tool_calls].map { |tc| tc[:id] }
                k = j + 1
                while k < messages.size
                  result_msg = messages[k]
                  if result_msg[:role] == "tool" && tool_call_ids.include?(result_msg[:tool_call_id])
                    messages_to_include.add(k)
                  elsif result_msg[:role] != "tool"
                    break
                  end
                  k += 1
                end

                break
              end
            end
            j -= 1
          end
        end

        i -= 1
      end

      # Extract the messages in their original order
      messages_to_include.to_a.sort.map { |idx| messages[idx] }
    end

    def summarize_messages(messages)
      # Count different message types
      user_msgs = messages.count { |m| m[:role] == "user" }
      assistant_msgs = messages.count { |m| m[:role] == "assistant" }
      tool_msgs = messages.count { |m| m[:role] == "tool" }

      # Extract key information
      tools_used = messages
        .select { |m| m[:role] == "assistant" && m[:tool_calls] }
        .flat_map { |m| m[:tool_calls].map { |tc| tc.dig(:function, :name) } }
        .compact
        .uniq

      # Count completed tasks from tool results
      completed_todos = messages
        .select { |m| m[:role] == "tool" }
        .map { |m| JSON.parse(m[:content]) rescue nil }
        .compact
        .select { |data| data.is_a?(Hash) && data["message"]&.include?("completed") }
        .size

      summary_text = "Previous conversation summary (#{messages.size} messages compressed):\n"
      summary_text += "- User requests: #{user_msgs}\n"
      summary_text += "- Assistant responses: #{assistant_msgs}\n"
      summary_text += "- Tool executions: #{tool_msgs}\n"
      summary_text += "- Tools used: #{tools_used.join(', ')}\n" if tools_used.any?
      summary_text += "- Completed tasks: #{completed_todos}\n" if completed_todos > 0
      summary_text += "\nContinuing with recent conversation context..."

      {
        role: "user",
        content: "[SYSTEM] " + summary_text
      }
    end

    def confirm_tool_use?(call)
      # Show preview first and check for errors
      preview_error = show_tool_preview(call)

      # If preview detected an error, auto-deny and provide feedback
      if preview_error && preview_error[:error]
        @ui&.show_warning("Tool call auto-denied due to preview error")
        feedback = build_preview_error_feedback(call[:name], preview_error)
        return { approved: false, feedback: feedback }
      end

      # Request confirmation via UI
      if @ui
        prompt_text = format_tool_prompt(call)
        result = @ui.request_confirmation(prompt_text, default: true)

        case result
        when true
          { approved: true, feedback: nil }
        when false, nil
          { approved: false, feedback: nil }
        else
          # String feedback
          { approved: false, feedback: result.to_s }
        end
      else
        # Fallback: auto-approve if no UI
        { approved: true, feedback: nil }
      end
    end

    private def build_preview_error_feedback(tool_name, error_info)
      case tool_name
      when "edit"
        "The edit operation will fail because the old_string was not found in the file. " \
        "Please use file_reader to read '#{error_info[:path]}' first, " \
        "find the correct string to replace, and try again with the exact string (including whitespace)."
      else
        "Tool preview error: #{error_info[:error]}"
      end
    end

    def format_tool_prompt(call)
      begin
        args = JSON.parse(call[:arguments], symbolize_names: true)

        # Try to use tool's format_call method for better formatting
        tool = @tool_registry.get(call[:name]) rescue nil
        if tool
          formatted = tool.format_call(args) rescue nil
          return formatted if formatted
        end

        # Fallback to manual formatting for common tools
        case call[:name]
        when "edit"
          path = args[:path] || args[:file_path]
          filename = Utils::PathHelper.safe_basename(path)
          "Edit(#{filename})"
        when "write"
          filename = Utils::PathHelper.safe_basename(args[:path])
          if args[:path] && File.exist?(args[:path])
            "Write(#{filename}) - overwrite existing"
          else
            "Write(#{filename}) - create new"
          end
        when "shell", "safe_shell"
          cmd = args[:command] || ''
          display_cmd = cmd.length > 30 ? "#{cmd[0..27]}..." : cmd
          "#{call[:name]}(\"#{display_cmd}\")"
        else
          "Allow #{call[:name]}"
        end
      rescue JSON::ParserError
        "Allow #{call[:name]}"
      end
    end

    def show_tool_preview(call)
      return nil unless @ui

      begin
        args = JSON.parse(call[:arguments], symbolize_names: true)

        preview_error = nil
        case call[:name]
        when "write"
          preview_error = show_write_preview(args)
        when "edit"
          preview_error = show_edit_preview(args)
        when "shell", "safe_shell"
          show_shell_preview(args)
        else
          # For other tools, show formatted arguments
          tool = @tool_registry.get(call[:name]) rescue nil
          if tool
            formatted = tool.format_call(args) rescue "#{call[:name]}(...)"
            @ui&.show_tool_args(formatted)
          else
            @ui&.show_tool_args(call[:arguments])
          end
        end

        preview_error
      rescue JSON::ParserError
        @ui&.show_tool_args(call[:arguments])
        nil
      end
    end

    def show_write_preview(args)
      path = args[:path] || args['path']
      new_content = args[:content] || args['content'] || ""

      is_new_file = !(path && File.exist?(path))
      @ui&.show_file_write_preview(path, is_new_file: is_new_file)

      if is_new_file
        @ui&.show_diff("", new_content, max_lines: 50)
      else
        old_content = File.read(path)
        @ui&.show_diff(old_content, new_content, max_lines: 50)
      end
      nil
    end

    def show_edit_preview(args)
      path = args[:path] || args[:file_path] || args['path'] || args['file_path']
      old_string = args[:old_string] || args['old_string'] || ""
      new_string = args[:new_string] || args['new_string'] || ""

      @ui&.show_file_edit_preview(path)

      if !path || path.empty?
        @ui&.show_file_error("No file path provided")
        return { error: "No file path provided for edit operation" }
      end

      unless File.exist?(path)
        @ui&.show_file_error("File not found: #{path}")
        return { error: "File not found: #{path}", path: path }
      end

      if old_string.empty?
        @ui&.show_file_error("No old_string provided (nothing to replace)")
        return { error: "No old_string provided (nothing to replace)" }
      end

      file_content = File.read(path)

      # Check if old_string exists in file
      unless file_content.include?(old_string)
        # Log debug info for troubleshooting
        @debug_logs << {
          timestamp: Time.now.iso8601,
          event: "edit_preview_failed",
          path: path,
          looking_for: old_string[0..500],
          file_content_preview: file_content[0..1000],
          file_size: file_content.length
        }

        @ui&.show_file_error("String to replace not found in file")
        @ui&.show_file_error("Looking for (first 100 chars):")
        @ui&.show_file_error(old_string[0..100].inspect)
        return {
          error: "String to replace not found in file",
          path: path,
          looking_for: old_string[0..200]
        }
      end

      new_content = file_content.sub(old_string, new_string)
      @ui&.show_diff(file_content, new_content, max_lines: 50)
      nil  # No error
    end

    def show_shell_preview(args)
      command = args[:command] || ""
      @ui&.show_shell_preview(command)
      nil
    end

    def build_success_result(call, result)
      # Try to get tool instance to use its format_result_for_llm method
      tool = @tool_registry.get(call[:name]) rescue nil

      formatted_result = if tool && tool.respond_to?(:format_result_for_llm)
        # Tool provides a custom LLM-friendly format
        tool.format_result_for_llm(result)
      else
        # Fallback: use the original result
        result
      end

      {
        id: call[:id],
        content: JSON.generate(formatted_result)
      }
    end

    def build_error_result(call, error_message)
      {
        id: call[:id],
        content: JSON.generate({ error: error_message })
      }
    end

    def build_denied_result(call, user_feedback = nil)
      message = if user_feedback && !user_feedback.empty?
                  "Tool use denied by user. User feedback: #{user_feedback}"
                else
                  "Tool use denied by user"
                end

      {
        id: call[:id],
        content: JSON.generate({
          error: message,
          user_feedback: user_feedback
        })
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
        cost_source: @task_cost_source,  # Add cost source for this task
        cache_stats: @cache_stats,
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

      @tool_registry.register(Tools::SafeShell.new)
      @tool_registry.register(Tools::FileReader.new)
      @tool_registry.register(Tools::Write.new)
      @tool_registry.register(Tools::Edit.new)
      @tool_registry.register(Tools::Glob.new)
      @tool_registry.register(Tools::Grep.new)
      @tool_registry.register(Tools::WebSearch.new)
      @tool_registry.register(Tools::WebFetch.new)
      @tool_registry.register(Tools::TodoManager.new)
      @tool_registry.register(Tools::RunProject.new)
    end

    # Format user content with optional images
    # @param text [String] User's text input
    # @param images [Array<String>] Array of image file paths
    # @return [String|Array] String if no images, Array with text and image_url objects if images present
    def format_user_content(text, images)
      return text if images.nil? || images.empty?

      content = []
      content << { type: "text", text: text } unless text.nil? || text.empty?

      images.each do |image_path|
        image_url = image_path_to_data_url(image_path)
        content << { type: "image_url", image_url: { url: image_url } }
      end

      content
    end

    # Convert image file path to base64 data URL
    # @param path [String] File path to image
    # @return [String] base64 data URL (e.g., "data:image/png;base64,...")
    def image_path_to_data_url(path)
      unless File.exist?(path)
        raise ArgumentError, "Image file not found: #{path}"
      end

      # Read file as binary
      image_data = File.binread(path)

      # Detect MIME type from file extension or content
      mime_type = detect_image_mime_type(path, image_data)

      # Encode to base64
      base64_data = Base64.strict_encode64(image_data)

      "data:#{mime_type};base64,#{base64_data}"
    end

    # Detect image MIME type
    # @param path [String] File path
    # @param data [String] Binary image data
    # @return [String] MIME type (e.g., "image/png")
    def detect_image_mime_type(path, data)
      # Try to detect from file extension first
      ext = File.extname(path).downcase
      case ext
      when ".png"
        "image/png"
      when ".jpg", ".jpeg"
        "image/jpeg"
      when ".gif"
        "image/gif"
      when ".webp"
        "image/webp"
      else
        # Try to detect from file signature (magic bytes)
        if data.start_with?("\x89PNG".b)
          "image/png"
        elsif data.start_with?("\xFF\xD8\xFF".b)
          "image/jpeg"
        elsif data.start_with?("GIF87a".b) || data.start_with?("GIF89a".b)
          "image/gif"
        elsif data.start_with?("RIFF".b) && data[8..11] == "WEBP".b
          "image/webp"
        else
          # Default to png if unknown
          "image/png"
        end
      end
    end
  end
end
