# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "../ui_interface"

module Clacky
  module Server
    # WebUIController implements UIInterface for the web server mode.
    # Instead of writing to stdout, it broadcasts JSON events over WebSocket connections.
    # Multiple browser tabs can subscribe to the same session_id.
    #
    # request_confirmation blocks the calling thread until the browser sends a response,
    # mirroring the behaviour of JsonUIController (which reads from stdin).
    class WebUIController
      include Clacky::UIInterface

      attr_reader :session_id

      def initialize(session_id, broadcaster)
        @session_id  = session_id
        @broadcaster = broadcaster   # callable: broadcaster.call(session_id, event_hash)
        @mutex       = Mutex.new

        # Pending confirmation state: { id => ConditionVariable, result => value }
        @pending_confirmations = {}
      end

      # Deliver a confirmation answer received from the browser.
      # Called by the HTTP server when a confirmation message arrives over WebSocket.
      def deliver_confirmation(conf_id, result)
        @mutex.synchronize do
          pending = @pending_confirmations[conf_id]
          return unless pending

          pending[:result] = result
          pending[:cond].signal
        end
      end

      # === Output display ===

      def show_user_message(content, created_at: nil)
        data = { content: content }
        data[:created_at] = created_at if created_at
        emit("history_user_message", **data)
      end

      def show_assistant_message(content)
        return if content.nil? || content.to_s.strip.empty?

        emit("assistant_message", content: content)
      end

      def show_tool_call(name, args)
        # Skip request_user_feedback — its question is already shown as an assistant message
        return if name.to_s == "request_user_feedback"

        args_data = args.is_a?(String) ? (JSON.parse(args) rescue args) : args
        emit("tool_call", name: name, args: args_data)
      end

      def show_tool_result(result)
        emit("tool_result", result: result)
      end

      def show_tool_error(error)
        error_msg = error.is_a?(Exception) ? error.message : error.to_s
        emit("tool_error", error: error_msg)
      end

      def show_tool_args(formatted_args)
        emit("tool_args", args: formatted_args)
      end

      def show_file_write_preview(path, is_new_file:)
        emit("file_preview", path: path, operation: "write", is_new_file: is_new_file)
      end

      def show_file_edit_preview(path)
        emit("file_preview", path: path, operation: "edit")
      end

      def show_file_error(error_message)
        emit("file_error", error: error_message)
      end

      def show_shell_preview(command)
        emit("shell_preview", command: command)
      end

      def show_diff(old_content, new_content, max_lines: 50)
        emit("diff", old_size: old_content.bytesize, new_size: new_content.bytesize)
      end

      def show_token_usage(token_data)
        emit("token_usage", **token_data)
      end

      def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false)
        data = { iterations: iterations, cost: cost }
        data[:duration]               = duration            if duration
        data[:cache_stats]            = cache_stats         if cache_stats
        data[:awaiting_user_feedback] = awaiting_user_feedback if awaiting_user_feedback
        emit("complete", **data)
      end

      def append_output(content)
        emit("output", content: content)
      end

      # === Status messages ===

      def show_info(message, prefix_newline: true)
        emit("info", message: message)
      end

      def show_warning(message)
        emit("warning", message: message)
      end

      def show_error(message)
        emit("error", message: message)
      end

      def show_success(message)
        emit("success", message: message)
      end

      def log(message, level: :info)
        emit("log", level: level.to_s, message: message)
      end

      # === Progress ===

      def show_progress(message = nil, prefix_newline: true, output_buffer: nil)
        @progress_start_time = Time.now
        emit("progress", message: message, status: "start")
      end

      def clear_progress
        elapsed = @progress_start_time ? (Time.now - @progress_start_time).round(1) : 0
        @progress_start_time = nil
        emit("progress", status: "stop", elapsed: elapsed)
      end

      # === State updates ===

      def update_sessionbar(tasks: nil, cost: nil, status: nil)
        data = {}
        data[:tasks]  = tasks  if tasks
        data[:cost]   = cost   if cost
        data[:status] = status if status
        emit("session_update", **data) unless data.empty?
      end

      def update_todos(todos)
        emit("todo_update", todos: todos)
      end

      def set_working_status
        emit("session_update", status: "working")
      end

      def set_idle_status
        emit("session_update", status: "idle")
      end

      # === Blocking interaction ===
      # Emits a request_confirmation event and blocks until the browser responds.
      # Timeout after 5 minutes to avoid hanging threads forever.
      CONFIRMATION_TIMEOUT = 300 # seconds

      def request_confirmation(message, default: true)
        conf_id = "conf_#{SecureRandom.hex(4)}"

        cond    = ConditionVariable.new
        pending = { cond: cond, result: nil }

        @mutex.synchronize { @pending_confirmations[conf_id] = pending }

        emit("request_confirmation", id: conf_id, message: message, default: default)

        # Block until browser replies or timeout
        @mutex.synchronize do
          cond.wait(@mutex, CONFIRMATION_TIMEOUT)
          @pending_confirmations.delete(conf_id)
          result = pending[:result]

          # Timed out — use default
          return default if result.nil?

          case result.to_s.downcase
          when "yes", "y" then true
          when "no",  "n" then false
          else result.to_s
          end
        end
      end

      # === Input control (no-ops in web mode) ===

      def clear_input; end
      def set_input_tips(message, type: :info); end

      # === Lifecycle ===

      def stop
        emit("server_stop")
      end

      private

      def emit(type, **data)
        event = { type: type, session_id: @session_id }.merge(data)
        @broadcaster.call(@session_id, event)
      end
    end
  end
end
