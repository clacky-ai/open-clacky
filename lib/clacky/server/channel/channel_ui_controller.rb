# frozen_string_literal: true

require_relative "../../ui_interface"

module Clacky
  module Channel
    # ChannelUIController implements UIInterface for IM platform sessions.
    # It is registered as a subscriber on WebUIController so that every
    # agent output event is forwarded here and sent back to the IM platform.
    #
    # Design notes:
    # - Tool calls / results / diffs / token usage are intentionally suppressed
    #   to keep IM chat clean. Only high-signal events are forwarded.
    # - Buffering: file/shell previews accumulate in a buffer and are flushed
    #   as one message before the next assistant message, avoiding flooding.
    # - request_confirmation is not invoked directly on this class — the Web
    #   UI handles the blocking wait and only sends show_warning notifications.
    class ChannelUIController
      include Clacky::UIInterface

      BUFFER_FLUSH_SIZE = 5  # flush early when buffer is large

      attr_reader :platform, :chat_id

      def initialize(event, adapter)
        @platform   = event[:platform]
        @chat_id    = event[:chat_id]
        @message_id = event[:message_id]  # original message to reply under
        @adapter    = adapter
        @buffer     = []
        @mutex      = Mutex.new
      end

      # Update the reply context for the current inbound message.
      # Called at the start of each route_message so replies are threaded correctly.
      # @param event [Hash] inbound event with :message_id
      def update_message_context(event)
        @mutex.synchronize { @message_id = event[:message_id] }
      end

      # === Output display ===

      # Forward WebUI user messages to the IM channel so both sides stay in sync.
      # Prefixed with the product/user context so it's clear who sent it.
      def show_user_message(content)
        return if content.nil? || content.to_s.strip.empty?

        send_text("[USER] #{content}")
      end

      def show_assistant_message(content, files:)
        flush_buffer
        Clacky::Logger.info("[ChannelUI] show_assistant_message files=#{files.size} content_len=#{content.to_s.length}")
        send_text(content) unless content.nil? || content.to_s.strip.empty?
        files.each do |f|
          Clacky::Logger.info("[ChannelUI] sending file path=#{f[:path].inspect} name=#{f[:name].inspect}")
          send_file(f[:path], f[:name])
        end
      end

      def show_tool_call(name, args)
        # Suppress — too noisy for IM
      end

      def show_tool_result(result)
        # Suppress — too noisy for IM
      end

      def show_tool_error(error)
        msg = error.is_a?(Exception) ? error.message : error.to_s
        send_text("Tool error: #{msg}")
      end

      def show_tool_args(formatted_args)
        # Suppress
      end

      def show_file_write_preview(path, is_new_file:)
        action = is_new_file ? "create" : "overwrite"
        buffer_line("#{action}: #{path}")
      end

      def show_file_edit_preview(path)
        buffer_line("edit: #{path}")
      end

      def show_shell_preview(command)
        buffer_line("$ #{command}")
      end

      def show_file_error(error_message)
        send_text("File error: #{error_message}")
      end

      def show_diff(old_content, new_content, max_lines: 50)
        # Diffs are too verbose for IM — suppress
      end

      def show_token_usage(token_data)
        # Suppress
      end

      def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false)
        flush_buffer
        parts = ["Done", "#{iterations} step#{"s" if iterations != 1}"]
        parts << "$#{cost.round(4)}" if cost && cost > 0
        parts << "#{duration.round(1)}s" if duration
        send_text(parts.join(" · "))
      end

      def append_output(content)
        return if content.nil? || content.to_s.strip.empty?

        send_text(content)
      end

      # === Status messages ===

      def show_info(message, prefix_newline: true)
        # Suppress informational noise in IM
      end

      def show_warning(message)
        send_text("Warning: #{message}")
      end

      def show_error(message)
        send_text("Error: #{message}")
      end

      def show_success(message)
        send_text(message)
      end

      def log(message, level: :info)
        # Suppress
      end

      # === Progress ===

      def show_progress(message = nil, prefix_newline: true, output_buffer: nil)
        # Suppress — progress spinner has no IM equivalent
      end

      # === State updates (no-ops for IM) ===

      def update_sessionbar(tasks: nil, cost: nil, status: nil); end
      def update_todos(todos); end
      def set_working_status; end
      def set_idle_status; end

      # === Blocking interaction ===
      # Not called directly — WebUIController handles the blocking wait
      # and only notifies IM via show_warning. Implemented as auto-approve
      # as a safety fallback in case this is ever called directly.
      def request_confirmation(message, default: true)
        send_text("Confirmation requested (auto-approved): #{message}")
        default
      end

      # === Input control / lifecycle (no-ops) ===

      def clear_input; end
      def set_input_tips(message, type: :info); end
      def stop; end


      def send_text(text)
        text = text.to_s.gsub(/<think>[\s\S]*?<\/think>\n*/i, "").strip
        return if text.empty?

        @adapter.send_text(@chat_id, text, reply_to: @message_id)
      rescue StandardError => e
        warn "[ChannelUI] send_text failed (#{@platform}/#{@chat_id}): #{e.message}"
        nil
      end

      def send_file(path, name = nil)
        if @adapter.respond_to?(:send_file)
          @adapter.send_file(@chat_id, path, name: name)
        else
          # Fallback for adapters that don't support file sending
          send_text("File: #{name || File.basename(path)}\n#{path}")
        end
      rescue StandardError => e
        Clacky::Logger.error("[ChannelUI] send_file failed (#{@platform}/#{@chat_id}): #{e.message}")
        send_text("Failed to send file: #{File.basename(path)}\nError: #{e.message}")
      end

      def buffer_line(line)
        @mutex.synchronize do
          @buffer << line
          flush_buffer_unlocked if @buffer.size >= BUFFER_FLUSH_SIZE
        end
      end

      def flush_buffer
        @mutex.synchronize { flush_buffer_unlocked }
      end

      def flush_buffer_unlocked
        return if @buffer.empty?

        send_text(@buffer.join("\n"))
        @buffer.clear
      end
    end
  end
end
