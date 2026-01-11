# frozen_string_literal: true

require "securerandom"
require "json"
require "readline"
require "set"
require_relative "utils/arguments_parser"

module Clacky
  class Agent
    attr_reader :session_id, :messages, :iterations, :total_cost, :working_dir, :created_at, :total_tasks, :todos

    # Pricing per 1M tokens (approximate - adjust based on actual model)
    PRICING = {
      input: 0.50,  # $0.50 per 1M input tokens
      output: 1.50  # $1.50 per 1M output tokens
    }.freeze

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

    def initialize(client, config = {}, working_dir: nil)
      @client = client
      @config = config.is_a?(AgentConfig) ? config : AgentConfig.new(config)
      @tool_registry = ToolRegistry.new
      @hooks = HookManager.new
      @session_id = SecureRandom.uuid
      @messages = []
      @todos = []  # Store todos in memory
      @iterations = 0
      @total_cost = 0.0
      @start_time = nil
      @working_dir = working_dir || Dir.pwd
      @created_at = Time.now.iso8601
      @total_tasks = 0

      # Register built-in tools
      register_builtin_tools
    end

    # Restore from a saved session
    def self.from_session(client, config, session_data)
      agent = new(client, config)
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
          trigger_hook(:session_rollback, {
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

    def run(user_input, &block)
      @start_time = Time.now

      # Add system prompt as the first message if this is the first run
      if @messages.empty?
        system_prompt = build_system_prompt
        @messages << { role: "system", content: system_prompt }
      end

      @messages << { role: "user", content: user_input }
      @total_tasks += 1

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

          # Debug: check for potential infinite loops
          if @config.verbose
            puts "[DEBUG] Iteration #{@iterations}: finish_reason=#{response[:finish_reason]}, tool_calls=#{response[:tool_calls]&.size || 'nil'}"
          end

          # Check if done (no more tool calls needed)
          if response[:finish_reason] == "stop" || response[:tool_calls].nil? || response[:tool_calls].empty?
            emit_event(:answer, { content: response[:content] }, &block)
            break
          end

          # Emit assistant_message event if there's content before tool calls
          if response[:content] && !response[:content].empty?
            emit_event(:assistant_message, { content: response[:content] }, &block)
          end

          # Act: Execute tool calls
          action_result = act(response[:tool_calls], &block)

          # Observe: Add tool results to conversation context
          observe(response, action_result[:tool_results])

          # Check if user denied any tool
          if action_result[:denied]
            # If user provided feedback, treat it as a user question/instruction
            if action_result[:feedback] && !action_result[:feedback].empty?
              # Add user feedback as a new user message
              # Use a clear format that signals this is important user input
              @messages << {
                role: "user",
                content: "STOP. The user has a question/feedback for you: #{action_result[:feedback]}\n\nPlease respond to the user's question/feedback before continuing with any actions."
              }
              # Continue loop to let agent respond to feedback
              next
            else
              # User just said "no" without feedback - stop and wait
              emit_event(:answer, { content: "Tool execution was denied. Please provide further instructions." }, &block)
              break
            end
          end
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

    # Generate session data for saving
    # @param status [Symbol] Status of the last task: :success, :error, or :interrupted
    # @param error_message [String] Error message if status is :error
    def to_session_data(status: :success, error_message: nil)
      # Get first real user message for preview (skip compressed system messages)
      first_user_msg = @messages.find do |m|
        m[:role] == "user" && !m[:content].to_s.start_with?("[SYSTEM]")
      end

      # Extract preview text from first user message
      first_message_preview = if first_user_msg
        content = first_user_msg[:content]
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
        last_status: status.to_s
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
          max_iterations: @config.max_iterations,
          max_cost_usd: @config.max_cost_usd,
          enable_compression: @config.enable_compression,
          keep_recent_messages: @config.keep_recent_messages,
          max_tokens: @config.max_tokens,
          verbose: @config.verbose
        },
        stats: stats_data,
        messages: @messages,
        first_user_message: first_message_preview
      }
    end

    private

    def should_auto_execute?(tool_name, tool_params = {})
      # Check if tool is disallowed
      return false if @config.disallowed_tools.include?(tool_name)

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

    def think(&block)
      emit_event(:thinking, { iteration: @iterations }, &block)

      # Compress messages if needed to reduce cost
      compress_messages_if_needed if @config.enable_compression

      # Always send tools definitions to allow multi-step tool calling
      tools_to_send = @tool_registry.allowed_definitions(@config.allowed_tools)

      # Show progress indicator while waiting for LLM response
      progress = ProgressIndicator.new(verbose: @config.verbose)
      progress.start

      begin
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
            verbose: @config.verbose
          )
        rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
          retries += 1
          if retries <= max_retries
            progress.finish
            puts "\n⚠️  Network request failed: #{e.class.name} - #{e.message}"
            puts "🔄 Retry #{retries}/#{max_retries}, waiting #{retry_delay} seconds..."
            sleep retry_delay
            progress.start
            retry
          else
            progress.finish
            puts "\n❌ Network request failed after #{max_retries} retries, giving up"
            raise Error, "Network connection failed after #{max_retries} retries: #{e.message}"
          end
        end

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
      ensure
        progress.finish
      end
    end

    def act(tool_calls, &block)
      return { denied: false, feedback: nil, tool_results: [] } unless tool_calls

      denied = false
      feedback = nil
      results = []

      tool_calls.each_with_index do |call, index|
        # Hook: before_tool_use
        hook_result = @hooks.trigger(:before_tool_use, call)
        if hook_result[:action] == :deny
          emit_event(:tool_denied, call, &block)
          results << build_error_result(call, hook_result[:reason] || "Tool use denied by hook")
          next
        end

        # Permission check (if not in auto-approve mode)
        unless should_auto_execute?(call[:name], call[:arguments])
          if @config.is_plan_only?
            emit_event(:tool_planned, call, &block)
            results << build_planned_result(call)
            next
          end

          confirmation = confirm_tool_use?(call, &block)
          unless confirmation[:approved]
            emit_event(:tool_denied, call, &block)
            denied = true
            user_feedback = confirmation[:feedback]
            feedback = user_feedback if user_feedback
            results << build_denied_result(call, user_feedback)

            # If user provided feedback, stop processing remaining tools immediately
            # Let the agent respond to the feedback in the next iteration
            if user_feedback && !user_feedback.empty?
              # Fill in denied results for all remaining tool calls to avoid mismatch
              remaining_calls = tool_calls[(index + 1)..-1] || []
              remaining_calls.each do |remaining_call|
                results << build_denied_result(remaining_call, "Auto-denied due to user feedback on previous tool")
              end
              break
            end
            next
          end
        end

        emit_event(:tool_call, call, &block)

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

          emit_event(:observation, { tool: call[:name], result: result }, &block)
          results << build_success_result(call, result)
        rescue StandardError => e
          @hooks.trigger(:on_tool_error, call, e)
          emit_event(:tool_error, { call: call, error: e }, &block)
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

    def should_stop?
      if @iterations >= @config.max_iterations
        puts "\n⚠️  Reached maximum iterations (#{@config.max_iterations})" if @config.verbose
        return true
      end

      if @total_cost >= @config.max_cost_usd
        puts "\n⚠️  Reached maximum cost ($#{@config.max_cost_usd})" if @config.verbose
        return true
      end

      # Check timeout only if configured (nil means no timeout)
      if @config.timeout_seconds && Time.now - @start_time > @config.timeout_seconds
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

    def compress_messages_if_needed
      # Check if compression is enabled
      return unless @config.enable_compression

      # Only compress if we have more messages than threshold
      threshold = @config.keep_recent_messages + 80 # +80 to trigger at ~100 messages
      return if @messages.size <= threshold

      original_size = @messages.size
      target_size = @config.keep_recent_messages + 2

      # Show compression progress using ProgressIndicator
      progress = ProgressIndicator.new(
        verbose: @config.verbose,
        message: "🗜️  Compressing conversation history (#{original_size} → ~#{target_size} messages)"
      )
      progress.start

      begin
        # Find the system message (should be first)
        system_msg = @messages.find { |m| m[:role] == "system" }

        # Get the most recent N messages, ensuring tool_calls/tool results pairs are kept together
        recent_messages = get_recent_messages_with_tool_pairs(@messages, @config.keep_recent_messages)

        # Get messages to compress (everything except system and recent)
        messages_to_compress = @messages.reject { |m| m[:role] == "system" || recent_messages.include?(m) }

        if messages_to_compress.empty?
          progress.finish
          return
        end

        # Create summary of compressed messages
        summary = summarize_messages(messages_to_compress)

        # Rebuild messages array: [system, summary, recent_messages]
        @messages = [system_msg, summary, *recent_messages].compact

        final_size = @messages.size

        # Finish progress and show completion message
        progress.finish
        puts "✅ Compressed conversation history (#{original_size} → #{final_size} messages)"

        # Show detailed summary in verbose mode
        if @config.verbose
          puts "\n[COMPRESSION SUMMARY]"
          puts summary[:content]
          puts ""
        end
      ensure
        progress.finish
      end
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

      # Show preview first and check for errors
      preview_error = show_tool_preview(call)

      # If preview detected an error (e.g., edit with non-existent string),
      # auto-deny and provide detailed feedback
      if preview_error && preview_error[:error]
        puts "\nTool call auto-denied due to preview error"

        # Build helpful feedback message
        feedback = case call[:name]
        when "edit"
          "The edit operation will fail because the old_string was not found in the file. " \
          "Please use file_reader to read '#{preview_error[:path]}' first, " \
          "find the correct string to replace, and try again with the exact string (including whitespace)."
        else
          "Tool preview error: #{preview_error[:error]}"
        end

        return { approved: false, feedback: feedback }
      end

      # Then show the confirmation prompt with better formatting
      prompt_text = format_tool_prompt(call)
      puts "\n❓ #{prompt_text}"

      # Use Readline for better input handling (backspace, arrow keys, etc.)
      response = Readline.readline("   (Enter/y to approve, n to deny, or provide feedback): ", true)

      if response.nil?  # Handle EOF/pipe input
        return { approved: false, feedback: nil }
      end

      response = response.chomp
      response_lower = response.downcase

      # Empty response (just Enter) or "y"/"yes" = approved
      if response.empty? || response_lower == "y" || response_lower == "yes"
        return { approved: true, feedback: nil }
      end

      # "n"/"no" = denied without feedback
      if response_lower == "n" || response_lower == "no"
        return { approved: false, feedback: nil }
      end

      # Any other input = denied with feedback
      { approved: false, feedback: response }
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
      begin
        args = JSON.parse(call[:arguments], symbolize_names: true)

        preview_error = nil
        case call[:name]
        when "write"
          preview_error = show_write_preview(args)
        when "edit"
          preview_error = show_edit_preview(args)
        when "shell", "safe_shell"
          preview_error = show_shell_preview(args)
        else
          # For other tools, show formatted arguments
          tool = @tool_registry.get(call[:name]) rescue nil
          if tool
            formatted = tool.format_call(args) rescue "#{call[:name]}(...)"
            puts "\nArgs: #{formatted}"
          else
            puts "\nArgs: #{call[:arguments]}"
          end
        end

        return preview_error
      rescue JSON::ParserError
        puts "   Args: #{call[:arguments]}"
        return nil
      end
    end

    def show_write_preview(args)
      path = args[:path] || args['path']
      new_content = args[:content] || args['content'] || ""

      puts "\n📝 File: #{path || '(unknown)'}"

      if path && File.exist?(path)
        old_content = File.read(path)
        puts "Modifying existing file\n"
        show_diff(old_content, new_content, max_lines: 50)
      else
        puts "Creating new file\n"
        # Show diff from empty content to new content (all additions)
        show_diff("", new_content, max_lines: 50)
      end
    end

    def show_edit_preview(args)
      path = args[:path] || args[:file_path] || args['path'] || args['file_path']
      old_string = args[:old_string] || args['old_string'] || ""
      new_string = args[:new_string] || args['new_string'] || ""

      puts "\n📝 File: #{path || '(unknown)'}"

      if !path || path.empty?
        puts "   ⚠️  No file path provided"
        return { error: "No file path provided for edit operation" }
      end

      unless File.exist?(path)
        puts "   ⚠️  File not found: #{path}"
        return { error: "File not found: #{path}" }
      end

      if old_string.empty?
        puts "   ⚠️  No old_string provided (nothing to replace)"
        return { error: "No old_string provided (nothing to replace)" }
      end

      file_content = File.read(path)

      # Check if old_string exists in file
      unless file_content.include?(old_string)
        puts "   ⚠️  String to replace not found in file"
        puts "   Looking for (first 100 chars):"
        puts "   #{old_string[0..100].inspect}"
        return {
          error: "String to replace not found in file",
          path: path,
          looking_for: old_string[0..200]
        }
      end

      new_content = file_content.sub(old_string, new_string)
      show_diff(file_content, new_content, max_lines: 50)
      nil  # No error
    end

    def show_shell_preview(args)
      command = args[:command] || ""
      puts "\n💻 Command: #{command}"
    end

    def show_diff(old_content, new_content, max_lines: 50)
      require 'diffy'

      diff = Diffy::Diff.new(old_content, new_content, context: 3)
      all_lines = diff.to_s(:color).lines
      display_lines = all_lines.first(max_lines)

      display_lines.each { |line| puts line.chomp }
      puts "\n... (#{all_lines.size - max_lines} more lines, diff truncated)" if all_lines.size > max_lines
    rescue LoadError
      # Fallback if diffy is not available
      puts "   Old size: #{old_content.bytesize} bytes"
      puts "   New size: #{new_content.bytesize} bytes"
    end

    def build_success_result(call, result)
      {
        id: call[:id],
        content: JSON.generate(result)
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
  end
end
