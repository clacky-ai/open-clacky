# frozen_string_literal: true

module Clacky
  class Agent
    # Message compression functionality for managing conversation history
    # Handles automatic compression when token limits are exceeded
    module MessageCompressorHelper
      # Compression thresholds
      COMPRESSION_THRESHOLD = 150_000  # Trigger compression when exceeding this (in tokens)
      MESSAGE_COUNT_THRESHOLD = 200   # Trigger compression when exceeding this (in message count)
      MAX_RECENT_MESSAGES = 20  # Keep this many recent message pairs intact
      TARGET_COMPRESSED_TOKENS = 10_000  # Target size after compression
      IDLE_COMPRESSION_THRESHOLD = 20_000  # Minimum messages needed for idle compression

      # Trigger compression during idle time (user-friendly, interruptible)
      # Returns true if compression was performed, false otherwise
      def trigger_idle_compression
        # Check if we should compress (force mode)
        compression_context = compress_messages_if_needed(force: true)
        @ui&.show_idle_status(phase: :start, message: "Idle detected. Compressing conversation to optimize costs...")
        if compression_context.nil?
          @ui&.show_idle_status(phase: :end, message: "Idle skipped.")
          return false
        end

        # Insert compression message
        compression_message = compression_context[:compression_message]
        @history.append(compression_message)

        begin
          # Execute compression using shared LLM call logic
          response = call_llm
          handle_compression_response(response, compression_context)
          true
        rescue Clacky::AgentInterrupted => e
          @ui&.log("Idle compression canceled: #{e.message}", level: :info)
          @history.rollback_before(compression_message)
          false
        rescue => e
          @ui&.log("Idle compression failed: #{e.message}", level: :error)
          @history.rollback_before(compression_message)
          false
        end
      end

      # Check if compression is needed and return compression context
      # @param force [Boolean] Force compression even if thresholds not met
      # @return [Hash, nil] Compression context or nil if not needed
      def compress_messages_if_needed(force: false)
        # Check if compression is enabled
        return nil unless @config.enable_compression

        # Use actual API-reported tokens from last request
        total_tokens = @previous_total_tokens
        message_count = @history.size

        # Force compression (for idle compression) - use lower threshold
        if force
          # Only compress if we have more than MAX_RECENT_MESSAGES + system message
          return nil unless message_count > MAX_RECENT_MESSAGES + 1
          # Also require minimum message count to make compression worthwhile
          return nil unless total_tokens >= IDLE_COMPRESSION_THRESHOLD
        else
          # Normal compression - check thresholds
          # Either: token count exceeds threshold OR message count exceeds threshold
          token_threshold_exceeded = total_tokens >= COMPRESSION_THRESHOLD
          message_count_exceeded = message_count >= MESSAGE_COUNT_THRESHOLD

          # Only compress if we exceed at least one threshold
          return nil unless token_threshold_exceeded || message_count_exceeded
        end

        # Calculate how much we need to reduce
        reduction_needed = total_tokens - TARGET_COMPRESSED_TOKENS

        # Don't compress if reduction is minimal (< 10% of current size)
        # Only apply this check when triggered by token threshold (not for force mode)
        if !force && token_threshold_exceeded && reduction_needed < (total_tokens * 0.1)
          return nil
        end

        # If only message count threshold is exceeded, force compression
        # to keep conversation history manageable

        # Calculate target size for recent messages based on compression level
        target_recent_count = calculate_target_recent_count(reduction_needed)

        # Increment compression level for progressive summarization
        @compression_level += 1

        # Get the most recent N messages, ensuring tool_calls/tool results pairs are kept together
        all_messages = @history.to_a
        recent_messages = get_recent_messages_with_tool_pairs(all_messages, target_recent_count)
        recent_messages = [] if recent_messages.nil?

        # Build compression instruction message (to be inserted into conversation)
        compression_message = @message_compressor.build_compression_message(all_messages, recent_messages: recent_messages)

        return nil if compression_message.nil?

        # Return compression context for agent to handle
        {
          compression_message: compression_message,
          recent_messages: recent_messages,
          original_token_count: total_tokens,
          original_message_count: @history.size,
          compression_level: @compression_level
        }
      end

      # Handle compression response and rebuild message list
      def handle_compression_response(response, compression_context)
        # Extract compressed content from response
        compressed_content = response[:content]

        # Note: Cost tracking is already handled by call_llm, no need to track again here

        # Rebuild message list with compression
        # Note: we need to remove the compression instruction message we just added
        original_messages = @history.to_a[0..-2]  # All except the last (compression instruction)

        # Archive compressed messages to a chunk MD file before discarding them
        chunk_index = @compressed_summaries.size + 1
        chunk_path = save_compressed_chunk(
          original_messages,
          compression_context[:recent_messages],
          chunk_index: chunk_index,
          compression_level: compression_context[:compression_level]
        )

        @history.replace_all(@message_compressor.rebuild_with_compression(
          compressed_content,
          original_messages: original_messages,
          recent_messages: compression_context[:recent_messages],
          chunk_path: chunk_path
        ))

        # Reset to the estimated size of the rebuilt (small) history.
        # The compression call_llm reported the OLD large token count, so
        # @previous_total_tokens would still be above COMPRESSION_THRESHOLD —
        # without this reset the very next think() would re-trigger compression
        # immediately, causing an infinite loop (especially after image uploads
        # where base64 data inflates token counts dramatically).
        @previous_total_tokens = @history.estimate_tokens

        # Track this compression
        @compressed_summaries << {
          level: compression_context[:compression_level],
          message_count: compression_context[:original_message_count],
          timestamp: Time.now.iso8601,
          strategy: :insert_then_compress,
          chunk_path: chunk_path
        }

        # Show compression info (use estimated tokens from rebuilt history)
        @ui&.show_info(
          "History compressed (~#{compression_context[:original_token_count]} -> ~#{@history.estimate_tokens} tokens, " \
          "level #{compression_context[:compression_level]})"
        )
      end

      # Get recent messages while preserving tool_calls/tool_results pairs.
      # Handles both canonical format (role: "tool") and legacy Anthropic-native
      # format (role: "user" with tool_result content blocks).
      # @param messages [Array] All messages
      # @param count [Integer] Target number of recent messages to keep
      # @return [Array] Recent messages with complete tool pairs
      def get_recent_messages_with_tool_pairs(messages, count)
        return [] if messages.nil? || messages.empty?

        messages_to_include = Set.new
        i = messages.size - 1
        messages_collected = 0

        while i >= 0 && messages_collected < count
          msg = messages[i]

          # Never include the system message — it is always prepended separately
          # by rebuild_with_compression. Including it here would cause it to appear
          # twice in the rebuilt history, inflating token counts on every compression.
          if msg[:role] == "system"
            i -= 1
            next
          end

          if messages_to_include.include?(i)
            i -= 1
            next
          end

          messages_to_include.add(i)
          messages_collected += 1

          # assistant with tool_calls → also pull in all following tool results
          if msg[:role] == "assistant" && msg[:tool_calls]&.any?
            pull_tool_results_after(messages, i, messages_to_include)
          end

          # tool result (canonical or legacy Anthropic) → also pull in its assistant
          if tool_result_message?(msg)
            pull_assistant_before(messages, i, messages_to_include) do |added|
              messages_collected += 1 if added
            end
          end

          i -= 1
        end

        recent_messages = messages_to_include.to_a.sort.map { |idx| messages[idx] }

        # Truncate large tool results to prevent token bloat
        recent_messages.map do |msg|
          truncate_tool_result(msg)
        end
      end


      # Returns true if msg is a tool result, regardless of storage format.
      # Canonical: role:"tool"  |  Legacy Anthropic-native: role:"user" + tool_result blocks
      def tool_result_message?(msg)
        MessageFormat::OpenAI.tool_result_message?(msg) ||
          MessageFormat::Anthropic.tool_result_message?(msg)
      end

      # Returns the tool_call IDs referenced in a tool result message.
      def tool_result_ids(msg)
        if MessageFormat::OpenAI.tool_result_message?(msg)
          MessageFormat::OpenAI.tool_call_ids(msg)
        else
          MessageFormat::Anthropic.tool_use_ids(msg)
        end
      end

      # Returns true if msg is a tool result that matches any of the given call IDs.
      def tool_result_for?(msg, call_ids)
        tool_result_message?(msg) && (tool_result_ids(msg) & call_ids).any?
      end

      # Mark all tool results immediately following messages[assistant_idx].
      # Stops at the first non-tool-result message.
      def pull_tool_results_after(messages, assistant_idx, include_set)
        call_ids = messages[assistant_idx][:tool_calls].map { |tc| tc[:id] }
        j = assistant_idx + 1
        while j < messages.size
          nxt = messages[j]
          if tool_result_for?(nxt, call_ids)
            include_set.add(j)
          elsif !tool_result_message?(nxt)
            break
          end
          j += 1
        end
      end

      # Walk backwards from tool_result_idx to find and mark its assistant message.
      # Also marks all sibling tool results for that assistant.
      # Yields true if the assistant was newly added (for caller to increment count).
      def pull_assistant_before(messages, tool_result_idx, include_set)
        result_ids = tool_result_ids(messages[tool_result_idx])

        j = tool_result_idx - 1
        while j >= 0
          prev = messages[j]
          if prev[:role] == "assistant" && prev[:tool_calls]&.any?
            call_ids = prev[:tool_calls].map { |tc| tc[:id] }
            if (call_ids & result_ids).any?
              newly_added = include_set.add?(j)
              yield newly_added

              # Also pull all sibling tool results for this assistant
              pull_tool_results_after(messages, j, include_set)
              break
            end
          end
          j -= 1
        end
      end

      # Truncate oversized tool result content to avoid token bloat.
      def truncate_tool_result(msg)
        if MessageFormat::OpenAI.tool_result_message?(msg) &&
            msg[:content].is_a?(String) && msg[:content].length > 2000
          msg.merge(content: msg[:content][0..2000] + "...\n[Content truncated - exceeded 2000 characters]")
        else
          msg
        end
      end

      # Save the messages being compressed to a chunk MD file for future recall
      # File path: ~/.clacky/sessions/{datetime}-{short_id}-chunk-{n}.md
      # @param original_messages [Array<Hash>] All messages before compression (excluding compression instruction)
      # @param recent_messages [Array<Hash>] Recent messages being kept (to exclude from chunk)
      # @param chunk_index [Integer] Sequential chunk number
      # @param compression_level [Integer] Compression level
      # @return [String, nil] Path to saved chunk file, or nil if save failed
      def save_compressed_chunk(original_messages, recent_messages, chunk_index:, compression_level:)
        return nil unless @session_id && @created_at

        # Messages being compressed = original minus system message minus recent messages
        recent_set = recent_messages.to_a
        messages_to_archive = original_messages.reject do |m|
          m[:role] == "system" || recent_set.include?(m)
        end

        return nil if messages_to_archive.empty?

        sessions_dir = Clacky::SessionManager::SESSIONS_DIR
        datetime = Time.parse(@created_at).strftime("%Y-%m-%d-%H-%M-%S")
        short_id = @session_id[0..7]
        base_name = "#{datetime}-#{short_id}"
        chunk_filename = "#{base_name}-chunk-#{chunk_index}.md"
        chunk_path = File.join(sessions_dir, chunk_filename)

        md_content = build_chunk_md(messages_to_archive, chunk_index: chunk_index, compression_level: compression_level)

        File.write(chunk_path, md_content)
        FileUtils.chmod(0o600, chunk_path)

        chunk_path
      rescue => e
        @ui&.log("Failed to save chunk MD: #{e.message}", level: :warn)
        nil
      end

      # Build markdown content from a list of messages
      # @param messages [Array<Hash>] Messages to render
      # @param chunk_index [Integer] Chunk number for metadata
      # @param compression_level [Integer] Compression level
      # @return [String] Markdown content
      def build_chunk_md(messages, chunk_index:, compression_level:)
        lines = []

        # Front matter
        lines << "---"
        lines << "session_id: #{@session_id}"
        lines << "chunk: #{chunk_index}"
        lines << "compression_level: #{compression_level}"
        lines << "archived_at: #{Time.now.iso8601}"
        lines << "message_count: #{messages.size}"
        lines << "---"
        lines << ""
        lines << "# Session Chunk #{chunk_index}"
        lines << ""
        lines << "> This file contains the original conversation archived during compression."
        lines << "> Use `file_reader` to recall specific details from this conversation."
        lines << ""

        messages.each do |msg|
          role = msg[:role]
          content = msg[:content]

          case role
          when "user"
            lines << "## User"
            lines << ""
            lines << format_message_content(content)
            lines << ""
          when "assistant"
            # If this message is itself a compressed summary, annotate the header
            # so the reader knows the original conversation is in the referenced chunk
            if msg[:compressed_summary] && msg[:chunk_path]
              prev_chunk = File.basename(msg[:chunk_path])
              lines << "## Assistant [Compressed Summary — original conversation at: #{prev_chunk}]"
            else
              lines << "## Assistant"
            end
            lines << ""
            # Include tool calls summary if present
            if msg[:tool_calls]&.any?
              tool_names = msg[:tool_calls].map { |tc| tc.dig(:function, :name) }.compact.join(", ")
              lines << "_Tool calls: #{tool_names}_"
              lines << ""
            end
            lines << format_message_content(content) if content
            lines << ""
          when "tool"
            tool_name = msg[:name] || "tool"
            lines << "### Tool Result: #{tool_name}"
            lines << ""
            lines << "```"
            lines << truncate_content(content.to_s, max_length: 500)
            lines << "```"
            lines << ""
          end
        end

        lines.join("\n")
      end

      # Format message content (handles string or array of content blocks)
      def format_message_content(content)
        return "" if content.nil?
        return content.to_s if content.is_a?(String)

        # Handle array of content blocks (e.g., text + images)
        if content.is_a?(Array)
          content.map do |block|
            if block.is_a?(Hash) && block[:type] == "text"
              block[:text].to_s
            else
              "[#{block[:type] || 'content'}]"
            end
          end.join("\n")
        else
          content.to_s
        end
      end

      # Truncate long content with a note
      def truncate_content(text, max_length: 500)
        return text if text.length <= max_length
        "#{text[0...max_length]}\n... [truncated, #{text.length} chars total]"
      end

      # Calculate how many recent messages to keep based on how much we need to compress
      def calculate_target_recent_count(reduction_needed)
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
      def generate_hierarchical_summary(messages)
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
      def extract_key_information(messages)
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
      def extract_from_messages(messages, role_filter = nil, &block)
        return [] if messages.nil?

        results = messages
          .select { |m| role_filter.nil? || m[:role] == role_filter.to_s }
          .map(&block)
          .compact

        # Flatten if we have nested arrays (from methods returning arrays of items)
        results.any? { |r| r.is_a?(Array) } ? results.flatten.uniq : results.uniq
      end

      # Helper: extract tool names from tool_calls
      def extract_tool_names(tool_calls)
        return [] unless tool_calls.is_a?(Array)
        tool_calls.map { |tc| tc.dig(:function, :name) }
      end

      # Helper: filter write results by action
      def filter_write_results(result, action)
        result && result[:action] == action ? result[:file] : nil
      end

      # Helper: filter todo results by status
      def filter_todo_results(result, status)
        result && result[:status] == status ? result[:task] : nil
      end

      # Helper: extract decision text from content (returns array of decisions or empty array)
      def extract_decision_text(content)
        return [] unless content.is_a?(String)
        return [] unless content.include?("decision") || content.include?("chose to") || content.include?("using")

        sentences = content.split(/[.!?]/).select do |s|
          s.include?("decision") || s.include?("chose") || s.include?("using") ||
          s.include?("decided") || s.include?("will use") || s.include?("selected")
        end
        sentences.map(&:strip).map { |s| s[0..100] }
      end

      # Helper: find in-progress task
      def find_in_progress(messages)
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
      def empty_extraction_data
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

      def parse_write_result(content)
        return nil unless content.is_a?(String)

        # Check for "Created: path" or "Updated: path" patterns
        if content.include?("Created:")
          { action: :created, file: content[/Created:\s*(.+)/, 1]&.strip }
        elsif content.include?("Updated:") || content.include?("modified")
          { action: :modified, file: content[/Updated:\s*(.+)/, 1]&.strip || content[/File written to:\s*(.+)/, 1]&.strip }
        else
          nil
        end
      end

      def parse_todo_result(content)
        return nil unless content.is_a?(String)

        if content.include?("completed")
          { status: :completed, task: content[/completed[:\s]*(.+)/i, 1]&.strip || "task" }
        elsif content.include?("added")
          { status: :added, task: content[/added[:\s]*(.+)/i, 1]&.strip || "task" }
        else
          nil
        end
      end

      def parse_shell_result(content)
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
      def generate_level1_summary(data)
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
      def generate_level2_summary(data)
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
      def generate_level3_summary(data)
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
      def generate_level4_summary(data)
        all_files = (data[:files_created] + data[:files_modified]).uniq
        "Progress: #{data[:completed_tasks].size} tasks, #{all_files.size} files. Recent: #{data[:tools_used].last(3).join(', ')}"
      end
    end
  end
end
