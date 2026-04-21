# frozen_string_literal: true

require "securerandom"
require "json"
require "cgi"
require "tty-prompt"
require "set"
require_relative "utils/arguments_parser"
require_relative "utils/file_processor"
require_relative "utils/environment_detector"

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
require_relative "agent/skill_evolution"
require_relative "agent/skill_reflector"
require_relative "agent/skill_auto_creator"

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
    include SkillEvolution
    include SkillReflector
    include SkillAutoCreator

    attr_reader :session_id, :name, :history, :iterations, :total_cost, :working_dir, :created_at, :total_tasks, :todos,
                :cache_stats, :cost_source, :ui, :skill_loader, :agent_profile,
                :status, :error, :updated_at, :source
    attr_accessor :pinned

    def permission_mode
      @config&.permission_mode&.to_s || ""
    end

    def initialize(client, config, working_dir:, ui:, profile:, session_id:, source:)
      @client = client  # Client for current model
      @config = config.is_a?(AgentConfig) ? config : AgentConfig.new(config)
      @agent_profile = AgentProfile.load(profile)
      @source = source.to_sym  # :manual | :cron | :channel
      @tool_registry = ToolRegistry.new
      @hooks = HookManager.new
      @session_id = session_id
      @name = ""
      @pinned = false
      @history = MessageHistory.new
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
      @pending_injections = []     # Pending inline skill injections to flush after observe()
      @pending_script_tmpdirs = [] # Decrypted-script tmpdirs to shred when agent.run completes
      @pending_error_rollback = false  # Deferred rollback flag set by restore_session on error

      # Compression tracking
      @compression_level = 0  # Tracks how many times we've compressed (for progressive summarization)
      @compressed_summaries = []  # Store summaries from previous compressions for reference

      # Message compressor for LLM-based intelligent compression
      # Uses LLM to preserve key decisions, errors, and context while reducing token count
      @message_compressor = MessageCompressor.new(@client, model: current_model)

      # Load brand config — used for brand skill decryption and background sync
      @brand_config = Clacky::BrandConfig.load

      # Skill loader for skill management (brand_config enables encrypted skill loading)
      @skill_loader = SkillLoader.new(working_dir: @working_dir, brand_config: @brand_config)

      # Background sync: compare remote skill versions and download updates quietly.
      # Runs in a daemon thread so Agent startup is never blocked.
      @brand_config.sync_brand_skills_async!

      # Initialize Time Machine
      init_time_machine

      # Register built-in tools
      register_builtin_tools

      # Ensure user-space parsers are in place (~/.clacky/parsers/)
      Utils::ParserManager.setup!

      # Ensure bundled shell scripts are in place (~/.clacky/scripts/)
      Utils::ScriptsManager.setup!
    end

    # Restore from a saved session
    def self.from_session(client, config, session_data, ui: nil, profile:)
      working_dir = session_data[:working_dir] || session_data["working_dir"] || Dir.pwd
      original_id = session_data[:session_id] || session_data["session_id"] || Clacky::SessionManager.generate_id
      # Restore source from persisted data; fall back to :manual for legacy sessions
      source = (session_data[:source] || session_data["source"] || "manual").to_sym
      agent = new(client, config, working_dir: working_dir, ui: ui, profile: profile,
                  session_id: original_id, source: source)
      agent.restore_session(session_data)
      agent
    end

    def add_hook(event, &block)
      @hooks.add(event, &block)
    end

    # Switch to a different model by index
    # @param index [Integer] Model index (0-based)
    # @return [Boolean] true if switched successfully, false otherwise
    def switch_model(index)
      # Switch config to the model by index
      return false unless @config.switch_model(index)
      
      # Re-create client for new model
      @client = Clacky::Client.new(
        @config.api_key,
        base_url: @config.base_url,
        model: @config.model_name,
        anthropic_format: @config.anthropic_format?
      )
      # Update message compressor with new client and model
      @message_compressor = MessageCompressor.new(@client, model: current_model)
      
      # Inject a new session context to notify the AI of the model switch
      inject_session_context
      
      true
    end

    # Change the working directory for this session
    # Injects a new session context to notify the AI of the directory change
    def change_working_dir(new_dir)
      @working_dir = new_dir
      inject_session_context
      true
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

    # Get current model name (respects any active fallback override)
    private def current_model
      @config.effective_model_name
    end

    # Rename this session. Called by auto-naming (first message) or user explicit rename.
    def rename(new_name)
      @name = new_name.to_s.strip
    end

    def run(user_input, files: [])
      # Start new task for Time Machine
      task_id = start_new_task

      @start_time = Time.now
      @task_truncation_count = 0  # Reset truncation counter for each task
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

      # Deferred error rollback: if the previous session ended with an error,
      # trim history back to just before that failed user message now — at the
      # point the user actually sends a new message, not at restore time.
      # (Trimming at restore time caused replay_history to return empty results.)
      if @pending_error_rollback
        @pending_error_rollback = false
        last_user_index = @history.last_real_user_index
        if last_user_index
          @history.truncate_from(last_user_index)
          @hooks.trigger(:session_rollback, {
            reason: "Previous session ended with error — rolling back before new message",
            rolled_back_message_index: last_user_index
          })
        end
      end

      # Add system prompt as the first message if this is the first run
      if @history.empty?
        system_prompt = build_system_prompt
        @history.append({ role: "system", content: system_prompt })
      end

      # Inject session context (date + model) if not yet present or date has changed
      inject_session_context_if_needed

      # Inject chunk index card if archived chunks exist and index is stale
      inject_chunk_index_if_needed

      # Split files into vision images and disk files; downgrade oversized images to disk
      image_files, disk_files = partition_files(Array(files))
      vision_images, downgraded = resolve_vision_images(image_files)
      all_disk_files = disk_files + downgraded

      # Format user message — text + inline vision images
      # Store the tmp path alongside the data_url so the history replay can
      # reconstruct the image if the base64 was stripped (e.g. after compression).
      user_content = format_user_content(user_input, vision_images.map { |v| { url: v[:url], path: v[:path] } })

      # Parse disk files — agent's responsibility, not the upload layer.
      # process_path runs the parser script and returns a FileRef with preview_path or parse_error.
      all_disk_files = all_disk_files.map do |f|
        path = f[:path] || f["path"]
        name = f[:name] || f["name"]
        next f unless path && File.exist?(path.to_s)
        ref = Utils::FileProcessor.process_path(path, name: name)
        { name: ref.name, type: ref.type.to_s, path: ref.original_path,
          preview_path: ref.preview_path, parse_error: ref.parse_error, parser_path: ref.parser_path }
      end

      # Build display_files for replay: lightweight metadata so the UI can reconstruct
      # file badges (PDF, doc, etc.) on page refresh. Images are NOT stored here — they
      # are recovered from the image_url blocks in user_content by extract_image_files_from_content.
      display_files = all_disk_files.filter_map do |f|
        name = f[:name] || f["name"]
        next unless name
        { name: name, type: f[:type] || f["type"] || "file",
          preview_path: f[:preview_path] || f["preview_path"] }
      end

      @history.append({ role: "user", content: user_content, task_id: task_id, created_at: Time.now.to_f,
                        display_files: display_files.empty? ? nil : display_files })
      @total_tasks += 1

      # Inject disk file references as a system_injected message so:
      #   - LLM sees the file info (system_injected is NOT stripped from to_api)
      #   - replay_history skips it (next if ev[:system_injected]), keeping the user bubble clean
      #
      # Images: also injected here (alongside vision inline) so LLM knows filename + size.
      all_meta_files = vision_images.map { |v|
        { name: v[:name], type: "image", size_bytes: v[:size_bytes], path: v[:path] }
      } + all_disk_files

      unless all_meta_files.empty?
        file_prompt = all_meta_files.filter_map do |f|
          name         = f[:name]         || f["name"]
          type         = f[:type]         || f["type"]
          path         = f[:path]         || f["path"]
          preview_path = f[:preview_path] || f["preview_path"]
          size_bytes   = f[:size_bytes]   || f["size_bytes"]
          parse_error  = f[:parse_error]  || f["parse_error"]
          parser_path  = f[:parser_path]  || f["parser_path"]

          next unless name

          lines = ["[File: #{name}]", "Type: #{type || "file"}"]
          lines << "Size: #{format_size(size_bytes)}" if size_bytes
          lines << "Original: #{path}" if path
          lines << "Preview (Markdown): #{preview_path}" if preview_path

          # Parser failed — instruct LLM to fix and re-run
          if preview_path.nil? && parse_error
            lines << "Parse failed: #{parse_error}"
            if parser_path
              expected_preview = "#{path}.preview.md"
              lines << "Action required: fix the parser at #{parser_path}, then run:"
              lines << "  ruby #{parser_path} #{path} > #{expected_preview}"
              lines << "Once done, read #{expected_preview} to continue helping the user."
            end
          end

          lines.join("\n")
        end.join("\n\n")

        unless file_prompt.empty?
          @history.append({ role: "user", content: file_prompt, system_injected: true, task_id: task_id })
        end
      end

      # If the user typed a slash command targeting a skill with disable-model-invocation: true,
      # inject the skill content as a synthetic assistant message so the LLM can act on it.
      # Skills already in the system prompt (model_invocation_allowed?) are skipped.
      inject_skill_command_as_assistant_message(user_input, task_id)

      @hooks.trigger(:on_start, user_input)

      begin
        # Track if request_user_feedback was called
        awaiting_user_feedback = false
        # Track if task was interrupted by user (denied tool execution)
        task_interrupted = false

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
            # During memory update phase, show LLM response as info (not a chat bubble)
            if @memory_updating && response[:content] && !response[:content].empty?
              @ui&.show_info(response[:content].strip)
            elsif response[:content] && !response[:content].empty?
              emit_assistant_message(response[:content])
            end

            # Show token usage after the assistant message so WebUI renders it below the bubble
            @ui&.show_token_usage(response[:token_usage]) if response[:token_usage]

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
          # During memory update phase, suppress text output (only tool calls matter)
          if response[:content] && !response[:content].empty? && !@memory_updating
            emit_assistant_message(response[:content])
          end

          # Show token usage after assistant message (or immediately if no message).
          # This ensures WebUI renders the token line below the assistant bubble.
          @ui&.show_token_usage(response[:token_usage]) if response[:token_usage]

          # Act: Execute tool calls
          action_result = act(response[:tool_calls])

          # Check if request_user_feedback was called
          if action_result[:awaiting_feedback]
            awaiting_user_feedback = true
            observe(response, action_result[:tool_results])
            flush_pending_injections
            break
          end

          # Observe: Add tool results to conversation context
          observe(response, action_result[:tool_results])

          # Flush any inline skill injections enqueued by invoke_skill during act().
          # Must happen AFTER observe() so toolResult is appended before skill instructions,
          # producing a legal message sequence for all API providers (especially Bedrock).
          flush_pending_injections

          # Check if user denied any tool
          if action_result[:denied]
            task_interrupted = true
            # If user provided feedback, treat it as a user question/instruction
            if action_result[:feedback] && !action_result[:feedback].empty?
              # Add user feedback as a new user message with system_injected marker
              @history.append({
                role: "user",
                content: "The user has a question/feedback for you: #{action_result[:feedback]}\n\nPlease respond to the user's question/feedback before continuing with any actions.",
                system_injected: true
              })
              # Continue loop to let agent respond to feedback
              next
            else
              # User just said "no" without feedback - stop and wait
              @ui&.show_assistant_message("Tool execution was denied. Please give more instructions...", files: [])
              break
            end
          end
        end

      result = build_result

      # Save snapshots of modified files for Time Machine
      if @modified_files_in_task && !@modified_files_in_task.empty?
        save_modified_files_snapshot(@modified_files_in_task)
        @modified_files_in_task = []  # Reset for next task
      end

        # Run skill evolution hooks after main loop completes
        # Skip if task was interrupted by user (denied tool) or awaiting user feedback
        # Only for main agent (not subagents) to avoid recursive evolution
        unless @is_subagent || task_interrupted || awaiting_user_feedback
          run_skill_evolution_hooks
        end

        if @is_subagent
          # Parent agent (skill_manager) prints the completion summary; skip here.
        else
          @ui&.show_complete(
            iterations: result[:iterations],
            cost: result[:total_cost_usd],
            duration: result[:duration_seconds],
            cache_stats: result[:cache_stats],
            awaiting_user_feedback: awaiting_user_feedback
          )
        end
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

        # 400 errors mean our request was malformed — roll back history so the bad
        # message is not replayed on the next user turn.
        # Other errors (auth, network, etc.) leave history intact for retry.
        @pending_error_rollback = true if e.is_a?(Clacky::BadRequestError)

        # Build error result for session data, but let CLI handle error display
        result = build_result(:error, error: e.message)  # rubocop:disable Lint/UselessAssignment
        raise
      ensure
        # Always clean up memory update messages, even if interrupted or error occurred
        cleanup_memory_messages

        # Shred any decrypted-script tmpdirs created during this run for encrypted brand skills.
        # This covers the inline-injection path; the subagent path shreds immediately after
        # subagent.run returns (see execute_skill_with_subagent).
        shred_script_tmpdirs
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
        @history.append(compression_message)
        compression_handled = false
        begin
          response = call_llm
          handle_compression_response(response, compression_context)
          compression_handled = true
        ensure
          # If interrupted or failed, roll back the speculative compression message
          # so it doesn't pollute future conversation turns.
          unless compression_handled
            @history.rollback_before(compression_message)
            # Also restore compression_level since compress_messages_if_needed already incremented it.
            # Failure to do so would cause the next call to start at level 2 instead of 1,
            # and more importantly would re-trigger compression on the very next think() call
            # (with the user's new message as the last entry), producing consecutive user messages
            # that confuse the LLM into echoing compression instructions.
            @compression_level -= 1
          end
        end
        return nil
      end

      # Normal LLM call
      response = call_llm

      # Handle truncated responses (when max_tokens limit is reached)
      if response[:finish_reason] == "length"
        # Count recent truncations to prevent infinite loops
        @task_truncation_count = (@task_truncation_count || 0) + 1

        if @task_truncation_count >= 3
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
          @history.append({
            role: "assistant",
            content: error_response[:content]
          })

          return error_response
        end

        # Preserve the truncated assistant message (text only, drop incomplete tool_calls)
        # so the LLM sees what it attempted before. This also maintains the required
        # user/assistant alternation for Bedrock Converse API.
        truncated_text = response[:content] || ""
        truncated_text = "..." if truncated_text.strip.empty?
        @history.append({
          role: "assistant",
          content: truncated_text,
          task_id: @current_task_id
        })

        # Insert system message to guide LLM to retry with smaller steps
        @history.append({
          role: "user",
          content: "[SYSTEM] Your previous response was truncated because it exceeded the output token limit (max_tokens=#{@config.max_tokens}). " \
                   "The incomplete tool call has been discarded. Please retry with a different approach:\n" \
                   "- For long file content: create the file with a basic structure first, then use edit() to add content section by section\n" \
                   "- Break down large tasks into multiple smaller tool calls\n" \
                   "- Keep each tool call argument under 2000 characters\n" \
                   "- Use multiple tool calls instead of one large call",
          truncated: true
        })

        @ui&.show_warning("Response truncated (#{@task_truncation_count}/3). Retrying with smaller steps...")

        # Recursively retry
        return think
      end

      # Add assistant response to history
      msg = { role: "assistant", task_id: @current_task_id }
      # Always include content field (some APIs require it even with tool_calls)
      # Use empty string instead of null for better compatibility
      msg[:content] = response[:content] || ""
      # Only add tool_calls if they actually exist (don't add empty arrays)
      if response[:tool_calls]&.any?
        msg[:tool_calls] = format_tool_calls_for_api(response[:tool_calls])
      end
      # Store token_usage in the message so replay_history can re-emit it
      msg[:token_usage] = response[:token_usage] if response[:token_usage]
      # Preserve reasoning_content so it is echoed back to APIs that require it
      # (e.g. Kimi/Moonshot extended thinking — omitting it causes HTTP 400)
      msg[:reasoning_content] = response[:reasoning_content] if response[:reasoning_content]
      @history.append(msg)

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
          @ui&.show_tool_call(call[:name], redact_tool_args(call[:arguments]))
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

          if @ui
            progress_message = build_tool_progress_message(call[:name], args)

            # For shell/safe_shell: inject on_output callback for real-time stdout streaming.
            # The callback fires immediately on each read_nonblock chunk — no polling delay.
            if (call[:name] == "shell" || call[:name] == "safe_shell") &&
               @ui.respond_to?(:show_tool_stdout)
              args[:on_output] = ->(stream, data) {
                @ui.show_tool_stdout([data]) if stream == :stdout
              }
            end

            progress_timer = Thread.new do
              sleep 2
              @ui.show_progress(progress_message, prefix_newline: false)
              progress_shown = true
              # Streaming is handled by on_output callback — no polling loop needed here
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
            @ui&.show_progress(phase: "done") if progress_shown
          end

          # Track modified files for Time Machine snapshots
          track_modified_files(call[:name], args)

          # Hook: after_tool_use
          @hooks.trigger(:after_tool_use, call, result)

          # Update todos display after todo_manager execution
          if call[:name] == "todo_manager"
            @ui&.update_todos(@todos.dup)
          end

          # Special handling for request_user_feedback: emit as interactive feedback card
          if call[:name] == "request_user_feedback"
            # Pass the raw call arguments to show_tool_call so the WebUI controller
            # can extract question/context/options and emit a "request_feedback" event
            # (renders as a clickable card in the browser).
            # Fallback UIs (terminal, IM channels) receive the formatted text message.
            @ui&.show_tool_call(call[:name], call[:arguments])

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
      formatted_messages.each { |msg| @history.append(msg.merge(task_id: @current_task_id)) }
    end

    # Interrupt the agent's current run
    # Called when user presses Ctrl+C during agent execution
    def interrupt!
      @interrupted = true
    end

    # Enqueue an inline skill injection to be flushed after observe().
    # Called by InvokeSkill#execute to avoid injecting during tool execution,
    # which would break Bedrock's toolUse/toolResult pairing requirement.
    # @param skill [Clacky::Skill] The skill whose instructions should be injected
    # @param task [String] The task description passed to the skill
    def enqueue_injection(skill, task)
      @pending_injections << { skill: skill, task: task }
    end

    # Register a tmpdir that contains decrypted brand skill scripts.
    # SkillManager calls this after decrypt_all_scripts so agent.run's ensure block
    # can shred it when the run completes.
    # @param dir [String] Absolute path to the tmpdir
    def register_script_tmpdir(dir)
      @pending_script_tmpdirs << dir
    end

    # Redact volatile tmpdir paths from tool call arguments before showing in UI.
    # Replaces each registered path with <SKILL_DIR> so encrypted skill locations
    # are never exposed to the user.
    # @param args [String, Hash, nil] Raw tool arguments
    # @return [String, Hash, nil] Redacted arguments (same type as input)
    def redact_tool_args(args)
      return args if @pending_script_tmpdirs.empty?

      redact_value(args)
    end

    def redact_value(obj)
      case obj
      when String
        @pending_script_tmpdirs.map(&:to_s).sort_by { |p| -p.length }.reduce(obj) { |s, path| s.gsub(path, "<SKILL_DIR>") }
      when Hash
        obj.transform_values { |v| redact_value(v) }
      when Array
        obj.map { |v| redact_value(v) }
      else
        obj
      end
    end

    # Flush all pending inline skill injections into history.
    # Must be called AFTER observe() so toolResult is appended before skill instructions,
    # producing the correct message sequence for all API providers (especially Bedrock).
    private def flush_pending_injections
      return if @pending_injections.empty?

      @pending_injections.each do |entry|
        inject_skill_as_assistant_message(entry[:skill], entry[:task], @current_task_id)
      end
      @pending_injections.clear
    end

    # Shred all decrypted-script tmpdirs registered during this run.
    # Called from agent.run's ensure block to guarantee cleanup even on error/interrupt.
    # Overwrites each file with zeros before unlinking to hinder recovery.
    # Delegates to SkillManager#shred_directory (available via include SkillManager).
    private def shred_script_tmpdirs
      return if @pending_script_tmpdirs.empty?

      @pending_script_tmpdirs.each { |dir| shred_directory(dir) }
      @pending_script_tmpdirs.clear
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

    private def build_result(status = :success, error: nil)
      task_iterations = @iterations - (@task_start_iterations || 0)
      task_cost = @total_cost - (@task_start_cost || 0)

      {
        status: status,
        session_id: @session_id,
        iterations: task_iterations,
        duration_seconds: Time.now - @start_time,
        total_cost_usd: task_cost.round(4),
        cost_source: @task_cost_source,
        cache_stats: @task_cache_stats || @cache_stats,
        history: @history,
        error: error
      }
    end

    private def format_tool_calls_for_api(tool_calls)
      return nil unless tool_calls

      valid = tool_calls.filter_map do |call|
        func = call[:function] || call
        name = func[:name] || call[:name]
        arguments = func[:arguments] || call[:arguments]
        # Skip malformed tool calls with nil name or arguments
        next if name.nil? || arguments.nil?

        {
          id: call[:id],
          type: call[:type] || "function",
          function: {
            name: name,
            arguments: arguments
          }
        }
      end

      valid.any? ? valid : nil
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
      # @tool_registry.register(Tools::RunProject.new) # temporarily disabled
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
      subagent_config = @config.deep_copy

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
        model: subagent_config.model_name,
        anthropic_format: subagent_config.anthropic_format?
      )

      # Create subagent (reuses all tools from parent, inherits agent profile from parent)
      # Subagent gets its own unique session_id.
      subagent = self.class.new(
        subagent_client,
        subagent_config,
        working_dir: @working_dir,
        ui: @ui,
        profile: @agent_profile.name,
        session_id: Clacky::SessionManager.generate_id,
        source: @source
      )
      subagent.instance_variable_set(:@is_subagent, true)

      # Inherit previous_total_tokens so the first iteration delta is calculated correctly
      subagent.instance_variable_set(:@previous_total_tokens, @previous_total_tokens)

      # Deep clone history to avoid cross-contamination.
      # Dangling tool_calls (no tool_result yet) are cleaned up automatically by
      # MessageHistory#append when the subagent appends its first user message.
      cloned_messages = deep_clone(@history.to_a)
      subagent.instance_variable_set(:@history, MessageHistory.new(cloned_messages))

      # Append system prompt suffix as user message (for cache reuse)
      if system_prompt_suffix
        subagent_history = subagent.history

        # Build forbidden tools notice if any tools are forbidden
        forbidden_notice = if forbidden_tools.any?
          tool_list = forbidden_tools.map { |t| "`#{t}`" }.join(", ")
          "\n\n[System Notice] The following tools are disabled in this subagent and will be rejected if called: #{tool_list}"
        else
          ""
        end

        subagent_history.append({
          role: "user",
          content: "CRITICAL: TASK CONTEXT SWITCH - FORKED SUBAGENT MODE\n\nYou are now running as a forked subagent — a temporary, isolated agent spawned by the parent agent to handle a specific task. You run independently and cannot communicate back to the parent mid-task. When you finish (i.e., you stop calling tools and return a final response), your output will be automatically summarized and returned to the parent agent as a result so it can continue.\n\n#{system_prompt_suffix}#{forbidden_notice}",
          system_injected: true,
          subagent_instructions: true
        })

        # Insert an assistant acknowledgement so the conversation structure is complete:
        #   [user] role/constraints  →  [assistant] ack  →  [user] actual task (from run())
        subagent_history.append({
          role: "assistant",
          content: "Understood. I am now operating as a subagent with the constraints above. Please provide the task.",
          system_injected: true
        })
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
      subagent.instance_variable_set(:@parent_message_count, @history.size)

      subagent
    end

    # Generate summary from subagent execution
    # Extracts new messages added by subagent and creates a concise summary
    # This summary will replace the subagent instructions message in parent agent
    # @param subagent [Agent] The subagent that completed execution
    # @return [String] Summary text to insert into parent agent
    def generate_subagent_summary(subagent)
      parent_count = subagent.instance_variable_get(:@parent_message_count) || 0
      new_messages = subagent.history.to_a[parent_count..] || []

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
    # PDF files are handled upstream (server injects file path into message text),
    # so this method only needs to handle images.
    # @param text [String] User's text input
    # @param images [Array<String>] Array of image file paths or data: URLs
    # @param files [Array] Unused — kept for signature compatibility
    # @return [String|Array] String if no images, Array with content blocks otherwise
    # Partition files array into [image_files, non_image_files].
    # Image files: have mime_type starting with "image/" OR have data_url present.
    private def partition_files(files)
      image_files = []
      non_image_files = []
      files.each do |f|
        mime = f[:mime_type] || f["mime_type"] || ""
        data_url = f[:data_url] || f["data_url"]
        if mime.start_with?("image/") || data_url
          image_files << f
        else
          non_image_files << f
        end
      end
      [image_files, non_image_files]
    end

    # Resolve image files to vision data_urls.
    # Files with data_url: use as-is (already compressed by frontend or adapter).
    # Files with path: convert to data_url via FileProcessor.
    # Oversized images (> MAX_IMAGE_BYTES) are downgraded to disk file refs.
    # @return [Array<String>, Array<Hash>] [vision_urls, downgraded_disk_files]
    private def resolve_vision_images(image_files)
      require "base64"
      max_bytes = Utils::FileProcessor::MAX_IMAGE_BYTES
      vision_images = []  # Array of { url:, name:, size_bytes: }
      downgraded    = []

      image_files.each do |f|
        name     = f[:name]     || f["name"]     || "image.jpg"
        mime     = f[:mime_type] || f["mime_type"] || "image/jpeg"
        data_url = f[:data_url]  || f["data_url"]
        path     = f[:path]      || f["path"]

        if data_url
          b64_data  = data_url.split(",", 2).last.to_s
          byte_size = (b64_data.bytesize * 3) / 4
          raw       = Base64.decode64(b64_data)
          file_ref  = Utils::FileProcessor.save_image_to_disk(body: raw, mime_type: mime, filename: name)
          if byte_size > max_bytes
            downgraded << { name: name, path: file_ref.original_path, type: "image", mime_type: mime, size_bytes: byte_size }
          else
            vision_images << { url: data_url, name: name, size_bytes: byte_size, path: file_ref.original_path }
          end
        elsif path
          begin
            data_url_from_path = Utils::FileProcessor.image_path_to_data_url(path)
            b64_data  = data_url_from_path.split(",", 2).last.to_s
            byte_size = (b64_data.bytesize * 3) / 4
            if byte_size > max_bytes
              downgraded << { name: name, path: path, type: "image", mime_type: mime, size_bytes: byte_size }
            else
              vision_images << { url: data_url_from_path, name: name, size_bytes: byte_size, path: path }
            end
          rescue => e
            @ui&.log("Failed to load image #{name}: #{e.message}", level: :warn)
          end
        end
      end

      [vision_images, downgraded]
    end

    # Build user message content for LLM.
    # Returns plain String when no vision images; Array of content parts otherwise.
    # Build user message content for LLM.
    # vision_images: Array of String (plain url) OR Hash { url:, path: }
    # path is stored in the block so history replay can reconstruct the image
    # from the tmp file when the base64 data_url is no longer available.
    private def format_user_content(text, vision_images)
      vision_images ||= []

      return text if vision_images.empty?

      content = []
      content << { type: "text", text: text } unless text.nil? || text.empty?
      vision_images.each do |img|
        if img.is_a?(Hash)
          block = { type: "image_url", image_url: { url: img[:url] } }
          block[:image_path] = img[:path] if img[:path]
          content << block
        else
          content << { type: "image_url", image_url: { url: img } }
        end
      end
      content
    end

    # Format byte size as human-readable string.
    private def format_size(bytes)
      return "0B" unless bytes
      if bytes >= 1024 * 1024
        "#{(bytes / 1024.0 / 1024.0).round(1)}MB"
      elsif bytes >= 1024
        "#{(bytes / 1024.0).round(0).to_i}KB"
      else
        "#{bytes}B"
      end
    end

    # Inject a session context message (date + model) into the conversation.
    # Only injects when:
    #   1. No context message exists yet in this session, OR
    #   2. The existing context is from a previous day (cross-day session)
    # Marked with system_injected: true so existing filters (replay_history,
    # get_recent_user_messages, etc.) automatically skip it.
    # Cache-safe: always inserted just before the current user message,
    # so no historical cache entries are ever invalidated.
    private def inject_session_context_if_needed
      today = Time.now.strftime("%Y-%m-%d")

      # Skip if we already have a context for today
      return if @history.last_session_context_date == today

      inject_session_context
    end

    # Core method to inject session context (date, model, OS, paths).
    # Called by inject_session_context_if_needed (with date check)
    # and by switch_model (without date check, to force update).
    private def inject_session_context
      today   = Time.now.strftime("%Y-%m-%d")
      os      = Clacky::Utils::EnvironmentDetector.os_type
      desktop = Clacky::Utils::EnvironmentDetector.desktop_path
      parts   = [
        "Today is #{Time.now.strftime('%Y-%m-%d, %A')}",
        "Current model: #{current_model}",
        os != :unknown ? "OS: #{Clacky::Utils::EnvironmentDetector.os_label}" : nil,
        desktop ? "Desktop: #{desktop}" : nil,
        "Working directory: #{@working_dir}"
      ].compact.join(". ")

      content = "[Session context: #{parts}]"
      @history.append({
        role: "user",
        content: content,
        system_injected: true,
        session_context: true,
        session_date: today
      })
    end

    # Parse markdown file:// links from assistant message content.
    # Handles both regular links and inline images:
    #   [Download report](file:///path/to/file.pdf)
    #   ![chart](file:///path/to/chart.png)
    #
    # Returns { text: String, files: Array<{name:, path:, inline:}> }
    # File links are stripped from the returned text.
    private def parse_file_links(content)
      return { text: content, files: [] } if content.nil? || content.empty?

      files = []
      text = content.gsub(/(!?)\[([^\]]*)\]\(file:\/\/([^)]+)\)/) do
        inline = $1 == "!"
        # URL-decode percent-encoded characters (e.g. Chinese filenames encoded by AI)
        raw_path = CGI.unescape($3)
        name   = $2.empty? ? File.basename(raw_path) : $2
        path   = File.expand_path(raw_path)
        Clacky::Logger.info("[parse_file_links] raw=#{$3.inspect} expanded=#{path.inspect} exist=#{File.exist?(path)}")
        files << { name: name, path: path, inline: inline }
        ""
      end
      { text: text.strip, files: files }
    end

    # Emit assistant message to UI, parsing any embedded file:// links first.
    private def emit_assistant_message(content)
      return if content.nil? || content.empty?

      parsed = parse_file_links(content)
      @ui&.show_assistant_message(parsed[:text], files: parsed[:files])
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
