# frozen_string_literal: true

require_relative "ui_interface"

module Clacky
  # PlainUIController implements UIInterface for non-interactive (--message) mode.
  # Writes human-readable plain text directly to stdout so the caller can capture
  # or pipe the output. No spinners, no TUI — just clean lines.
  class PlainUIController
    include Clacky::UIInterface

    def initialize(output: $stdout)
      @output = output
      @mutex = Mutex.new
    end

    # === Output display ===

    def show_assistant_message(content, files:)
      puts_line(content) unless content.nil? || content.strip.empty?
      files.each { |f| puts_line("📄 File: #{f[:path]}") }
    end

    def show_tool_call(name, args)
      args_data = args.is_a?(String) ? (JSON.parse(args) rescue args) : args
      display = case name
                when "shell", "safe_shell"
                  cmd = args_data.is_a?(Hash) ? (args_data[:command] || args_data["command"]) : args_data
                  "$ #{cmd}"
                when "write"
                  path = args_data.is_a?(Hash) ? (args_data[:path] || args_data["path"]) : args_data
                  "Write → #{path}"
                when "edit"
                  path = args_data.is_a?(Hash) ? (args_data[:path] || args_data["path"]) : args_data
                  "Edit → #{path}"
                else
                  label = args_data.is_a?(Hash) ? args_data.map { |k, v| "#{k}=#{v.to_s[0..40]}" }.join(", ") : args_data.to_s[0..80]
                  "#{name}(#{label})"
                end
      puts_line("[tool] #{display}")
    end

    def show_tool_result(result)
      text = result.to_s.strip
      return if text.empty?

      # Indent multi-line results for readability
      indented = text.lines.map { |l| "  #{l}" }.join
      puts_line(indented)
    end

    def show_tool_error(error)
      msg = error.is_a?(Exception) ? error.message : error.to_s
      puts_line("[error] #{msg}")
    end

    def show_file_write_preview(path, is_new_file:)
      action = is_new_file ? "create" : "overwrite"
      puts_line("[file] #{action}: #{path}")
    end

    def show_file_edit_preview(path)
      puts_line("[file] edit: #{path}")
    end

    def show_file_error(error_message)
      puts_line("[file error] #{error_message}")
    end

    def show_shell_preview(command)
      puts_line("[shell] #{command}")
    end

    def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false)
      parts = ["[done] iterations=#{iterations}", "cost=$#{cost.round(4)}"]
      parts << "duration=#{duration.round(1)}s" if duration
      puts_line(parts.join(" "))
    end

    def append_output(content)
      puts_line(content)
    end

    # === Status messages ===

    def show_info(message, prefix_newline: true)
      puts_line("[info] #{message}")
    end

    def show_idle_status(phase:, message:)
      # In plain mode, just print the final state
      puts_line("[info] #{message}") if phase.to_s == "end"
    end

    def show_warning(message)
      puts_line("[warn] #{message}")
    end

    def show_error(message)
      puts_line("[error] #{message}")
    end

    def show_success(message)
      puts_line("[ok] #{message}")
    end

    def log(message, level: :info)
      # Only surface errors/warnings; suppress debug noise in plain mode
      puts_line("[#{level}] #{message}") if %i[error warn].include?(level.to_sym)
    end

    # === Progress (no-ops — no spinner in plain mode) ===

    def show_progress(message = nil, prefix_newline: true, output_buffer: nil); end
    def clear_progress; end

    # === State updates (no-ops) ===

    def update_sessionbar(tasks: nil, cost: nil, status: nil); end
    def update_todos(todos); end
    def set_working_status; end
    def set_idle_status; end

    # === Blocking interaction (auto-approve in non-interactive mode) ===

    def request_confirmation(message, default: true)
      # Should not be reached because permission_mode is forced to auto_approve,
      # but return true as a safety net.
      true
    end

    # === Input control / Lifecycle (no-ops) ===

    def clear_input; end
    def set_input_tips(message, type: :info); end
    def stop; end


    def puts_line(text)
      @mutex.synchronize do
        @output.puts(text)
        @output.flush
      end
    end
  end
end
