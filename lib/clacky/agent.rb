# frozen_string_literal: true

require "securerandom"
require "json"
require "tty-prompt"
require "set"
require_relative "utils/arguments_parser"
require_relative "utils/file_processor"

# Load all agent modules
require_relative "agent/message_compressor"
require_relative "agent/message_compressor_helper"
require_relative "agent/tool_executor"
require_relative "agent/cost_tracker"
require_relative "agent/session_serializer"
require_relative "agent/skill_manager"
require_relative "agent/system_prompt_builder"
require_relative "agent/llm_caller"
require_relative "agent/time_machine"
require_relative "agent/memory_updater"

module Clacky
  class Agent
    # Include all functionality modules
    include MessageCompressorHelper
    include ToolExecutor
    include CostTracker
    include SessionSerializer
    include SkillManager
    include SystemPromptBuilder
    include LlmCaller
    include TimeMachine
    include MemoryUpdater

    attr_reader :session_id, :messages, :iterations, :total_cost, :working_dir, :created_at, :total_tasks, :todos,
                :cache_stats, :cost_source, :ui, :skill_loader, :agent_profile

    def initialize(client, config = {}, working_dir: nil, ui: nil, profile: "coding")
      @client = client  # Client for current model
      @config = config.is_a?(AgentConfig) ? config : AgentConfig.new(config)
      @agent_profile = AgentProfile.load(profile)
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
      @message_compressor = MessageCompressor.new(@client, model: current_model)

      # Load brand config — used for brand skill decryption and background sync
      @brand_config = Clacky::BrandConfig.load

      # Skill loader for skill management (brand_config enables encrypted skill loading)
      @skill_loader = SkillLoader.new(@working_dir, brand_config: @brand_config)

      # Background sync: compare remote skill versions and download updates quietly.
      # Runs in a daemon thread so Agent startup is never blocked.
      @brand_config.sync_brand_skills_async!

      # Initialize Time Machine
      init_time_machine

      # Register built-in tools
      register_builtin_tools
    end

    # Restore from a saved session
    def self.from_session(client, config, session_data, ui: nil, profile: "coding")
      agent = new(client, config, ui: ui, profile: profile)
      agent.restore_session(session_data)
      agent
    end

    def add_hook(event, &block)
      @hooks.add(event, &block)
    end

    # Switch to a different model by name
    # Returns true if switched, false if model not found
    def switch_model(model_name)
      if @config.switch_model(model_name)
        # Re-create client for new model
        @client = Clacky::Client.new(
          @config.api_key,
          base_url: @config.base_url,
          anthropic_format: @config.anthropic_format?
        )
        # Update message compressor with new client and model
        @message_compressor = MessageCompressor.new(@client, model: current_model)
        true
      else
        false
      end
    end

    # Get list of available model names
    def available_models
      @config.model_names
    end

    # Get current model configuration info
    def current_model_info
      model = @config.current_model
      return nil unless model

      {
        name: model["name"],
        model: model["model"],
        base_url: model["base_url"]
      }
    end

    # Get current model name
    private def current_model
      @config.model_name
    end

    def run(user_input, images: [])
      # Start new task for Time Machine
      task_id = start_new_task
      
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
      @messages << { role: "user", content: user_content, task_id: task_id, created_at: Time.now.to_f }
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

          # Skip if compression happened (response is nil)
          next if response.nil?

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

            # Inject memory update prompt and let the loop handle it naturally
            next if inject_memory_prompt!

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
            observe(response, action_result[:tool_results])
            break
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
        
        # Save snapshots of modified files for Time Machine
        if @modified_files_in_task && !@modified_files_in_task.empty?
          save_modified_files_snapshot(@modified_files_in_task)
          @modified_files_in_task = []  # Reset for next task
        end

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
        Clacky::Logger.error("agent_run_error", error: e)

        # Build error result for session data, but let CLI handle error display
        result = build_result(:error, error: e.message)
        raise
      ensure
        # Always clean up memory update messages, even if interrupted or error occurred
        cleanup_memory_messages
      end
    end

    private def think
      # Check API key before starting progress indicator
      if @client.instance_variable_get(:@api_key).nil? || @client.instance_variable_get(:@api_key).empty?
        @ui&.show_error("API key is not configured! Please run /config to set up your API key.")
        raise AgentError, "API key is not configured"
      end

      # Check if compression is needed
      compression_context = compress_messages_if_needed(force: false)

      # If compression is triggered, insert compression message and handle it
      if compression_context
        # Show compression start notification
        @ui&.show_info(
          "Message history compression starting (~#{compression_context[:original_token_count]} tokens, #{compression_context[:original_message_count]} messages) - Level #{compression_context[:compression_level]}"
        )
        compression_message = compression_context[:compression_message]
        @messages << compression_message
        compression_handled = false
        begin
          response = call_llm
          handle_compression_response(response, compression_context)
          compression_handled = true
        ensure
          # If interrupted or failed, remove the dangling compression message
          # so it doesn't pollute future conversation turns
          @messages.pop if !compression_handled && @messages.last.equal?(compression_message)
        end
        return nil
      end

      # Normal LLM call
      response = call_llm

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
      msg = { role: "assistant", task_id: @current_task_id }
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

    private def act(tool_calls)
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

        # Show preview for edit and write tools even in auto-approve mode
        if should_auto_execute?(call[:name], call[:arguments])
          # In auto-approve mode, show preview for edit and write tools
          if call[:name] == "edit" || call[:name] == "write"
            show_tool_preview(call)
          end
        else
          # Permission check (if not in auto-approve mode)
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

          # Special handling for InvokeSkill: inject agent and skill_loader
          if call[:name] == "invoke_skill"
            args[:agent] = self
            args[:skill_loader] = @skill_loader
          end

          # Special handling for Time Machine tools: inject agent
          if ["undo_task", "redo_task", "list_tasks"].include?(call[:name])
            args[:agent] = self
          end

          # For safe_shell, skip safety check if user has already confirmed
          if call[:name] == "safe_shell" || call[:name] == "shell"
            args[:skip_safety_check] = true
          end

          # Inject working_dir so tools don't rely on Dir.chdir global state
          args[:working_dir] = @working_dir if @working_dir

          # Automatic progress display after 2 seconds for any tool execution
          progress_shown = false
          progress_timer = nil
          output_buffer = nil
          
          if @ui
            progress_message = build_tool_progress_message(call[:name], args)
            
            # For shell commands, create shared output buffer
            if call[:name] == "shell" || call[:name] == "safe_shell"
              output_buffer = { content: "", timestamp: Time.now }
              args[:output_buffer] = output_buffer
            end
            
            progress_timer = Thread.new do
              sleep 2
              @ui.show_progress(progress_message, prefix_newline: false, output_buffer: output_buffer)
              progress_shown = true
            end
          end

          begin
            result = tool.execute(**args)
          ensure
            # Cancel timer and clear progress if shown
            if progress_timer
              progress_timer.kill
              progress_timer.join
            end
            @ui&.clear_progress if progress_shown
          end

          # Track modified files for Time Machine snapshots
          track_modified_files(call[:name], args)

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

            if @config.permission_mode == :auto_approve
              # auto_approve means no human is watching (unattended/scheduled tasks).
              # Inject an auto_reply so the LLM makes a reasonable decision and keeps going.
              result = result.merge(
                auto_reply: "No user is available. Please make a reasonable decision based on the context and continue."
              )
            else
              # confirm_all / confirm_safes — a human is present, truly wait for user input.
              awaiting_feedback = true
            end
          else
            # Use tool's format_result method to get display-friendly string
            formatted_result = tool.respond_to?(:format_result) ? tool.format_result(result) : result.to_s
            @ui&.show_tool_result(formatted_result)
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
          Clacky::Logger.error("tool_execution_error", tool: call[:name], error: e)

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

    private def observe(response, tool_results)
      # Add tool results as messages
      # Use Client to format results based on API type (Anthropic vs OpenAI)
      return if tool_results.empty?

      formatted_messages = @client.format_tool_results(response, tool_results, model: current_model)
      formatted_messages.each { |msg| @messages << msg.merge(task_id: @current_task_id) }
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

    private def should_stop?
      if @interrupted
        @interrupted = false  # Reset for next run
        return true
      end

      false
    end

    private def build_result(status, error: nil)
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

    private def format_tool_calls_for_api(tool_calls)
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

    private def register_builtin_tools
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
      @tool_registry.register(Tools::InvokeSkill.new)
      @tool_registry.register(Tools::UndoTask.new)
      @tool_registry.register(Tools::RedoTask.new)
      @tool_registry.register(Tools::ListTasks.new)
      @tool_registry.register(Tools::Browser.new)
    end

    # Fork a subagent with specified configuration
    # The subagent inherits all messages and tools from parent agent
    # Tools are not modified (for cache reuse), but forbidden tools are blocked at runtime via hooks
    # @param model [String, nil] Model name to use (nil = use current model)
    # @param forbidden_tools [Array<String>] List of tool names to forbid
    # @param system_prompt_suffix [String, nil] Additional instructions (inserted as user message for cache reuse)
    # @return [Agent] New subagent instance
    def fork_subagent(model: nil, forbidden_tools: [], system_prompt_suffix: nil)
      # Clone config to avoid affecting parent
      subagent_config = @config.dup

      # Switch to specified model if provided
      if model
        if model == "lite"
          # Special keyword: use lite model if available, otherwise fall back to default
          lite_model = subagent_config.lite_model
          if lite_model
            model_index = subagent_config.models.index(lite_model)
            subagent_config.switch_model(model_index) if model_index
          end
          # If no lite model, just use current (default) model
        else
          # Regular model name lookup
          model_index = subagent_config.model_names.index(model)
          if model_index
            subagent_config.switch_model(model_index)
          else
            raise AgentError, "Model '#{model}' not found in config. Available models: #{subagent_config.model_names.join(', ')}"
          end
        end
      end

      # Create new client for subagent
      subagent_client = Clacky::Client.new(
        subagent_config.api_key,
        base_url: subagent_config.base_url,
        anthropic_format: subagent_config.anthropic_format?
      )

      # Create subagent (reuses all tools from parent)
      subagent = self.class.new(
        subagent_client,
        subagent_config,
        working_dir: @working_dir,
        ui: @ui
      )

      # Deep clone messages to avoid cross-contamination
      subagent.instance_variable_set(:@messages, deep_clone(@messages))

      # Append system prompt suffix as user message (for cache reuse)
      if system_prompt_suffix
        messages = subagent.instance_variable_get(:@messages)

        # Build forbidden tools notice if any tools are forbidden
        forbidden_notice = if forbidden_tools.any?
          tool_list = forbidden_tools.map { |t| "`#{t}`" }.join(", ")
          "\n\n[System Notice] The following tools are disabled in this subagent and will be rejected if called: #{tool_list}"
        else
          ""
        end

        messages << {
          role: "user",
          content: "CRITICAL: TASK CONTEXT SWITCH - FORKED SUBAGENT MODE\n\nYou are now running as a forked subagent — a temporary, isolated agent spawned by the parent agent to handle a specific task. You run independently and cannot communicate back to the parent mid-task. When you finish (i.e., you stop calling tools and return a final response), your output will be automatically summarized and returned to the parent agent as a result so it can continue.\n\n#{system_prompt_suffix}#{forbidden_notice}",
          system_injected: true,
          subagent_instructions: true
        }

        # Insert an assistant acknowledgement so the conversation structure is complete:
        #   [user] role/constraints  →  [assistant] ack  →  [user] actual task (from run())
        # Without this, two consecutive user messages confuse the model about what to act on.
        messages << {
          role: "assistant",
          content: "Understood. I am now operating as a subagent with the constraints above. Please provide the task.",
          system_injected: true
        }
      end

      # Register hook to forbid certain tools at runtime (doesn't affect tool registry for cache)
      if forbidden_tools.any?
        subagent.add_hook(:before_tool_use) do |call|
          if forbidden_tools.include?(call[:name])
            {
              action: :deny,
              reason: "Tool '#{call[:name]}' is forbidden in this subagent context"
            }
          else
            { action: :allow }
          end
        end
      end

      # Mark subagent metadata for summary generation
      subagent.instance_variable_set(:@is_subagent, true)
      subagent.instance_variable_set(:@parent_message_count, @messages.length)

      subagent
    end

    # Generate summary from subagent execution
    # Extracts new messages added by subagent and creates a concise summary
    # This summary will replace the subagent instructions message in parent agent
    # @param subagent [Agent] The subagent that completed execution
    # @return [String] Summary text to insert into parent agent
    def generate_subagent_summary(subagent)
      parent_count = subagent.instance_variable_get(:@parent_message_count) || 0
      new_messages = subagent.messages[parent_count..-1] || []

      # Extract tool calls
      tool_calls = new_messages
        .select { |m| m[:role] == "assistant" && m[:tool_calls] }
        .flat_map { |m| m[:tool_calls].map { |tc| tc[:name] } }
        .uniq

      # Extract final assistant response
      last_response = new_messages
        .reverse
        .find { |m| m[:role] == "assistant" && m[:content] && !m[:content].empty? }
        &.dig(:content)

      # Build summary (this will replace the subagent instructions message)
      parts = []
      parts << "[SUBAGENT SUMMARY]"
      parts << "Completed in #{subagent.iterations} iterations, cost: $#{subagent.total_cost.round(4)}"
      parts << "Tools used: #{tool_calls.join(', ')}" if tool_calls.any?
      parts << ""
      parts << "Results:"
      parts << (last_response || "(No response)")

      parts.join("\n")
    end

    # Deep clone helper for messages using Marshal
    # @param obj [Object] Object to clone
    # @return [Object] Deep cloned object
    private def deep_clone(obj)
      Marshal.load(Marshal.dump(obj))
    end

    # Format user content with optional images
    # @param text [String] User's text input
    # @param images [Array<String>] Array of image file paths or data: URLs
    # @return [String|Array] String if no images, Array with text and image_url objects if images present
    private def format_user_content(text, images)
      return text if images.nil? || images.empty?

      content = []
      content << { type: "text", text: text } unless text.nil? || text.empty?

      images.each do |image|
        # Accept both file paths and pre-encoded data: URLs (e.g. from Web UI)
        image_url = if image.start_with?("data:")
                      image
                    else
                      Utils::FileProcessor.image_path_to_data_url(image)
                    end
        content << { type: "image_url", image_url: { url: image_url } }
      end

      content
    end

    # Track modified files for Time Machine snapshots
    # @param tool_name [String] Name of the tool that was executed
    # @param args [Hash] Arguments passed to the tool
    def track_modified_files(tool_name, args)
      @modified_files_in_task ||= []
      
      case tool_name
      when "write", "edit"
        file_path = args[:path]
        full_path = File.expand_path(file_path, @working_dir)
        @modified_files_in_task << full_path unless @modified_files_in_task.include?(full_path)
      end
    end
  end
end
