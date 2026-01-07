# frozen_string_literal: true

require "securerandom"
require "json"

module Clacky
  class Agent
    attr_reader :session_id, :messages, :iterations, :total_cost, :working_dir, :created_at, :total_tasks

    # Pricing per 1M tokens (approximate - adjust based on actual model)
    PRICING = {
      input: 0.50,  # $0.50 per 1M input tokens
      output: 1.50  # $1.50 per 1M output tokens
    }.freeze

    # System prompt for the coding agent
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are an expert coding agent and technical co-founder, designed to help non-technical users complete software development projects.

      ⚠️ CRITICAL RULE FOR TODO MANAGER:
      When using todo_manager to add tasks, you MUST continue working immediately after adding ALL todos.
      Adding todos is NOT completion - it's just the planning phase!
      Workflow: add todo 1 → add todo 2 → add todo 3 → START WORKING on todo 1 → complete(1) → work on todo 2 → complete(2) → etc.
      NEVER stop after just adding todos without executing them!

      Your role is to:
      - Understand project requirements and translate them into technical solutions
      - Write clean, maintainable, and well-documented code
      - Follow best practices and industry standards
      - Explain technical concepts in simple terms when needed
      - Proactively identify potential issues and suggest improvements
      - Help with debugging, testing, and deployment

      CRITICAL RULES:
      1. **ALWAYS USE TOOLS** - Don't just describe or return code, USE THE TOOLS to actually create/modify files
      2. When asked to "write" or "create" code - use the `write` tool to create the actual file
      3. When asked to "modify" or "update" code - use the `edit` tool to change the actual file
      4. When asked to "run" or "execute" - use the `shell` tool to run the actual command
      5. Never just print code in your response - always create the actual files using tools
      6. After creating files, you can briefly explain what you did

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

      Available tools:
      - todo_manager: Manage TODO items (add/list/complete/remove tasks) - USE THIS for planning!
        * IMPORTANT: After adding TODOs, don't stop! Continue to execute them immediately.
        * Example workflow: add todos → execute first todo → complete(1) → execute second todo → complete(2) → ...
      - file_reader: Read file contents
      - write: Create new files (USE THIS to write code files!)
      - edit: Modify existing files (USE THIS to update code!)
      - glob: Find files by pattern
      - grep: Search for text in files
      - shell: Execute shell commands (USE THIS to run programs!)
      - calculator: Perform calculations
      - web_search: Search the web for information
      - web_fetch: Fetch content from URLs

      Remember: You are an ACTION-ORIENTED agent. When users ask you to do something, DO IT using tools, don't just talk about it!
    PROMPT

    def initialize(client, config = {}, working_dir: nil)
      @client = client
      @config = config.is_a?(AgentConfig) ? config : AgentConfig.new(config)
      @tool_registry = ToolRegistry.new
      @hooks = HookManager.new
      @session_id = SecureRandom.uuid
      @messages = []
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
      @iterations = session_data.dig(:stats, :total_iterations) || 0
      @total_cost = session_data.dig(:stats, :total_cost_usd) || 0.0
      @working_dir = session_data[:working_dir]
      @created_at = session_data[:created_at]
      @total_tasks = session_data.dig(:stats, :total_tasks) || 0
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

          # Act: Execute tool calls
          action_result = act(response[:tool_calls], &block)

          # Observe: Add tool results to conversation context
          observe(response, action_result[:tool_results])

          # Check if user denied any tool
          if action_result[:denied]
            # If user provided feedback, add it as a new user message and continue
            if action_result[:feedback] && !action_result[:feedback].empty?
              @messages << { role: "user", content: action_result[:feedback] }
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
    def to_session_data
      # Get first user message for preview
      first_user_msg = @messages.find { |m| m[:role] == "user" }
      first_message_preview = first_user_msg ? first_user_msg[:content][0..100] : "No messages"

      {
        session_id: @session_id,
        created_at: @created_at,
        updated_at: Time.now.iso8601,
        working_dir: @working_dir,
        config: {
          model: @config.model,
          permission_mode: @config.permission_mode.to_s,
          max_iterations: @config.max_iterations,
          max_cost_usd: @config.max_cost_usd
        },
        stats: {
          total_tasks: @total_tasks,
          total_iterations: @iterations,
          total_cost_usd: @total_cost.round(4),
          duration_seconds: @start_time ? (Time.now - @start_time).round(2) : 0
        },
        messages: @messages,
        first_user_message: first_message_preview
      }
    end

    private

    def build_system_prompt
      prompt = SYSTEM_PROMPT.dup

      # Load .clackyrules if exists
      rules_file = File.join(@working_dir, ".clackyrules")
      if File.exist?(rules_file)
        rules_content = File.read(rules_file).strip
        unless rules_content.empty?
          prompt += "\n\n" + "=" * 80 + "\n"
          prompt += "PROJECT-SPECIFIC RULES (from .clackyrules):\n"
          prompt += "=" * 80 + "\n"
          prompt += rules_content
          prompt += "\n" + "=" * 80 + "\n"
          prompt += "⚠️ IMPORTANT: Follow these project-specific rules at all times!\n"
          prompt += "=" * 80
        end
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
      ensure
        progress.finish
      end
    end

    def act(tool_calls, &block)
      return { denied: false, feedback: nil, tool_results: [] } unless tool_calls

      denied = false
      feedback = nil
      results = tool_calls.map do |call|
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

          confirmation = confirm_tool_use?(call, &block)
          unless confirmation[:approved]
            emit_event(:tool_denied, call, &block)
            denied = true
            feedback = confirmation[:feedback] if confirmation[:feedback]
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

      {
        denied: denied,
        feedback: feedback,
        tool_results: results
      }
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
      threshold = @config.keep_recent_messages + 5 # +5 to avoid compressing too frequently
      return if @messages.size <= threshold

      puts "\n🗜️  Compressing conversation history (#{@messages.size} messages -> ~#{@config.keep_recent_messages + 2})" if @config.verbose

      # Find the system message (should be first)
      system_msg = @messages.find { |m| m[:role] == "system" }

      # Get the most recent N messages, ensuring tool_use/tool_result pairs are kept together
      recent_messages = get_recent_messages_with_tool_pairs(@messages, @config.keep_recent_messages)

      # Get messages to compress (everything except system and recent)
      messages_to_compress = @messages.reject { |m| m[:role] == "system" || recent_messages.include?(m) }

      return if messages_to_compress.empty?

      # Create summary of compressed messages
      summary = summarize_messages(messages_to_compress)

      # Rebuild messages array: [system, summary, recent_messages]
      @messages = [system_msg, summary, *recent_messages].compact
    end

    def get_recent_messages_with_tool_pairs(messages, count)
      # Start from the end and work backwards
      recent = []
      i = messages.size - 1

      while i >= 0 && recent.size < count
        msg = messages[i]
        recent.unshift(msg)

        # If this is a tool result, make sure we include the corresponding assistant message with tool_calls
        if msg[:role] == "tool"
          # Find the previous assistant message with tool_calls
          j = i - 1
          while j >= 0
            prev_msg = messages[j]
            if prev_msg[:role] == "assistant" && prev_msg[:tool_calls]
              # Check if this assistant message has the tool_call that matches our tool_result
              has_matching_call = prev_msg[:tool_calls].any? { |tc| tc[:id] == msg[:tool_call_id] }
              if has_matching_call && !recent.include?(prev_msg)
                # Insert at the beginning to maintain order
                recent.unshift(prev_msg)
                break
              end
            end
            j -= 1
          end
        end

        i -= 1
      end

      recent
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

      # Show preview first
      show_tool_preview(call)

      # Then show the confirmation prompt with better formatting
      prompt_text = format_tool_prompt(call)
      puts "\n❓ #{prompt_text}"
      print "   (Enter/y to approve, n to deny, or provide feedback): "

      response = $stdin.gets
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

        case call[:name]
        when "edit"
          filename = File.basename(args[:file_path] || "unknown")
          "Edit(#{filename})"
        when "write"
          filename = File.basename(args[:path] || "unknown")
          if File.exist?(args[:path])
            "Write(#{filename}) - overwrite existing"
          else
            "Write(#{filename}) - create new"
          end
        when "shell"
          "Shell(#{args[:command]&.split&.first || 'command'})"
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

        case call[:name]
        when "write"
          show_write_preview(args)
        when "edit"
          show_edit_preview(args)
        when "shell"
          show_shell_preview(args)
        else
          puts "\nArgs: #{call[:arguments]}"
        end
      rescue JSON::ParserError
        puts "   Args: #{call[:arguments]}"
      end
    end

    def show_write_preview(args)
      path = args[:path]
      new_content = args[:content] || ""

      puts "\n📝 File: #{path}"

      if File.exist?(path)
        old_content = File.read(path)
        puts "Modifying existing file\n"
        show_diff(old_content, new_content, max_lines: 50)
      else
        puts "Creating new file"
        puts "Content preview (first 20 lines):"
        preview_lines = new_content.lines.first(20)
        preview_lines.each { |line| puts "   > #{line.chomp}" }
        puts "   ... (#{new_content.lines.size} lines total)" if new_content.lines.size > 20
      end
    end

    def show_edit_preview(args)
      path = args[:file_path]
      old_string = args[:old_string] || ""
      new_string = args[:new_string] || ""

      puts "\n📝 File: #{path}"

      if File.exist?(path)
        file_content = File.read(path)
        new_content = file_content.sub(old_string, new_string)
        show_diff(file_content, new_content, max_lines: 50)
      else
        puts "   ⚠️  File not found"
      end
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
      @tool_registry.register(Tools::TodoManager.new)
    end
  end
end
