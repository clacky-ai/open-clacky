# frozen_string_literal: true

module Clacky
  # MessageHistory wraps the conversation message list and exposes
  # business-meaningful operations instead of raw array manipulation.
  #
  # Internal fields (task_id, created_at, system_injected, etc.) are kept
  # in the internal store but stripped when calling #to_api.
  class MessageHistory
    # Fields that are internal to the agent and must not be sent to the API.
    INTERNAL_FIELDS = %i[
      task_id created_at system_injected session_context memory_update
      subagent_instructions subagent_result token_usage
      compressed_summary chunk_path truncated transient
      chunk_index chunk_count
    ].freeze

    def initialize(messages = [])
      @messages = messages.dup
    end

    # ─────────────────────────────────────────────
    # Write operations
    # ─────────────────────────────────────────────

    # Append a single message hash to the history.
    #
    # When appending a user message, automatically drop any trailing assistant
    # message that has unanswered tool_calls (no tool_result follows it).
    # This prevents API error 2013 ("tool call result does not follow tool call")
    # when a previous task ended before observe() could append tool results
    # (e.g. subagent crash, interrupt, or error).
    def append(message)
      if message[:role] == "user"
        drop_dangling_tool_calls!
      end
      @messages << deep_sanitize_utf8(message)
      self
    end

    # Replace (or insert at head) the system prompt message.
    # Used by session_serializer#refresh_system_prompt.
    def replace_system_prompt(content, **extra)
      msg = { role: "system", content: content }.merge(extra)
      idx = @messages.index { |m| m[:role] == "system" }
      if idx
        @messages[idx] = msg
      else
        @messages.unshift(msg)
      end
      self
    end

    # Replace the entire message list (used by compression rebuild).
    def replace_all(new_messages)
      @messages = new_messages.map { |m| deep_sanitize_utf8(m) }
      self
    end

    # Remove and return the last message.
    def pop_last
      @messages.pop
    end

    # Remove all messages matching the block in-place.
    # Generic history pruning utility — used by callers that need to
    # strip transient/system-injected messages out of the persisted
    # history (e.g. compaction, rollback on 400 errors).
    def delete_where(&block)
      @messages.reject!(&block)
      self
    end

    # Mutate the last message matching the predicate lambda in-place.
    # Used by execute_skill_with_subagent to update instruction messages.
    def mutate_last_matching(predicate, &block)
      msg = @messages.reverse.find { |m| predicate.call(m) }
      block.call(msg) if msg
      self
    end

    # Remove all messages from index onward (used by restore_session on error).
    def truncate_from(index)
      @messages = @messages[0...index]
      self
    end

    # Roll back the history to just before the given message object.
    # Removes the message and anything appended after it.
    # Used to undo a failed speculative append (e.g. compression message that errored).
    def rollback_before(message)
      idx = @messages.index { |m| m.equal?(message) }
      return self unless idx

      @messages = @messages[0...idx]
      self
    end

    # ─────────────────────────────────────────────
    # Business queries
    # ─────────────────────────────────────────────

    # True when the last assistant message has tool_calls but no
    # tool_result has been appended yet (would cause a 400 from the API).
    def pending_tool_calls?
      return false if @messages.empty?

      last = @messages.last
      return false unless last[:role] == "assistant" && last[:tool_calls]&.any?

      # Check that there is no tool result message after this assistant message
      last_assistant_idx = @messages.rindex { |m| m == last }
      @messages[(last_assistant_idx + 1)..].none? { |m| m[:role] == "tool" || m[:tool_results] }
    end

    # Return the session_date value from the most recent session_context message.
    # Used by inject_session_context_if_needed to avoid re-injecting on the same date.
    def last_session_context_date
      msg = @messages.reverse.find { |m| m[:session_context] }
      msg&.dig(:session_date)
    end

    # Return the chunk_count from the most recently injected chunk index message.
    # Used by inject_chunk_index_if_needed to avoid re-injecting when nothing changed.
    def last_injected_chunk_count
      msg = @messages.reverse.find { |m| m[:chunk_index] }
      msg&.dig(:chunk_count) || 0
    end

    # Return only real (non-system-injected) user messages.
    def real_user_messages
      @messages.select { |m| m[:role] == "user" && !m[:system_injected] }
    end

    # Return the index of the last real (non-system-injected) user message.
    # Used by restore_session to trim back to a clean state on error.
    def last_real_user_index
      @messages.rindex { |m| m[:role] == "user" && !m[:system_injected] }
    end

    # Return the message with :subagent_instructions set.
    def subagent_instruction_message
      @messages.find { |m| m[:subagent_instructions] }
    end

    # Return all messages where task_id <= given id (Time Machine support).
    def for_task(task_id)
      @messages.select { |m| !m[:task_id] || m[:task_id] <= task_id }
    end

    # ─────────────────────────────────────────────
    # Size helpers
    # ─────────────────────────────────────────────

    def size
      @messages.size
    end

    def empty?
      @messages.empty?
    end

    # Estimate total token count for all messages.
    # Uses the ~4 chars/token heuristic (works well for English/code).
    # Handles string content, array content blocks, and tool_calls.
    def estimate_tokens
      @messages.sum { |m| estimate_message_tokens(m) }
    end

    # ─────────────────────────────────────────────
    # Output
    # ─────────────────────────────────────────────

    # Return a clean copy of messages suitable for sending to the LLM API:
    # - strips internal-only fields
    def to_api
      @messages.map { |m| strip_internal_fields(m) }
    end

    # Return a shallow copy of the message list, excluding transient messages.
    # Transient messages (e.g. brand skill instructions) are valid during the
    # current session but must not be persisted to session.json.
    # For serialization, compression, and cloning.
    def to_a
      @messages.reject { |m| m[:transient] }.dup
    end

    # Estimate token count for a single message (role overhead + content).
    private def estimate_message_tokens(message)
      # ~4 tokens of overhead per message (role, formatting)
      tokens = 4
      tokens += estimate_content_tokens(message[:content])

      # tool_calls: each call adds name + arguments chars
      if message[:tool_calls].is_a?(Array)
        message[:tool_calls].each do |tc|
          tokens += estimate_content_tokens(tc.dig(:function, :name))
          tokens += estimate_content_tokens(tc.dig(:function, :arguments))
        end
      end

      tokens
    end

    # Estimate tokens from a content value (string, array of blocks, or nil).
    # Heuristic: ASCII/code ~4 chars/token; CJK/multibyte ~1.5 chars/token.
    private def estimate_content_tokens(content)
      case content
      when String
        ascii_chars = content.scan(/[ -~]/).length
        multibyte_chars = content.length - ascii_chars
        ((ascii_chars / 4.0) + (multibyte_chars / 1.5)).ceil
      when Array
        content.sum do |block|
          block.is_a?(Hash) ? estimate_content_tokens(block[:text] || block["text"]) : 0
        end
      else
        0
      end
    end

    # Drop the trailing assistant message if it has tool_calls with no subsequent
    # tool_result — i.e. the tool call was never answered (dangling).
    # Called automatically before appending any user message.
    private def drop_dangling_tool_calls!
      return unless pending_tool_calls?

      @messages.pop
    end

    private def strip_internal_fields(message)
      message.reject { |k, _| INTERNAL_FIELDS.include?(k) }
    end

    # Defense-in-depth: recursively scrub invalid UTF-8 bytes from every String
    # stored in the message tree. Even if a tool forgets to scrub its output,
    # nothing poisoned will ever reach session persistence or JSON.generate.
    #
    # Fast path: if the tree contains only valid UTF-8 strings, the original
    # object is returned unchanged — preserving object identity for callers
    # that rely on `equal?` (e.g. rollback_before).
    # Slow path: any invalid byte triggers a rebuild with scrubbed strings
    # (invalid bytes → U+FFFD).
    private def deep_sanitize_utf8(obj)
      case obj
      when String
        return obj if obj.encoding == Encoding::UTF_8 && obj.valid_encoding?
        obj.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\u{FFFD}")
      when Hash
        return obj unless contains_dirty_utf8?(obj)
        obj.transform_values { |v| deep_sanitize_utf8(v) }
      when Array
        return obj unless contains_dirty_utf8?(obj)
        obj.map { |v| deep_sanitize_utf8(v) }
      else
        obj
      end
    end

    # Cheap recursive check: does this subtree contain any invalid-UTF-8 string?
    # Short-circuits on first offender. Keeps the common case (all valid UTF-8)
    # allocation-free.
    private def contains_dirty_utf8?(obj)
      case obj
      when String
        !(obj.encoding == Encoding::UTF_8 && obj.valid_encoding?)
      when Hash
        obj.any? { |_, v| contains_dirty_utf8?(v) }
      when Array
        obj.any? { |v| contains_dirty_utf8?(v) }
      else
        false
      end
    end
  end
end
