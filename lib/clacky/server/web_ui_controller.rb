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

        # Channel subscribers: array of objects implementing UIInterface.
        # All emitted events are forwarded to each subscriber after WebSocket broadcast.
        @channel_subscribers = []
        @subscribers_mutex   = Mutex.new
      end

      # Register a channel subscriber (e.g. ChannelUIController).
      # The subscriber will receive every UIInterface call that this controller handles.
      # @param subscriber [#UIInterface methods]
      # @return [void]
      def subscribe_channel(subscriber)
        @subscribers_mutex.synchronize { @channel_subscribers << subscriber }
      end

      # Remove a previously registered channel subscriber.
      # @param subscriber [Object]
      # @return [void]
      def unsubscribe_channel(subscriber)
        @subscribers_mutex.synchronize { @channel_subscribers.delete(subscriber) }
      end

      # @return [Boolean] true if any channel subscribers are registered
      def channel_subscribed?
        @subscribers_mutex.synchronize { !@channel_subscribers.empty? }
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

      def show_user_message(content, created_at: nil, files: [], source: :web)
        data = { content: content }
        data[:created_at] = created_at if created_at
        # Build ev.images for the frontend renderer (history_user_message):
        #   - Images with data_url → pass the data_url directly (<img> thumbnail)
        #   - Disk files (PDF, doc, etc., no data_url) → "pdf:name" sentinel (renders a badge)
        rendered = Array(files).filter_map do |f|
          url  = f[:data_url] || f["data_url"]
          name = f[:name]     || f["name"]
          url || (name ? "pdf:#{name}" : nil)
        end
        data[:images] = rendered unless rendered.empty?
        emit("history_user_message", **data)
        # Only forward to channel subscribers when the message originated from the WebUI,
        # to avoid echoing channel messages back to the same channel.
        return unless source == :web
        forward_to_subscribers { |sub| sub.show_user_message(content) if sub.respond_to?(:show_user_message) }
      end

      def show_assistant_message(content, files:)
        return if (content.nil? || content.to_s.strip.empty?) && files.empty?

        emit("assistant_message", content: content, files: files)
        forward_to_subscribers { |sub| sub.show_assistant_message(content, files: files) }
      end

      def show_tool_call(name, args)
        # Skip request_user_feedback — its question is already shown as an assistant message
        return if name.to_s == "request_user_feedback"

        args_data = args.is_a?(String) ? (JSON.parse(args) rescue args) : args

        # Generate a human-readable summary using the tool's format_call method
        summary = tool_call_summary(name, args_data)
        emit("tool_call", name: name, args: args_data, summary: summary)
        forward_to_subscribers { |sub| sub.show_tool_call(name, args_data) }
      end

      def show_tool_result(result)
        emit("tool_result", result: result)
        forward_to_subscribers { |sub| sub.show_tool_result(result) }
      end

      def show_tool_error(error)
        error_msg = error.is_a?(Exception) ? error.message : error.to_s
        emit("tool_error", error: error_msg)
        forward_to_subscribers { |sub| sub.show_tool_error(error) }
      end

      def show_tool_args(formatted_args)
        emit("tool_args", args: formatted_args)
        forward_to_subscribers { |sub| sub.show_tool_args(formatted_args) }
      end

      def show_file_write_preview(path, is_new_file:)
        emit("file_preview", path: path, operation: "write", is_new_file: is_new_file)
        forward_to_subscribers { |sub| sub.show_file_write_preview(path, is_new_file: is_new_file) }
      end

      def show_file_edit_preview(path)
        emit("file_preview", path: path, operation: "edit")
        forward_to_subscribers { |sub| sub.show_file_edit_preview(path) }
      end

      def show_file_error(error_message)
        emit("file_error", error: error_message)
        forward_to_subscribers { |sub| sub.show_file_error(error_message) }
      end

      def show_shell_preview(command)
        emit("shell_preview", command: command)
        forward_to_subscribers { |sub| sub.show_shell_preview(command) }
      end

      def show_diff(old_content, new_content, max_lines: 50)
        emit("diff", old_size: old_content.bytesize, new_size: new_content.bytesize)
        # Diffs are too verbose for IM — intentionally not forwarded
      end

      def show_token_usage(token_data)
        emit("token_usage", **token_data)
        # Token usage is internal detail — intentionally not forwarded
      end

      def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false)
        data = { iterations: iterations, cost: cost }
        data[:duration]               = duration            if duration
        data[:cache_stats]            = cache_stats         if cache_stats
        data[:awaiting_user_feedback] = awaiting_user_feedback if awaiting_user_feedback
        emit("complete", **data)
        forward_to_subscribers do |sub|
          sub.show_complete(iterations: iterations, cost: cost, duration: duration,
                            cache_stats: cache_stats, awaiting_user_feedback: awaiting_user_feedback)
        end
      end

      def append_output(content)
        emit("output", content: content)
        forward_to_subscribers { |sub| sub.append_output(content) }
      end

      # === Status messages ===

      def show_info(message, prefix_newline: true)
        emit("info", message: message)
        forward_to_subscribers { |sub| sub.show_info(message) }
      end

      # Emit a two-phase idle compression status update.
      # The frontend uses the same DOM element for both phases so it renders as one line.
      # phase: :start → show spinner message; phase: :end → update in-place with final result
      def show_idle_status(phase:, message:)
        emit("idle_status", phase: phase.to_s, message: message)
      end

      def show_warning(message)
        emit("warning", message: message)
        forward_to_subscribers { |sub| sub.show_warning(message) }
      end

      def show_error(message)
        emit("error", message: message)
        forward_to_subscribers { |sub| sub.show_error(message) }
      end

      def show_success(message)
        emit("success", message: message)
        forward_to_subscribers { |sub| sub.show_success(message) }
      end

      def log(message, level: :info)
        emit("log", level: level.to_s, message: message)
        # Log forwarding intentionally skipped — too noisy for IM
      end

      # === Progress ===

      def show_progress(message = nil, prefix_newline: true, output_buffer: nil)
        @progress_start_time = Time.now
        emit("progress", message: message, status: "start")
        forward_to_subscribers { |sub| sub.show_progress(message) }
      end

      def clear_progress
        elapsed = @progress_start_time ? (Time.now - @progress_start_time).round(1) : 0
        @progress_start_time = nil
        emit("progress", status: "stop", elapsed: elapsed)
        forward_to_subscribers { |sub| sub.clear_progress }
      end

      # === State updates ===

      def update_sessionbar(tasks: nil, cost: nil, status: nil)
        data = {}
        data[:tasks]  = tasks  if tasks
        data[:cost]   = cost   if cost
        data[:status] = status if status
        emit("session_update", **data) unless data.empty?
        forward_to_subscribers { |sub| sub.update_sessionbar(tasks: tasks, cost: cost, status: status) }
      end

      def update_todos(todos)
        emit("todo_update", todos: todos)
        forward_to_subscribers { |sub| sub.update_todos(todos) }
      end

      def set_working_status
        emit("session_update", status: "working")
        forward_to_subscribers { |sub| sub.set_working_status }
      end

      def set_idle_status
        emit("session_update", status: "idle")
        forward_to_subscribers { |sub| sub.set_idle_status }
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

        # Notify channel subscribers that confirmation is pending — non-blocking.
        # They display a notice; the actual decision comes from the Web UI user.
        forward_to_subscribers { |sub| sub.show_warning("⏳ Confirmation requested: #{message}") }

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


      # Generate a short human-readable summary for a tool call display.
      # Delegates to each tool's own format_call method when available.
      def tool_call_summary(name, args)
        class_name = name.to_s.split("_").map(&:capitalize).join
        return nil unless Clacky::Tools.const_defined?(class_name)

        tool = Clacky::Tools.const_get(class_name).new
        args_sym = args.is_a?(Hash) ? args.transform_keys(&:to_sym) : {}
        tool.format_call(args_sym)
      rescue StandardError
        nil
      end

      def emit(type, **data)
        event = { type: type, session_id: @session_id }.merge(data)
        @broadcaster.call(@session_id, event)
      end

      # Forward a UIInterface call to all registered channel subscribers.
      # Each subscriber is called in the same thread as the caller (Agent thread).
      # Errors in individual subscribers are rescued and logged so they never
      # interrupt the main agent execution.
      def forward_to_subscribers(&block)
        subscribers = @subscribers_mutex.synchronize { @channel_subscribers.dup }
        return if subscribers.empty?

        subscribers.each do |sub|
          block.call(sub)
        rescue StandardError => e
          warn "[WebUIController] channel subscriber error: #{e.message}"
        end
      end
    end
  end
end
