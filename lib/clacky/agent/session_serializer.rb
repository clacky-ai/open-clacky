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
        @name = session_data[:name] || ""
        @pinned = session_data[:pinned] || false
        @history = MessageHistory.new(session_data[:messages] || [])
        @todos = session_data[:todos] || []  # Restore todos from session
        @iterations = session_data.dig(:stats, :total_iterations) || 0
        @total_cost = session_data.dig(:stats, :total_cost_usd) || 0.0
        @working_dir = session_data[:working_dir]
        @created_at = session_data[:created_at]
        @total_tasks = session_data.dig(:stats, :total_tasks) || 0
        # Restore source; fall back to :manual for sessions saved before this field existed
        @source = (session_data[:source] || "manual").to_sym

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

        # Check if the session ended with an error.
        # We record the rollback intent here but do NOT truncate history immediately —
        # truncating at restore time causes the history replay to return empty results,
        # leaving the chat panel blank on first open.
        # Instead, the rollback is deferred: history is trimmed lazily when the user
        # actually sends the next message (see run() / handle_user_message).
        last_status = session_data.dig(:stats, :last_status)
        last_error = session_data.dig(:stats, :last_error)

        if last_status == "error" && last_error
          @pending_error_rollback = true
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
          name: @name,
          pinned: @pinned,
          created_at: @created_at,
          updated_at: Time.now.iso8601,
          working_dir: @working_dir,
          source: @source.to_s,                      # "manual" | "cron" | "channel" | "setup"
          agent_profile: @agent_profile&.name || "", # "general" | "coding" | custom
          todos: @todos,  # Include todos in session data
          time_machine: {  # Include Time Machine state
            task_parents: @task_parents || {},
            current_task_id: @current_task_id || 0,
            active_task_id: @active_task_id || 0
          },
          config: {
            # NOTE: api_key and other sensitive credentials are intentionally excluded
            # to prevent leaking secrets into session files on disk.
            permission_mode: @config.permission_mode.to_s,
            enable_compression: @config.enable_compression,
            enable_prompt_caching: @config.enable_prompt_caching,
            max_tokens: @config.max_tokens,
            verbose: @config.verbose
          },
          stats: stats_data,
          messages: @history.to_a
        }
      end

      # Get recent user messages from conversation history
      # @param limit [Integer] Number of recent user messages to retrieve (default: 5)
      # @return [Array<String>] Array of recent user message contents
      def get_recent_user_messages(limit: 5)
        @history.real_user_messages.last(limit).map do |msg|
          extract_text_from_content(msg[:content])
        end
      end

      # Replay conversation history by calling ui.show_* methods for each message.
      # Supports cursor-based pagination using created_at timestamps on user messages.
      # Each "round" starts at a user message and includes all subsequent assistant/tool messages.
      # Compressed chunks (chunk_path on assistant messages) are transparently expanded.
      #
      # @param ui [Object] UI interface that responds to show_user_message, show_assistant_message, etc.
      # @param limit [Integer] Maximum number of rounds (user turns) to replay
      # @param before [Float, nil] Unix timestamp cursor — only replay rounds where the user message
      #   created_at < before. Pass nil to get the most recent rounds.
      # @return [Hash] { has_more: Boolean } — whether older rounds exist beyond this page
      def replay_history(ui, limit: 20, before: nil)
        # Split @history into rounds, each starting at a real user message
        rounds = []
        current_round = nil

        @history.to_a.each do |msg|
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
          elsif msg[:compressed_summary] && msg[:chunk_path]
            # Compressed summary sitting before any user rounds — expand it from chunk md
            chunk_rounds = parse_chunk_md_to_rounds(msg[:chunk_path])
            rounds.concat(chunk_rounds)
            # After expanding, treat the last chunk round as the current round so that
            # any orphaned assistant/tool messages that follow in session.json (belonging
            # to the same task whose user message was compressed into the chunk) get
            # appended here instead of being silently discarded.
            current_round = rounds.last
          elsif rounds.last
            # Orphaned non-user message with no current_round yet (e.g. recent_messages
            # after compression started mid-task with no leading user message).
            # Attach to the last known round rather than drop silently.
            rounds.last[:events] << msg
          end
        end

        # Expand any compressed_summary assistant messages sitting inside a round's events.
        # These occur when compression happened mid-round (rare) — expand them in-place.
        rounds.each do |round|
          round[:events].select! { |ev| !ev[:compressed_summary] }
        end

        # Apply before-cursor filter: only rounds whose user message created_at < before
        if before
          rounds = rounds.select { |r| r[:user_msg][:created_at] && r[:user_msg][:created_at] < before }
        end

        # Fallback: when the conversation was compressed and no user messages remain in the
        # kept slice, render the surviving assistant/tool messages directly so the user can
        # still see the last visible state of the chat (e.g. compressed summary + recent work).
        if rounds.empty?
          visible = @history.to_a.reject { |m| m[:role].to_s == "system" || m[:system_injected] }
          visible.each { |msg| _replay_single_message(msg, ui) }
          return { has_more: false }
        end

        has_more = rounds.size > limit
        # Take the most recent `limit` rounds
        page = rounds.last(limit)

        page.each do |round|
          msg = round[:user_msg]
          raw_text    = extract_text_from_content(msg[:content])
          # Images: recovered from inline image_url blocks in content (carry data_url for <img> rendering)
          image_files = extract_image_files_from_content(msg[:content])
          # Disk files (PDF, doc, etc.): stored in display_files on the user message at send time
          disk_files  = Array(msg[:display_files]).map { |f|
            { name: f[:name] || f["name"], type: f[:type] || f["type"] || "file",
              preview_path: f[:preview_path] || f["preview_path"] }
          }
          all_files = image_files + disk_files
          ui.show_user_message(raw_text, created_at: msg[:created_at], files: all_files)

          round[:events].each do |ev|
            # Skip system-injected messages (e.g. synthetic skill content, memory prompts)
            # — they are internal scaffolding and must not be shown to the user.
            next if ev[:system_injected]

            _replay_single_message(ev, ui)
          end
        end

        { has_more: has_more }
      end

      # Parse a chunk MD file into an array of rounds compatible with replay_history.
      # Each round is { user_msg: Hash, events: Array<Hash> }.
      # Timestamps are synthesised from the chunk's archived_at, spread backwards.
      # Recursively expands nested chunk references (compressed summary inside a chunk).
      #
      # @param chunk_path [String] Path to the chunk md file
      # @return [Array<Hash>] rounds array (may be empty if file missing/unreadable)
      private def parse_chunk_md_to_rounds(chunk_path, visited: Set.new)
        return [] unless chunk_path

        # 1. Try the stored absolute path first (same machine, normal case).
        # 2. If not found, fall back to basename + SESSIONS_DIR (cross-user / cross-machine).
        resolved = chunk_path.to_s
        unless File.exist?(resolved)
          resolved = File.join(Clacky::SessionManager::SESSIONS_DIR, File.basename(resolved))
        end

        return [] unless File.exist?(resolved)

        # Guard against circular chunk references (e.g. chunk-3 → chunk-2 → chunk-1 → chunk-9 → … → chunk-3)
        canonical = File.expand_path(resolved)
        if visited.include?(canonical)
          Clacky::Logger.warn("parse_chunk_md_to_rounds: circular reference detected, skipping #{canonical}")
          return []
        end
        visited = visited.dup.add(canonical)

        raw = File.read(resolved)

        # Parse YAML front matter to get archived_at for synthetic timestamps
        archived_at = nil
        if raw.start_with?("---")
          fm_end = raw.index("\n---\n", 4)
          if fm_end
            fm_text = raw[4...fm_end]
            fm_text.each_line do |line|
              if line.start_with?("archived_at:")
                archived_at = Time.parse(line.split(":", 2).last.strip) rescue nil
              end
            end
          end
        end
        base_time = (archived_at || Time.now).to_f
        chunk_dir = File.dirname(chunk_path.to_s)

        # Split into sections by ## headings
        sections = []
        current_role       = nil
        current_lines      = []
        current_nested_chunk = nil  # chunk reference from a Compressed Summary heading

        raw.each_line do |line|
          stripped = line.chomp
          if (m = stripped.match(/\A## Assistant \[Compressed Summary — original conversation at: (.+)\]/))
            # Nested chunk reference — record it, treat as assistant section
            sections << { role: current_role, lines: current_lines.dup, nested_chunk: current_nested_chunk } if current_role
            current_role         = "assistant"
            current_lines        = []
            current_nested_chunk = File.join(chunk_dir, m[1])
          elsif stripped.match?(/\A## (User|Assistant)/)
            sections << { role: current_role, lines: current_lines.dup, nested_chunk: current_nested_chunk } if current_role
            current_role         = stripped.match(/\A## (User|Assistant)/)[1].downcase
            current_lines        = []
            current_nested_chunk = nil
          elsif stripped.match?(/\A### Tool Result:/)
            sections << { role: current_role, lines: current_lines.dup, nested_chunk: current_nested_chunk } if current_role
            current_role         = "tool"
            current_lines        = []
            current_nested_chunk = nil
          else
            current_lines << line
          end
        end
        sections << { role: current_role, lines: current_lines.dup, nested_chunk: current_nested_chunk } if current_role

        # Remove front-matter / header noise sections (nil role or non-user/assistant/tool)
        sections.select! { |s| %w[user assistant tool].include?(s[:role]) }

        # Group into rounds: each user section starts a new round
        rounds        = []
        current_round = nil
        round_index   = 0

        sections.each do |sec|
          text = sec[:lines].join.strip

          # Nested chunk: expand it recursively, prepend before current rounds
          if sec[:nested_chunk]
            nested = parse_chunk_md_to_rounds(sec[:nested_chunk], visited: visited)
            rounds = nested + rounds unless nested.empty?
            # Also render its summary text as an assistant event in current round if any
            if current_round && !text.empty?
              current_round[:events] << { role: "assistant", content: text }
            end
            next
          end

          next if text.empty?

          if sec[:role] == "user"
            round_index += 1
            # Synthetic timestamp: spread rounds backwards from archived_at
            synthetic_ts = base_time - (sections.size - round_index) * 1.0
            current_round = {
              user_msg: {
                role: "user",
                content: text,
                created_at: synthetic_ts,
                _from_chunk: true
              },
              events: []
            }
            rounds << current_round
          elsif current_round
            if sec[:role] == "assistant"
              # Detect "_Tool calls: ..._" lines — convert to tool_calls events
              # so _replay_single_message renders them as tool group UI (same as live).
              #
              # Formats supported:
              #   New: "_Tool calls: name | {"arg":"val"}; name2 | {"k":"v"}_"
              #   Old: "_Tool calls: name1, name2_"  (backward compat)
              remaining_lines = []
              pending_tool_entries = []  # [{name:, args:}]

              text.each_line do |line|
                stripped = line.strip
                if (m = stripped.match(/\A_Tool calls?:\s*(.+?)_?\z/i))
                  raw = m[1]
                  # New format uses ";" as separator between tools (each entry: "name | {json}")
                  # Old format uses "," with no JSON part.
                  entries = raw.include?(" | ") ? raw.split(/;\s*/) : raw.split(/,\s*/)
                  entries.each do |entry|
                    entry = entry.strip
                    if (parts = entry.match(/\A(.+?)\s*\|\s*(\{.+\})\z/))
                      tool_name = parts[1].strip
                      args = JSON.parse(parts[2]) rescue {}
                      pending_tool_entries << { name: tool_name, args: args }
                    else
                      pending_tool_entries << { name: entry, args: {} }
                    end
                  end
                else
                  remaining_lines << line
                end
              end

              # Flush any plain text
              plain_text = remaining_lines.join.strip
              current_round[:events] << { role: "assistant", content: plain_text } unless plain_text.empty?

              # Emit one synthetic tool_calls message per detected tool
              pending_tool_entries.each do |entry|
                current_round[:events] << {
                  role: "assistant",
                  content: "",
                  tool_calls: [{ name: entry[:name], arguments: entry[:args] }]
                }
              end
            else
              current_round[:events] << { role: "tool", content: text }
            end
          end
        end

        rounds
      rescue => e
        Clacky::Logger.warn("parse_chunk_md_to_rounds failed for #{chunk_path}: #{e.message}")
        []
      end


      # Render a single non-user message into the UI.
      # Used by both the normal round-based replay and the compressed-session fallback.
      def _replay_single_message(msg, ui)
        return if msg[:system_injected]

        case msg[:role].to_s
        when "assistant"
          # Text content
          text = extract_text_from_content(msg[:content]).to_s.strip
          ui.show_assistant_message(text, files: []) unless text.empty?

          # Tool calls embedded in assistant message
          Array(msg[:tool_calls]).each do |tc|
            name     = tc[:name] || tc.dig(:function, :name) || ""
            args_raw = tc[:arguments] || tc.dig(:function, :arguments) || {}
            args     = args_raw.is_a?(String) ? (JSON.parse(args_raw) rescue args_raw) : args_raw

            # Special handling: request_user_feedback question is shown as an
            # assistant message (matching real-time behavior), not as a tool call.
            # Reconstruct the full formatted message including options (mirrors RequestUserFeedback#execute).
            if name == "request_user_feedback"
              question = args.is_a?(Hash) ? (args[:question] || args["question"]).to_s : ""
              context  = args.is_a?(Hash) ? (args[:context]  || args["context"]).to_s  : ""
              options  = args.is_a?(Hash) ? (args[:options]  || args["options"])        : nil

              unless question.empty?
                parts = []
                parts << "**Context:** #{context.strip}" << "" unless context.strip.empty?
                parts << "**Question:** #{question.strip}"
                # Guard: options must be an Array to iterate with each_with_index
                if options.is_a?(Array) && !options.empty?
                  parts << "" << "**Options:**"
                  options.each_with_index { |opt, i| parts << "  #{i + 1}. #{opt}" }
                end
                ui.show_assistant_message(parts.join("\n"), files: [])
              end
            else
              ui.show_tool_call(name, args)
            end
          end

          # Emit token usage stored on this message (for history replay display)
          ui.show_token_usage(msg[:token_usage]) if msg[:token_usage]

        when "user"
          # Anthropic-format tool results (role: user, content: array of tool_result blocks)
          return unless msg[:content].is_a?(Array)

          msg[:content].each do |blk|
            next unless blk.is_a?(Hash) && blk[:type] == "tool_result"

            ui.show_tool_result(blk[:content].to_s)
          end

        when "tool"
          # OpenAI-format tool result
          ui.show_tool_result(msg[:content].to_s)
        end
      end

      # Replace the system message in @messages with a freshly built system prompt.
      # Called after restore_session so newly installed skills and any other
      # configuration changes since the session was saved take effect immediately.
      # If no system message exists yet (shouldn't happen in practice), a new one
      # is prepended so the conversation stays well-formed.
      def refresh_system_prompt
        # Reload skills from disk to pick up anything installed since the session was saved
        @skill_loader.load_all

        fresh_prompt = build_system_prompt
        @history.replace_system_prompt(fresh_prompt)
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
          when "document"
            # Anthropic PDF document block — return a sentinel string for frontend display
            source = block[:source]
            next unless source.is_a?(Hash) && source[:media_type].to_s == "application/pdf"

            # Return a special marker so the frontend can render a PDF badge instead of an <img>
            "pdf:#{source[:data]&.then { |d| d[0, 32] }}"  # prefix to identify without full payload
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

      # Extract images from a multipart content array and return them as file entries.
      # Returns an array of { name:, mime_type:, data_url: } hashes — the same structure
      # that the frontend sends via `files` in a message, and that show_user_message(files:) expects.
      # Only includes inline data_url images (not remote URLs).
      def extract_image_files_from_content(content)
        return [] unless content.is_a?(Array)

        content.each_with_index.filter_map do |block, idx|
          next unless block.is_a?(Hash)
          # OpenAI-style: { type: "image_url", image_url: { url: "data:image/png;base64,..." } }
          next unless block[:type] == "image_url"

          url = block.dig(:image_url, :url)
          # image_path is stored at send-time so replay can reconstruct the image from tmp
          path = block[:image_path]

          next unless url&.start_with?("data:") || path

          mime_type = (url || "")[/\Adata:([^;]+);/, 1] || "image/jpeg"
          ext       = mime_type.split("/").last
          { name: "image_#{idx + 1}.#{ext}", mime_type: mime_type, data_url: url, path: path }
        end
      end

      # Inject a chunk index card into the conversation when archived chunks exist.
      # Lists all chunk files (path + topics + turn count) so the AI knows where to
      # look if it needs details from past conversations. The AI can load any chunk
      # on demand using the existing file_reader tool — no new tools required.
      #
      # Only re-injects when a new chunk has been added since the last injection,
      # keeping the message list clean across multiple compressions.
      #
      # Cache-safe: injected as a system_injected user message in the conversation
      # turns, never touching the system prompt.
      def inject_chunk_index_if_needed
        # Collect all compressed_summary messages that carry a chunk_path
        chunk_msgs = @history.to_a.select { |m| m[:compressed_summary] && m[:chunk_path] }
        return if chunk_msgs.empty?

        # Skip if we already injected an index for this exact chunk count
        return if @history.last_injected_chunk_count == chunk_msgs.size

        # Remove any previously injected chunk index (stale — chunk count changed)
        @history.delete_where { |m| m[:chunk_index] }

        # Build index card lines
        lines = ["## Previous Session Archives (#{chunk_msgs.size} chunk#{"s" if chunk_msgs.size > 1} available)\n"]
        chunk_msgs.each_with_index do |msg, i|
          path   = msg[:chunk_path].to_s
          topics = read_chunk_topics(path)
          turns  = read_chunk_message_count(path)
          lines << "[CHUNK-#{i + 1}] #{path}"
          lines << "  Topics: #{topics}" if topics
          lines << "  Turns: #{turns}"   if turns
          lines << ""
        end
        lines << "Use file_reader to load a chunk file when you need original conversation details."

        @history.append({
          role: "user",
          content: lines.join("\n"),
          system_injected: true,
          chunk_index: true,
          chunk_count: chunk_msgs.size
        })
      end

      # Read the `topics` field from a chunk MD file's YAML front matter.
      # Returns nil if the file is missing or has no topics field.
      private def read_chunk_topics(chunk_path)
        return nil unless chunk_path && File.exist?(chunk_path)
        File.foreach(chunk_path) do |line|
          return line.sub(/^topics:\s*/, "").strip if line.start_with?("topics:")
          break if line.strip == "---" && $. > 1  # end of front matter
        end
        nil
      rescue
        nil
      end

      # Read the `message_count` field from a chunk MD file's YAML front matter.
      # Returns nil if the file is missing or has no message_count field.
      private def read_chunk_message_count(chunk_path)
        return nil unless chunk_path && File.exist?(chunk_path)
        File.foreach(chunk_path) do |line|
          return line.sub(/^message_count:\s*/, "").strip.to_i if line.start_with?("message_count:")
          break if line.strip == "---" && $. > 1
        end
        nil
      rescue
        nil
      end
    end
  end
end
