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
    def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false, cost_source: nil); end
    def append_output(content); end

    # === Status messages ===
    def show_info(message, prefix_newline: true); end
    def show_warning(message); end
    def show_error(message); end
    def show_success(message); end
    def log(message, level: :info); end

    # === Progress ===
    # Unified progress indicator with type-based display customization.
    # progress_type: "thinking" | "retrying" | "idle_compress" | custom
    # phase: "active" | "done"
    # metadata: extensible hash (e.g., {attempt: 3, total: 10} for retries)
    def show_progress(message = nil, prefix_newline: true, progress_type: "thinking", phase: "active", metadata: {}); end

    # Update the live "thinking" progress with streamed token counts.
    # This is *purely decorative*: it must NEVER start a new progress
    # indicator. If no thinking progress is currently active (e.g. during
    # idle compression, where only a quiet "Compressing..." progress is
    # live), the call is a no-op. UI2 overrides this; other UIs delegate
    # to show_progress.
    def stream_thinking_progress(input_tokens:, output_tokens:)
      show_progress(
        progress_type: "thinking",
        phase: "active",
        metadata: { input_tokens: input_tokens, output_tokens: output_tokens }
      )
    end

    # === Progress (v2: owned handles) ===
    #
    # Start a new progress indicator and return an owned handle. The caller
    # is responsible for finishing it — use +with_progress+ (below) whenever
    # possible to get ensure-based auto-close.
    #
    # @param message [String, nil] Initial progress message (nil picks a random thinking verb).
    # @param style [Symbol] :primary (foreground, yellow, bumps sessionbar)
    #   or :quiet (background, gray, no sessionbar change).
    # @param quiet_on_fast_finish [Boolean] When true, a finish under
    #   FAST_FINISH_THRESHOLD_SECONDS removes the progress line entirely
    #   (preferred for per-tool wrappers so fast tools don't leave a
    #   permanent "Executing foo… (0s)" log line). The default
    #   implementation ignores this flag — it only affects the native
    #   UI2::UIController + ProgressHandle path.
    # @return [#update, #finish, #cancel] a ProgressHandle-like object.
    #
    # Default implementation degrades gracefully to the old show_progress API
    # so UI implementations that haven't migrated still behave correctly.
    def start_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
      _ = quiet_on_fast_finish # default impl doesn't honor fast-collapse
      progress_type = style == :primary ? "thinking" : "idle_compress"
      show_progress(message, progress_type: progress_type, phase: "active")
      LegacyProgressHandleAdapter.new(self, progress_type: progress_type)
    end

    # Run the given block with a progress indicator active. The handle is
    # always finished in an +ensure+ block — exceptions (including
    # AgentInterrupted) cannot leave the ticker or entry orphaned.
    #
    # @yieldparam handle the progress handle
    def with_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
      handle = start_progress(
        message: message,
        style: style,
        quiet_on_fast_finish: quiet_on_fast_finish
      )
      begin
        yield handle
      ensure
        handle.finish
      end
    end

    # Minimal adapter that lets UIs without a native ProgressHandle still
    # participate in the new +with_progress+ API by delegating to the old
    # +show_progress(phase: ...)+ contract. UI2::UIController overrides
    # +start_progress+ directly with a native ProgressHandle, so this
    # adapter is only used by plain/json/web/channel UIs.
    class LegacyProgressHandleAdapter
      def initialize(ui, progress_type:)
        @ui = ui
        @progress_type = progress_type
        @closed = false
      end

      def update(message: nil, metadata: nil)
        return if @closed
        @ui.show_progress(message, progress_type: @progress_type, phase: "active", metadata: metadata || {})
      end

      def finish(final_message: nil)
        return if @closed
        @closed = true
        @ui.show_progress(final_message, progress_type: @progress_type, phase: "done")
      end
      alias_method :cancel, :finish
    end

    # === State updates ===
    def update_sessionbar(tasks: nil, cost: nil, cost_source: nil, status: nil, latency: nil); end
    def update_todos(todos); end
    def set_working_status; end
    def set_idle_status; end

    # === Blocking interaction ===
    def request_confirmation(message, default: true); end

    # === Input control (CLI layer) ===
    def clear_input; end
    def set_input_tips(message, type: :info); end

    # === Path redaction (for encrypted brand skill tmpdirs) ===
    # === Lifecycle ===
    def stop(clear_screen: false); end
  end
end
