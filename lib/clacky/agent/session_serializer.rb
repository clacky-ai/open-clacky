# frozen_string_literal: true

module Clacky
  class Agent
    # Session serialization for saving and restoring agent state
    # Handles session data serialization and deserialization
    module SessionSerializer
      # Restore from a saved session
      # @param session_data [Hash] Saved session data
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

        # Restore Time Machine state
        @task_parents = session_data.dig(:time_machine, :task_parents) || {}
        @current_task_id = session_data.dig(:time_machine, :current_task_id) || 0
        @active_task_id = session_data.dig(:time_machine, :active_task_id) || 0

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

        # Rebuild and refresh the system prompt so any newly installed skills
        # (or other configuration changes since the session was saved) are
        # reflected immediately — without requiring the user to create a new session.
        refresh_system_prompt
      end

      # Generate session data for saving
      # @param status [Symbol] Status of the last task: :success, :error, or :interrupted
      # @param error_message [String] Error message if status is :error
      # @return [Hash] Session data ready for serialization
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
          time_machine: {  # Include Time Machine state
            task_parents: @task_parents || {},
            current_task_id: @current_task_id || 0,
            active_task_id: @active_task_id || 0
          },
          config: {
            models: @config.models,
            permission_mode: @config.permission_mode.to_s,
            enable_compression: @config.enable_compression,
            enable_prompt_caching: @config.enable_prompt_caching,
            max_tokens: @config.max_tokens,
            verbose: @config.verbose
          },
          stats: stats_data,
          messages: @messages,
          last_user_message: last_message_preview
        }
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

      # Replay conversation history by calling ui.show_* methods for each message.
      # Supports cursor-based pagination using created_at timestamps on user messages.
      # Each "round" starts at a user message and includes all subsequent assistant/tool messages.
      #
      # @param ui [Object] UI interface that responds to show_user_message, show_assistant_message, etc.
      # @param limit [Integer] Maximum number of rounds (user turns) to replay
      # @param before [Float, nil] Unix timestamp cursor — only replay rounds where the user message
      #   created_at < before. Pass nil to get the most recent rounds.
      # @return [Hash] { has_more: Boolean } — whether older rounds exist beyond this page
      def replay_history(ui, limit: 20, before: nil)
        # Split @messages into rounds, each starting at a real user message
        rounds = []
        current_round = nil

        @messages.each do |msg|
          role = msg[:role].to_s

          # A real user message can have either a String content or an Array content
          # (Array = multipart: text + image blocks). Exclude system-injected messages
          # and synthetic [SYSTEM] text messages.
          is_real_user_msg = role == "user" && !msg[:system_injected] &&
            if msg[:content].is_a?(String)
              !msg[:content].start_with?("[SYSTEM]")
            elsif msg[:content].is_a?(Array)
              # Must contain at least one text or image block (not a tool_result array)
              msg[:content].any? { |b| b.is_a?(Hash) && %w[text image].include?(b[:type].to_s) }
            else
              false
            end

          if is_real_user_msg
            # Start a new round at each real user message
            current_round = { user_msg: msg, events: [] }
            rounds << current_round
          elsif current_round
            current_round[:events] << msg
          end
        end

        # Apply before-cursor filter: only rounds whose user message created_at < before
        if before
          rounds = rounds.select { |r| r[:user_msg][:created_at] && r[:user_msg][:created_at] < before }
        end

        has_more = rounds.size > limit
        # Take the most recent `limit` rounds
        page = rounds.last(limit)

        page.each do |round|
          msg = round[:user_msg]
          display_text = extract_text_from_content(msg[:content])
          # Extract image data URLs from multipart content (for history replay rendering)
          images = extract_images_from_content(msg[:content])
          # Emit user message with its timestamp for dedup on the frontend
          ui.show_user_message(display_text, created_at: msg[:created_at], images: images)

          round[:events].each do |ev|
            # Skip system-injected messages (e.g. synthetic skill content, memory prompts)
            # — they are internal scaffolding and must not be shown to the user.
            next if ev[:system_injected]

            case ev[:role].to_s
            when "assistant"
              # Text content
              text = extract_text_from_content(ev[:content]).to_s.strip
              ui.show_assistant_message(text) unless text.empty?

              # Tool calls embedded in assistant message
              Array(ev[:tool_calls]).each do |tc|
                name     = tc[:name] || tc.dig(:function, :name) || ""
                args_raw = tc[:arguments] || tc.dig(:function, :arguments) || {}
                args     = args_raw.is_a?(String) ? (JSON.parse(args_raw) rescue args_raw) : args_raw
                ui.show_tool_call(name, args)
              end

            when "user"
              # Anthropic-format tool results (role: user, content: array of tool_result blocks)
              next unless ev[:content].is_a?(Array)

              ev[:content].each do |blk|
                next unless blk.is_a?(Hash) && blk[:type] == "tool_result"

                ui.show_tool_result(blk[:content].to_s)
              end

            when "tool"
              # OpenAI-format tool result
              ui.show_tool_result(ev[:content].to_s)
            end
          end
        end

        { has_more: has_more }
      end

      private

      # Replace the system message in @messages with a freshly built system prompt.
      # Called after restore_session so newly installed skills and any other
      # configuration changes since the session was saved take effect immediately.
      # If no system message exists yet (shouldn't happen in practice), a new one
      # is prepended so the conversation stays well-formed.
      def refresh_system_prompt
        # Reload skills from disk to pick up anything installed since the session was saved
        @skill_loader.load_all

        fresh_prompt = build_system_prompt
        system_index = @messages.index { |m| m[:role] == "system" }

        if system_index
          @messages[system_index] = { role: "system", content: fresh_prompt }
        else
          @messages.unshift({ role: "system", content: fresh_prompt })
        end
      rescue StandardError => e
        # Log and continue — a stale system prompt is better than a broken restore
        Clacky::Logger.warn("refresh_system_prompt failed during session restore: #{e.message}")
      end

      # Extract base64 data URLs from multipart content (image blocks).
      # Returns an empty array when there are no images or content is plain text.
      # @param content [String, Array, Object] Message content
      # @return [Array<String>] Array of data URLs (e.g. "data:image/png;base64,...")
      def extract_images_from_content(content)
        return [] unless content.is_a?(Array)

        content.filter_map do |block|
          next unless block.is_a?(Hash)

          case block[:type].to_s
          when "image_url"
            # OpenAI format: { type: "image_url", image_url: { url: "data:image/png;base64,..." } }
            block.dig(:image_url, :url)
          when "image"
            # Anthropic format: { type: "image", source: { type: "base64", media_type: "image/png", data: "..." } }
            source = block[:source]
            next unless source.is_a?(Hash) && source[:type].to_s == "base64"

            "data:#{source[:media_type]};base64,#{source[:data]}"
          end
        end
      end

      # Extract text from message content (handles string and array formats)
      # @param content [String, Array, Object] Message content
      # @return [String] Extracted text
      def extract_text_from_content(content)
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
    end
  end
end
