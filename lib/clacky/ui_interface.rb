# frozen_string_literal: true

module Clacky
  # UIInterface defines the standard interface between Agent/CLI and UI implementations.
  # All UI controllers (UIController, JsonUIController) must implement these methods.
  module UIInterface
    # === Output display ===
    # @param content [String] text portion of the assistant reply (file:// links stripped)
    # @param files   [Array<Hash>] extracted file refs: [{ name:, path:, inline: }]
    def show_assistant_message(content, files:); end
    def show_tool_call(name, args); end
    def show_tool_result(result); end
    def show_tool_stdout(lines); end
    def show_tool_error(error); end
    def show_tool_args(formatted_args); end
    def show_file_write_preview(path, is_new_file:); end
    def show_file_edit_preview(path); end
    def show_file_error(error_message); end
    def show_shell_preview(command); end
    def show_diff(old_content, new_content, max_lines: 50); end
    def show_token_usage(token_data); end
    def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false); end
    def append_output(content); end

    # === Status messages ===
    def show_info(message, prefix_newline: true); end
    def show_warning(message); end
    def show_error(message); end
    def show_success(message); end
    def log(message, level: :info); end

    # === Progress ===
    def show_progress(message = nil, prefix_newline: true, output_buffer: nil); end
    def clear_progress(force: false); end

    # === State updates ===
    def update_sessionbar(tasks: nil, cost: nil, status: nil); end
    def update_todos(todos); end
    def set_working_status; end
    def set_idle_status; end

    # === Idle compression status ===
    # Emits a two-phase idle compression status update.
    # phase: :start  → show "Idle detected. Compressing..." (with spinner)
    # phase: :end    → update same element with final result (skipped / compressed)
    def show_idle_status(phase:, message:); end

    # === Blocking interaction ===
    def request_confirmation(message, default: true); end

    # === Input control (CLI layer) ===
    def clear_input; end
    def set_input_tips(message, type: :info); end

    # === Path redaction (for encrypted brand skill tmpdirs) ===
    # === Lifecycle ===
    def stop; end
  end
end
