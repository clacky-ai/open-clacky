# frozen_string_literal: true

require "securerandom"
require "json"
require "tty-prompt"
require "set"
require_relative "utils/arguments_parser"
require_relative "utils/file_processor"
require_relative "message_compressor"

module Clacky
  class Agent
    attr_reader :session_id, :messages, :iterations, :total_cost, :working_dir, :created_at, :total_tasks, :todos,
                :cache_stats, :cost_source, :ui, :skill_loader

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

      NOTE: Available skills are listed below in the AVAILABLE SKILLS section.
      When a user's request matches a skill, you MUST use the skill tool instead of implementing it yourself.
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

      # Compression tracking
      @compression_level = 0  # Tracks how many times we've compressed (for progressive summarization)
      @compressed_summaries = []  # Store summaries from previous compressions for reference

      # Message compressor for LLM-based intelligent compression
      # Uses LLM to preserve key decisions, errors, and context while reducing token count
      @message_compressor = MessageCompressor.new(@client, model: @config.model)

      # Skill loader for skill management
      @skill_loader = SkillLoader.new(@working_dir)

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

      # Restore previous_total_tokens for accurate delta calculation across sessions
      @previous_total_tokens = session_data.dig(:stats, :previous_total_tokens) || 0

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

    # Get recent user messages from conversation history
    # @param limit [Integer] Number of recent user messages to retrieve (default: 5)
    # @return [Array<String>] Array of recent user message contents
    def get_recent_user_messages(limit: 5)
      # Filter messages to only include real user messages (exclude system-injected ones)
      user_messages = @messages.select do |m|
        m[:role] == "user" && !m[:system_injected]
      end

      # Extract text content from the last N user messages
      user_messages.last(limit).map do |msg|
        extract_text_from_content(msg[:content])
      end
    end

    private def extract_text_from_content(content)
      if content.is_a?(String)
        content
      elsif content.is_a?(Array)
        # Extract text from content array (may contain text and images)
        text_parts = content.select { |c| c.is_a?(Hash) && c[:type] == "text" }
        text_parts.map { |c| c[:text] }.join("\n")
      else
        content.to_s
      end
    end

    def add_hook(event, &block)
      @hooks.add(event, &block)
    end

    def run(user_input, images: [])
      @start_time = Time.now
      @task_cost_source = :estimated  # Reset for new task
      # Note: Do NOT reset @previous_total_tokens here - it should maintain the value from the last iteration
      # across tasks to correctly calculate delta tokens in each iteration
      @task_start_iterations = @iterations  # Track starting iterations for this task
      @task_start_cost = @total_cost  # Track starting cost for this task

      # Track cache stats for current task
      @task_cache_stats = {
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        total_requests: 0,
        cache_hit_requests: 0
      }

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
        # Track if request_user_feedback was called
        awaiting_user_feedback = false

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

            # Debug: log why we're stopping
            if @config.verbose && (response[:tool_calls].nil? || response[:tool_calls].empty?)
              reason = response[:finish_reason] == "stop" ? "API returned finish_reason=stop" : "No tool calls in response"
              @ui&.log("Stopping: #{reason}", level: :debug)
              if response[:content] && response[:content].is_a?(String)
                preview = response[:content].length > 200 ? response[:content][0...200] + "..." : response[:content]
                @ui&.log("Response content: #{preview}", level: :debug)
              end
            end

            break
          end

          # Show assistant message if there's content before tool calls
          if response[:content] && !response[:content].empty?
            @ui&.show_assistant_message(response[:content])
          end

          # Act: Execute tool calls
          action_result = act(response[:tool_calls])

          # Check if request_user_feedback was called
          if action_result[:awaiting_feedback]
            awaiting_user_feedback = true
          end

          # Observe: Add tool results to conversation context
          observe(response, action_result[:tool_results])

          # Check if user denied any tool
          if action_result[:denied]
            # If user provided feedback, treat it as a user question/instruction
            if action_result[:feedback] && !action_result[:feedback].empty?
              # Add user feedback as a new user message with system_injected marker
              @messages << {
                role: "user",
                content: "STOP. The user has a question/feedback for you: #{action_result[:feedback]}\n\nPlease respond to the user's question/feedback before continuing with any actions.",
                system_injected: true  # Mark as system-injected message for filtering
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
          cache_stats: result[:cache_stats],
          awaiting_user_feedback: awaiting_user_feedback
        )
        @hooks.trigger(:on_complete, result)
        result
      rescue Clacky::AgentInterrupted
        # Let CLI handle the interrupt message
        raise
      rescue StandardError => e
        # Log complete error information to debug_logs for troubleshooting
        @debug_logs << {
          timestamp: Time.now.iso8601,
          event: "agent_run_error",
          error_class: e.class.name,
          error_message: e.message,
          backtrace: e.backtrace&.first(30) # Keep first 30 lines of backtrace
        }
        
        # Build error result for session data, but let CLI handle error display
        result = build_result(:error, error: e.message)
        raise
      end
    end

    # ===== Skill-related methods =====

    # Get the skill loader instance
    # @return [SkillLoader]
    def skill_loader
      @skill_loader
    end

    # Load all skills from configured locations
    # @return [Array<Skill>]
    def load_skills
      @skill_loader.load_all
    end

    # Check if input is a skill command and process it
    # @param input [String] User input
    # @return [Hash, nil] Returns { skill: Skill, arguments: String } if skill command, nil otherwise
    def parse_skill_command(input)
      # Check for slash command pattern
      if input.start_with?("/")
        # Extract command and arguments
        match = input.match(%r{^/(\S+)(?:\s+(.*))?$})
        return nil unless match

        skill_name = match[1]
        arguments = match[2] || ""

        # Find skill by command
        skill = @skill_loader.find_by_command("/#{skill_name}")
        return nil unless skill

        # Check if user can invoke this skill
        unless skill.user_invocable?
          return nil
        end

        { skill: skill, arguments: arguments }
      else
        nil
      end
    end

    # Execute a skill command
    # @param input [String] User input (should be a skill command)
    # @return [String] The expanded prompt with skill content
    def execute_skill_command(input)
      parsed = parse_skill_command(input)
      return input unless parsed

      skill = parsed[:skill]
      arguments = parsed[:arguments]

      # Process skill content with arguments
      expanded_content = skill.process_content(arguments)

      # Log skill usage
      @ui&.log("Executing skill: #{skill.identifier}", level: :info)

      expanded_content
    end

    # Generate skill context - loads all auto-invocable skills
    # @return [String] Skill context to add to system prompt
    def build_skill_context
      # Load all auto-invocable skills
      all_skills = @skill_loader.load_all
      auto_invocable = all_skills.select(&:model_invocation_allowed?)

      return "" if auto_invocable.empty?

      context = "\n\n" + "=" * 80 + "\n"
      context += "AVAILABLE SKILLS:\n"
      context += "=" * 80 + "\n\n"
      context += "CRITICAL SKILL USAGE RULES:\n"
      context += "- When a user's request matches any available skill, this is a BLOCKING REQUIREMENT:\n"
      context += "  invoke the relevant skill tool BEFORE generating any other response about the task\n"
      context += "- NEVER mention a skill without actually calling the skill tool\n"
      context += "- NEVER implement the skill's functionality yourself - always delegate to the skill\n"
      context += "- Skills provide specialized capabilities - use them instead of manual implementation\n"
      context += "- When users reference '/<skill-name>' (e.g., '/pptx'), they are requesting a skill\n\n"
      context += "Workflow: Use file_reader to read the SKILL.md file, then follow its instructions.\n\n"
      context += "Available skills:\n\n"

      auto_invocable.each do |skill|
        skill_md_path = skill.directory.join("SKILL.md")
        context += "- name: #{skill.identifier}\n"
        context += "  description: #{skill.context_description}\n"
        context += "  SKILL.md: #{skill_md_path}\n\n"
      end

      context += "\n"
      context
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
        debug_logs: @debug_logs,
        previous_total_tokens: @previous_total_tokens
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

      # Add all loaded skills to system prompt
      skill_context = build_skill_context
      prompt += skill_context if skill_context && !skill_context.empty?

      prompt
    end

    def think
      @ui&.show_progress

      # Check if compression is needed
      compression_context = compress_messages_if_needed

      # If compression is triggered, insert compression message and handle it
      if compression_context
        # Insert compression message into conversation
        @messages << compression_context[:compression_message]
      end

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
          raise AgentError, "Network connection failed after #{max_retries} retries: #{e.message}"
        end
      end

      # Clear progress indicator (change to gray and show final time)
      @ui&.clear_progress

      # If this was a compression call, rebuild message list with compressed content
      if compression_context
        handle_compression_response(response, compression_context)
        # Return early - don't process as normal response
        return nil
      end

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
      # Only add tool_calls if they actually exist (don't add empty arrays)
      if response[:tool_calls]&.any?
        msg[:tool_calls] = format_tool_calls_for_api(response[:tool_calls])
      end
      @messages << msg

      response
    end

    def act(tool_calls)
      return { denied: false, feedback: nil, tool_results: [], awaiting_feedback: false } unless tool_calls

      denied = false
      feedback = nil
      results = []
      awaiting_feedback = false

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
            # Show denial warning only for user-initiated denials (not system-injected preview errors)
            # Preview errors are already shown to user, no need to repeat
            system_injected = confirmation[:system_injected]
            unless system_injected
              denial_message = "Tool #{call[:name]} denied"
              if confirmation[:feedback] && !confirmation[:feedback].empty?
                denial_message += ": #{confirmation[:feedback]}"
              end
              @ui&.show_warning(denial_message)
            end

            denied = true
            user_feedback = confirmation[:feedback]
            feedback = user_feedback if user_feedback
            results << build_denied_result(call, user_feedback, system_injected)

            # Auto-deny all remaining tools
            remaining_calls = tool_calls[(index + 1)..-1] || []
            remaining_calls.each do |remaining_call|
              reason = user_feedback && !user_feedback.empty? ?
                       user_feedback :
                       "Auto-denied due to user rejection of previous tool"
              results << build_denied_result(remaining_call, reason, system_injected)
            end
            break
          end
        end

        # Special handling for request_user_feedback: don't show as tool call
        unless call[:name] == "request_user_feedback"
          @ui&.show_tool_call(call[:name], call[:arguments])
        end

        # Execute tool
        begin
          tool = @tool_registry.get(call[:name])

          # Parse and validate arguments with JSON repair capability
          args = Utils::ArgumentsParser.parse_and_validate(call, @tool_registry)

          # Special handling for TodoManager: inject todos array
          if call[:name] == "todo_manager"
            args[:todos_storage] = @todos
          end

          # For safe_shell, skip safety check if user has already confirmed
          if call[:name] == "safe_shell" || call[:name] == "shell"
            args[:skip_safety_check] = true
          end

          # Show progress for potentially slow tools (no prefix newline)
          if potentially_slow_tool?(call[:name], args)
            progress_message = build_tool_progress_message(call[:name], args)
            @ui&.show_progress(progress_message, prefix_newline: false)
          end

          result = tool.execute(**args)

          # Clear progress if shown
          @ui&.clear_progress if potentially_slow_tool?(call[:name], args)

          # Hook: after_tool_use
          @hooks.trigger(:after_tool_use, call, result)

          # Update todos display after todo_manager execution
          if call[:name] == "todo_manager"
            @ui&.update_todos(@todos.dup)
          end

          # Special handling for request_user_feedback: show directly as message
          if call[:name] == "request_user_feedback"
            if result.is_a?(Hash) && result[:message]
              @ui&.show_assistant_message(result[:message])
            end
            awaiting_feedback = true
          else
            @ui&.show_tool_result(tool.format_result(result))
          end
          
          results << build_success_result(call, result)
        rescue StandardError => e
          # Log complete error information to debug_logs for troubleshooting
          @debug_logs << {
            timestamp: Time.now.iso8601,
            event: "tool_execution_error",
            tool_name: call[:name],
            tool_args: call[:arguments],
            error_class: e.class.name,
            error_message: e.message,
            backtrace: e.backtrace&.first(20) # Keep first 20 lines of backtrace
          }

          @hooks.trigger(:on_tool_error, call, e)
          @ui&.show_tool_error(e)
          # Use build_denied_result with system_injected=true so LLM knows it can retry
          results << build_denied_result(call, e.message, true)
        end
      end

      {
        denied: denied,
        feedback: feedback,
        tool_results: results,
        awaiting_feedback: awaiting_feedback
      }
    end

    def observe(response, tool_results)
      # Add tool results as messages
      # Use Client to format results based on API type (Anthropic vs OpenAI)
      return if tool_results.empty?

      formatted_messages = @client.format_tool_results(response, tool_results, model: @config.model)
      formatted_messages.each { |msg| @messages << msg }
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

    # Check if a tool is potentially slow and should show progress
    private def potentially_slow_tool?(tool_name, args)
      case tool_name.to_s.downcase
      when 'shell', 'safe_shell'
        # Check if the command is a slow command
        command = args[:command] || args['command']
        return false unless command

        # List of slow command patterns
        slow_patterns = [
          /bundle\s+(install|exec\s+rspec|exec\s+rake)/,
          /npm\s+(install|run\s+test|run\s+build)/,
          /yarn\s+(install|test|build)/,
          /pnpm\s+install/,
          /cargo\s+(build|test)/,
          /go\s+(build|test)/,
          /make\s+(test|build)/,
          /pytest/,
          /jest/
        ]

        slow_patterns.any? { |pattern| command.match?(pattern) }
      when 'web_fetch', 'web_search'
        true  # Network operations can be slow
      else
        false  # Most file operations are fast
      end
    end

    # Build progress message for tool execution
    private def build_tool_progress_message(tool_name, args)
      case tool_name.to_s.downcase
      when 'shell', 'safe_shell'
        "Running command"
      when 'web_fetch'
        "Fetching web page"
      when 'web_search'
        "Searching web"
      else
        "Executing #{tool_name}"
      end
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

      # Track cache usage statistics (global)
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

      # Track cache usage for current task
      if @task_cache_stats
        @task_cache_stats[:total_requests] += 1

        if usage[:cache_creation_input_tokens]
          @task_cache_stats[:cache_creation_input_tokens] += usage[:cache_creation_input_tokens]
        end

        if usage[:cache_read_input_tokens]
          @task_cache_stats[:cache_read_input_tokens] += usage[:cache_read_input_tokens]
          @task_cache_stats[:cache_hit_requests] += 1
        end
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

    # Estimate token count for a message content
    # Simple approximation: characters / 4 (English text)
    # For Chinese/other languages, characters / 2 is more accurate
    # This is a rough estimate for compression triggering purposes
    private def estimate_tokens(content)
      return 0 if content.nil?

      text = if content.is_a?(String)
               content
             elsif content.is_a?(Array)
               # Handle content arrays (e.g., with images)
               # Add safety check to prevent nil.compact error
               mapped = content.map { |c| c[:text] if c.is_a?(Hash) }
               (mapped || []).compact.join
             else
               content.to_s
             end

      return 0 if text.empty?

      # Detect language mix - count non-ASCII characters
      ascii_count = text.bytes.count { |b| b < 128 }
      total_bytes = text.bytes.length

      # Mix ratio (1.0 = all English, 0.5 = all Chinese)
      mix_ratio = total_bytes > 0 ? ascii_count.to_f / total_bytes : 1.0

      # English: ~4 chars/token, Chinese: ~2 chars/token
      base_chars_per_token = mix_ratio * 4 + (1 - mix_ratio) * 2

      (text.length / base_chars_per_token).to_i + 50 # Add overhead for message structure
    end

    # Calculate total token count for all messages
    # Returns estimated tokens and breakdown by category
    private def total_message_tokens
      system_tokens = 0
      user_tokens = 0
      assistant_tokens = 0
      tool_tokens = 0
      summary_tokens = 0

      @messages.each do |msg|
        tokens = estimate_tokens(msg[:content])
        case msg[:role]
        when "system"
          system_tokens += tokens
        when "user"
          user_tokens += tokens
        when "assistant"
          assistant_tokens += tokens
        when "tool"
          tool_tokens += tokens
        end
      end

      {
        total: system_tokens + user_tokens + assistant_tokens + tool_tokens,
        system: system_tokens,
        user: user_tokens,
        assistant: assistant_tokens,
        tool: tool_tokens
      }
    end

    # Compression thresholds
    COMPRESSION_THRESHOLD = 80_000  # Trigger compression when exceeding this (in tokens)
    MESSAGE_COUNT_THRESHOLD = 100   # Trigger compression when exceeding this (in message count)
    TARGET_COMPRESSED_TOKENS = 70_000  # Target size after compression
    MAX_RECENT_MESSAGES = 30  # Keep this many recent message pairs intact

    def compress_messages_if_needed
      # Check if compression is enabled
      return nil unless @config.enable_compression

      # Calculate total tokens and message count
      token_counts = total_message_tokens
      total_tokens = token_counts[:total]
      message_count = @messages.length

      # Check if we should trigger compression
      # Either: token count exceeds threshold OR message count exceeds threshold
      token_threshold_exceeded = total_tokens >= COMPRESSION_THRESHOLD
      message_count_exceeded = message_count >= MESSAGE_COUNT_THRESHOLD

      # Only compress if we exceed at least one threshold
      return nil unless token_threshold_exceeded || message_count_exceeded

      # Calculate how much we need to reduce
      reduction_needed = total_tokens - TARGET_COMPRESSED_TOKENS

      # Don't compress if reduction is minimal (< 10% of current size)
      # Only apply this check when triggered by token threshold
      if token_threshold_exceeded && reduction_needed < (total_tokens * 0.1)
        return nil
      end

      # If only message count threshold is exceeded, force compression
      # to keep conversation history manageable

      # Calculate target size for recent messages based on compression level
      target_recent_count = calculate_target_recent_count(reduction_needed)

      # Increment compression level for progressive summarization
      @compression_level += 1

      # Get the most recent N messages, ensuring tool_calls/tool results pairs are kept together
      recent_messages = get_recent_messages_with_tool_pairs(@messages, target_recent_count)
      recent_messages = [] if recent_messages.nil?

      # Build compression instruction message (to be inserted into conversation)
      compression_message = @message_compressor.build_compression_message(@messages, recent_messages: recent_messages)

      return nil if compression_message.nil?

      # Return compression context for agent to handle
      {
        compression_message: compression_message,
        recent_messages: recent_messages,
        original_token_count: total_tokens,
        original_message_count: @messages.length,
        compression_level: @compression_level
      }
    end

    # Handle compression response and rebuild message list
    def handle_compression_response(response, compression_context)
      # Extract compressed content from response
      compressed_content = response[:content]

      # Track cost for compression call
      track_cost(response[:usage], raw_api_usage: response[:raw_api_usage])

      # Rebuild message list with compression
      # Note: we need to remove the compression instruction message we just added
      original_messages = @messages[0..-2]  # All except the last (compression instruction)
      
      @messages = @message_compressor.rebuild_with_compression(
        compressed_content,
        original_messages: original_messages,
        recent_messages: compression_context[:recent_messages]
      )

      # Track this compression
      @compressed_summaries << {
        level: compression_context[:compression_level],
        message_count: compression_context[:original_message_count],
        timestamp: Time.now.iso8601,
        strategy: :insert_then_compress
      }

      final_tokens = total_message_tokens[:total]

      # Show compression info
      @ui&.show_info(
        "History compressed (~#{compression_context[:original_token_count]} -> ~#{final_tokens} tokens, " \
        "level #{compression_context[:compression_level]})"
      )
    end

    # Calculate how many recent messages to keep based on how much we need to compress
    private def calculate_target_recent_count(reduction_needed)
      # We want recent messages to be around 20-30% of the total target
      # This keeps the context window useful without being too large
      tokens_per_message = 500  # Average estimate for a message with content

      # Target recent messages budget (~20% of target compressed size)
      recent_budget = (TARGET_COMPRESSED_TOKENS * 0.2).to_i
      target_messages = (recent_budget / tokens_per_message).to_i

      # Clamp to reasonable bounds
      [[target_messages, 20].max, MAX_RECENT_MESSAGES].min
    end

    # Generate hierarchical summary based on compression level
    # Level 1: Detailed summary with files, decisions, features
    # Level 2: Concise summary with key items
    # Level 3: Minimal summary (just project type)
    # Level 4+: Ultra-minimal (single line)
    private def generate_hierarchical_summary(messages)
      level = @compression_level

      # Extract key information from messages
      extracted = extract_key_information(messages)

      summary_text = case level
      when 1
        generate_level1_summary(extracted)
      when 2
        generate_level2_summary(extracted)
      when 3
        generate_level3_summary(extracted)
      else
        generate_level4_summary(extracted)
      end

      {
        role: "user",
        content: "[SYSTEM][COMPRESSION LEVEL #{level}] #{summary_text}",
        system_injected: true,
        compression_level: level
      }
    end

    # Extract key information from messages for summarization
    private def extract_key_information(messages)
      return empty_extraction_data if messages.nil?

      {
        # Message counts
        user_msgs: messages.count { |m| m[:role] == "user" },
        assistant_msgs: messages.count { |m| m[:role] == "assistant" },
        tool_msgs: messages.count { |m| m[:role] == "tool" },

        # Tools used
        tools_used: extract_from_messages(messages, :assistant) { |m| extract_tool_names(m[:tool_calls]) },

        # Files created/modified
        files_created: extract_from_messages(messages, :tool) { |m| filter_write_results(parse_write_result(m[:content]), :created) },
        files_modified: extract_from_messages(messages, :tool) { |m| filter_write_results(parse_write_result(m[:content]), :modified) },

        # Key decisions (limit to first 5)
        decisions: extract_from_messages(messages, :assistant) { |m| extract_decision_text(m[:content]) }.first(5),

        # Completed tasks (from TODO results)
        completed_tasks: extract_from_messages(messages, :tool) { |m| filter_todo_results(parse_todo_result(m[:content]), :completed) },

        # Current in-progress work
        in_progress: find_in_progress(messages),

        # Key results from shell commands
        shell_results: extract_from_messages(messages, :tool) { |m| parse_shell_result(m[:content]) }
      }
    end

    # Helper: safely extract from messages with proper nil handling
    private def extract_from_messages(messages, role_filter = nil, &block)
      return [] if messages.nil?

      results = messages
        .select { |m| role_filter.nil? || m[:role] == role_filter.to_s }
        .map(&block)
        .compact

      # Flatten if we have nested arrays (from methods returning arrays of items)
      results.any? { |r| r.is_a?(Array) } ? results.flatten.uniq : results.uniq
    end

    # Helper: extract tool names from tool_calls
    private def extract_tool_names(tool_calls)
      return [] unless tool_calls.is_a?(Array)
      tool_calls.map { |tc| tc.dig(:function, :name) }
    end

    # Helper: filter write results by action
    private def filter_write_results(result, action)
      result && result[:action] == action ? result[:file] : nil
    end

    # Helper: filter todo results by status
    private def filter_todo_results(result, status)
      result && result[:status] == status ? result[:task] : nil
    end

    # Helper: extract decision text from content (returns array of decisions or empty array)
    private def extract_decision_text(content)
      return [] unless content.is_a?(String)
      return [] unless content.include?("decision") || content.include?("chose to") || content.include?("using")

      sentences = content.split(/[.!?]/).select do |s|
        s.include?("decision") || s.include?("chose") || s.include?("using") ||
        s.include?("decided") || s.include?("will use") || s.include?("selected")
      end
      sentences.map(&:strip).map { |s| s[0..100] }
    end

    # Helper: find in-progress task
    private def find_in_progress(messages)
      return nil if messages.nil?

      messages.reverse_each do |m|
        if m[:role] == "tool"
          content = m[:content].to_s
          if content.include?("in progress") || content.include?("working on")
            return content[/[Tt]ODO[:\s]+(.+)/, 1]&.strip || content[/[Ww]orking[Oo]n[:\s]+(.+)/, 1]&.strip
          end
        end
      end
      nil
    end

    # Helper: empty extraction data
    private def empty_extraction_data
      {
        user_msgs: 0,
        assistant_msgs: 0,
        tool_msgs: 0,
        tools_used: [],
        files_created: [],
        files_modified: [],
        decisions: [],
        completed_tasks: [],
        in_progress: nil,
        shell_results: []
      }
    end

    private def parse_write_result(content)
      return nil unless content.is_a?(String)

      # Check for "Created: path" or "Updated: path" patterns
      if content.include?("Created:")
        { action: "created", file: content[/Created:\s*(.+)/, 1]&.strip }
      elsif content.include?("Updated:") || content.include?("modified")
        { action: "modified", file: content[/Updated:\s*(.+)/, 1]&.strip || content[/File written to:\s*(.+)/, 1]&.strip }
      else
        nil
      end
    end

    private def parse_todo_result(content)
      return nil unless content.is_a?(String)

      if content.include?("completed")
        { status: "completed", task: content[/completed[:\s]*(.+)/i, 1]&.strip || "task" }
      elsif content.include?("added")
        { status: "added", task: content[/added[:\s]*(.+)/i, 1]&.strip || "task" }
      else
        nil
      end
    end

    private def parse_shell_result(content)
      return nil unless content.is_a?(String)

      if content.include?("passed") || content.include?("success")
        "tests passed"
      elsif content.include?("failed") || content.include?("error")
        "command failed"
      elsif content =~ /bundle install|npm install|go mod download/
        "dependencies installed"
      elsif content.include?("Installed")
        content[/Installed:\s*(.+)/, 1]&.strip
      else
        nil
      end
    end

    # Level 1: Detailed summary (for first compression)
    private def generate_level1_summary(data)
      parts = []

      parts << "Previous conversation summary (#{data[:user_msgs]} user requests, #{data[:assistant_msgs]} responses, #{data[:tool_msgs]} tool calls):"

      # Files created
      if data[:files_created].any?
        files_list = data[:files_created].map { |f| File.basename(f) }.join(", ")
        parts << "Created: #{files_list}"
      end

      # Files modified
      if data[:files_modified].any?
        files_list = data[:files_modified].map { |f| File.basename(f) }.join(", ")
        parts << "Modified: #{files_list}"
      end

      # Completed tasks
      if data[:completed_tasks].any?
        tasks_list = data[:completed_tasks].first(3).join(", ")
        parts << "Completed: #{tasks_list}"
      end

      # In progress
      if data[:in_progress]
        parts << "In Progress: #{data[:in_progress]}"
      end

      # Key decisions
      if data[:decisions].any?
        decisions_text = data[:decisions].map { |d| d.gsub(/\n/, " ").strip }.join("; ")
        parts << "Decisions: #{decisions_text}"
      end

      # Tools used
      if data[:tools_used].any?
        parts << "Tools: #{data[:tools_used].join(', ')}"
      end

      parts << "Continuing with recent conversation..."
      parts.join("\n")
    end

    # Level 2: Concise summary (for second compression)
    private def generate_level2_summary(data)
      parts = []

      parts << "Conversation summary:"

      # Key files (limit to most important)
      all_files = (data[:files_created] + data[:files_modified]).uniq
      if all_files.any?
        key_files = all_files.first(5).map { |f| File.basename(f) }.join(", ")
        parts << "Files: #{key_files}"
      end

      # Key accomplishments
      accomplishments = []
      accomplishments << "#{data[:completed_tasks].size} tasks completed" if data[:completed_tasks].any?
      accomplishments << "#{data[:tool_msgs]} tools executed" if data[:tool_msgs] > 0
      accomplishments << "Level #{data[:completed_tasks].size + 1} progress" if data[:in_progress]

      parts << accomplishments.join(", ") if accomplishments.any?

      parts << "Recent context follows..."
      parts.join("\n")
    end

    # Level 3: Minimal summary (for third compression)
    private def generate_level3_summary(data)
      parts = []

      parts << "Project progress:"

      # Just counts and key items
      all_files = (data[:files_created] + data[:files_modified]).uniq
      parts << "#{all_files.size} files modified, #{data[:completed_tasks].size} tasks done"

      if data[:in_progress]
        parts << "Currently: #{data[:in_progress]}"
      end

      parts << "See recent messages for details."
      parts.join("\n")
    end

    # Level 4: Ultra-minimal summary (for fourth+ compression)
    private def generate_level4_summary(data)
      all_files = (data[:files_created] + data[:files_modified]).uniq
      "Progress: #{data[:completed_tasks].size} tasks, #{all_files.size} files. Recent: #{data[:tools_used].last(3).join(', ')}"
    end

    def get_recent_messages_with_tool_pairs(messages, count)
      # This method ensures that assistant messages with tool_calls are always kept together
      # with ALL their corresponding tool_results, maintaining the correct order.
      # This is critical for Bedrock Claude API which validates the tool_calls/tool_results pairing.

      return [] if messages.nil? || messages.empty?

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

    def confirm_tool_use?(call)
      # Show preview first and check for errors
      preview_error = show_tool_preview(call)

      # If preview detected an error, auto-deny and provide feedback
      if preview_error && preview_error[:error]
        feedback = build_preview_error_feedback(call[:name], preview_error)
        return { approved: false, feedback: feedback, system_injected: true }
      end

      # Request confirmation via UI
      if @ui
        prompt_text = format_tool_prompt(call)
        result = @ui.request_confirmation(prompt_text, default: true)

        case result
        when true
          { approved: true, feedback: nil }
        when false, nil
          # User denied - add visual marker based on tool type
          tool_name_capitalized = call[:name].capitalize
          @ui&.show_info("  ↳ #{tool_name_capitalized} cancelled", prefix_newline: false)
          { approved: false, feedback: nil }
        else
          # String feedback - also add visual marker
          tool_name_capitalized = call[:name].capitalize
          @ui&.show_info("  ↳ #{tool_name_capitalized} cancelled", prefix_newline: false)
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
        "Tool edit denied: The edit operation will fail because the old_string was not found in the file. " \
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

        @ui&.show_file_error("Edit file error")
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

      # Inject TODO reminder for non-todo_manager tools
      formatted_result = inject_todo_reminder(call[:name], formatted_result)

      {
        id: call[:id],
        content: JSON.generate(formatted_result)
      }
    end

    # Inject TODO reminder into tool results for non-todo_manager tools
    # This helps AI remember to mark TODOs as complete after executing tasks
    private def inject_todo_reminder(tool_name, result)
      # Skip injection for todo_manager tool itself to avoid redundancy
      return result if tool_name == "todo_manager"

      # Get pending TODOs
      todo_tool = @tool_registry.get("todo_manager")
      return result unless todo_tool

      pending_todos = begin
        todo_result = todo_tool.execute(action: "list", todos_storage: @todos)
        if todo_result.is_a?(Hash) && todo_result[:todos]
          todo_result[:todos].select { |t| t[:status] == "pending" }
        else
          []
        end
      rescue
        []
      end

      # Only inject reminder if there are pending TODOs
      return result unless pending_todos && !pending_todos.empty?

      # Create a friendly reminder message
      reminder = "\n\n📋 REMINDER: You have #{pending_todos.length} pending TODO(s). " \
                 "After completing each task, remember to mark it as complete using " \
                 "todo_manager with action 'complete' and the task id."

      # Inject reminder based on result type
      case result
      when String
        result + reminder
      when Hash
        result.merge({ _todo_reminder: reminder.strip })
      when Array
        result + [{ _todo_reminder: reminder.strip }]
      else
        result
      end
    end

    def build_error_result(call, error_message)
      {
        id: call[:id],
        content: JSON.generate({ error: error_message })
      }
    end

    def build_denied_result(call, user_feedback = nil, system_injected = false)
      if system_injected
        # System-generated feedback (e.g., from preview errors)
        tool_content = {
          error: "Tool #{call[:name]} denied: #{user_feedback}",
          system_injected: true
        }
      else
        # User manually denied or provided feedback
        message = if user_feedback && !user_feedback.empty?
                    "Tool use denied by user. User feedback: #{user_feedback}"
                  else
                    "Tool use denied by user"
                  end

        tool_content = {
          error: message,
          user_feedback: user_feedback
        }
      end

      {
        id: call[:id],
        content: JSON.generate(tool_content)
      }
    end

    def build_planned_result(call)
      {
        id: call[:id],
        content: JSON.generate({ planned: true, message: "Tool execution skipped (plan mode)" })
      }
    end

    def build_result(status, error: nil)
      # Calculate iterations for current task only
      task_iterations = @iterations - (@task_start_iterations || 0)

      # Calculate cost for current task only
      task_cost = @total_cost - (@task_start_cost || 0)

      {
        status: status,
        session_id: @session_id,
        iterations: task_iterations,  # Show only current task iterations
        duration_seconds: Time.now - @start_time,
        total_cost_usd: task_cost.round(4),  # Show only current task cost
        cost_source: @task_cost_source,  # Add cost source for this task
        cache_stats: @task_cache_stats || @cache_stats,  # Use task cache stats if available
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
      @tool_registry.register(Tools::RequestUserFeedback.new)
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
        image_url = Utils::FileProcessor.image_path_to_data_url(image_path)
        content << { type: "image_url", image_url: { url: image_url } }
      end

      content
    end


  end
end
