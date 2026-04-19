# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "ui_interface"

module Clacky
  # JsonUIController implements UIInterface for JSON (NDJSON) output mode.
  # All output is written as one-JSON-per-line to stdout.
  # Confirmation requests read responses from stdin.
  class JsonUIController
    include Clacky::UIInterface

    def initialize(output: $stdout, input: $stdin)
      @output = output
      @input = input
      @mutex = Mutex.new
    end

    # Emit a raw NDJSON event
    def emit(type, **data)
      event = { type: type }.merge(data)
      @mutex.synchronize do
        @output.puts(JSON.generate(event))
        @output.flush
      end
    end

    # === Output display ===

    def show_assistant_message(content, files:)
      return if (content.nil? || content.strip.empty?) && files.empty?

      data = { content: content.to_s }
      data[:files] = files if files.any?
      emit("assistant_message", **data)
    end

    def show_tool_call(name, args)
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
      data[:duration] = duration if duration
      data[:cache_stats] = cache_stats if cache_stats
      data[:awaiting_user_feedback] = awaiting_user_feedback if awaiting_user_feedback
      emit("complete", **data)
    end

    # append_output is a no-op in JSON mode (content is already emitted via semantic methods)
    def append_output(content)
      # no-op
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

    def show_progress(message = nil, prefix_newline: true, progress_type: "thinking", phase: "active", metadata: {})
      @progress_start_time = Time.now if phase == "active"
      
      data = {
        message: message,
        progress_type: progress_type,
        phase: phase,
        status: phase == "active" ? "start" : "stop"  # backward compat
      }
      data[:metadata] = metadata unless metadata.empty?
      data[:elapsed] = (Time.now - @progress_start_time).round(1) if phase == "done" && @progress_start_time
      
      emit("progress", **data)
      
      @progress_start_time = nil if phase == "done"
    end

    # === State updates ===

    def update_sessionbar(tasks: nil, cost: nil, status: nil)
      data = {}
      data[:tasks] = tasks if tasks
      data[:cost] = cost if cost
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

    def request_confirmation(message, default: true)
      conf_id = "conf_#{SecureRandom.hex(4)}"
      emit("request_confirmation", id: conf_id, message: message, default: default)

      # Read response from stdin (blocking)
      line = @input.gets
      return default if line.nil?

      begin
        response = JSON.parse(line.strip)
        result = response["result"] || response[:result]

        case result.to_s.downcase
        when "yes", "y" then true
        when "no", "n" then false
        else
          # Return as feedback text
          result.to_s
        end
      rescue JSON::ParserError
        default
      end
    end

    # === Input control (no-ops in JSON mode) ===

    def clear_input
      # no-op
    end

    def set_input_tips(message, type: :info)
      # no-op
    end

    # === Lifecycle ===

    def stop
      # no-op
    end

  end
end
