# frozen_string_literal: true

require_relative "layout_manager"
require_relative "view_renderer"
require_relative "progress_handle"
require_relative "components/input_area"
require_relative "components/todo_area"
require_relative "components/welcome_banner"
require_relative "components/inline_input"
require_relative "thinking_verbs"
require_relative "../ui_interface"

module Clacky
  module UI2
    # UIController is the MVC controller layer that coordinates UI state and user interactions
    class UIController
      include Clacky::UIInterface

      attr_reader :layout, :renderer, :running, :inline_input, :input_area
      attr_accessor :config

      def initialize(config = {})
        @renderer = ViewRenderer.new

        # Set theme if specified
        ThemeManager.set_theme(config[:theme]) if config[:theme]

        # Store configuration
        @config = {
          working_dir: config[:working_dir],
          mode: config[:mode],
          model: config[:model],
          theme: config[:theme]
        }

        # Initialize layout components
        @input_area = Components::InputArea.new
        @todo_area = Components::TodoArea.new
        @welcome_banner = Components::WelcomeBanner.new
        @inline_input = nil  # Created when needed
        @layout = LayoutManager.new(
          input_area: @input_area,
          todo_area: @todo_area
        )

        @running = false
        @input_callback = nil
        @interrupt_callback = nil
        @time_machine_callback = nil
        @tasks_count = 0
        @total_cost = 0.0
        @last_diff_lines = nil

        # ── Progress subsystem (v2: owned handles, stacked) ──────────────
        # Every progress indicator is an owned ProgressHandle. UiController
        # is the "owner" in the handle protocol: it keeps a stack of live
        # handles, only the top of which is rendered. See ProgressHandle
        # for the full protocol and stack semantics.
        @progress_stack = []
        @progress_mutex = Mutex.new
      end

      # Start the UI controller
      def start
        initialize_and_show_banner
        start_input_loop
      end

      # Initialize screen and show banner (separate from input loop)
      # @param recent_user_messages [Array<String>, nil] Recent user messages when loading session
      def initialize_and_show_banner(recent_user_messages: nil)
        @running = true

        # Set session bar data before initializing screen
        @input_area.update_sessionbar(
          working_dir: @config[:working_dir],
          mode: @config[:mode],
          model: @config[:model],
          tasks: @tasks_count,
          cost: @total_cost
        )

        @layout.initialize_screen

        # Display welcome banner or session history
        if recent_user_messages && !recent_user_messages.empty?
          display_session_history(recent_user_messages)
        else
          display_welcome_banner
        end
      end

      # Start input loop (separate from initialization)
      def start_input_loop
        @running = true
        input_loop
      end

      # Set skill loader for command suggestions in the input area
      # @param skill_loader [Clacky::SkillLoader] The skill loader instance
      # @param agent_profile [Clacky::AgentProfile, nil] Current agent profile for skill filtering
      def set_skill_loader(skill_loader, agent_profile = nil)
        @input_area.set_skill_loader(skill_loader, agent_profile)
      end

      # Update session bar with current stats
      # @param tasks [Integer] Number of completed tasks (optional)
      # @param cost [Float] Total cost (optional)
      # @param cost_source [Symbol, nil] :api / :price / :default (optional)
      # @param status [String] Workspace status ('idle' or 'working') (optional)
      def update_sessionbar(tasks: nil, cost: nil, cost_source: nil, status: nil)
        @tasks_count = tasks if tasks
        @total_cost = cost if cost
        @input_area.update_sessionbar(
          working_dir: @config[:working_dir],
          mode: @config[:mode],
          model: @config[:model],
          tasks: @tasks_count,
          cost: @total_cost,
          cost_source: cost_source,
          status: status
        )
        @layout.render_input
      end

      # Toggle permission mode between confirm_safes and auto_approve
      def toggle_mode
        current_mode = @config[:mode]
        new_mode = case current_mode.to_s
        when /confirm_safes/
          "auto_approve"
        when /auto_approve/
          "confirm_safes"
        else
          "auto_approve"  # Default to auto_approve if unknown mode
        end

        @config[:mode] = new_mode

        # Notify CLI to update agent_config
        @mode_toggle_callback&.call(new_mode)

        update_sessionbar
      end

      # Stop the UI controller
      def stop
        @running = false
        @layout.cleanup_screen
      end

      # Clear the input area
      def clear_input
        @input_area.clear
      end

      # Set input tips message
      # @param message [String] Tip message to display
      # @param type [Symbol] Tip type (:info, :warning, etc.)
      def set_input_tips(message, type: :info)
        @input_area.set_tips(message, type: type)
      end

      # Set callback for user input
      # @param block [Proc] Callback to execute with user input
      def on_input(&block)
        @input_callback = block
      end

      # Set callback for interrupt (Ctrl+C)
      # @param block [Proc] Callback to execute on interrupt
      def on_interrupt(&block)
        @interrupt_callback = block
      end

      # Set callback for mode toggle (Shift+Tab)
      # @param block [Proc] Callback to execute on mode toggle
      def on_mode_toggle(&block)
        @mode_toggle_callback = block
      end

      # Set callback for time machine (ESC key)
      # @param block [Proc] Callback to execute on time machine
      def on_time_machine(&block)
        @time_machine_callback = block
      end

      # Set agent for command suggestions
      # @param agent [Clacky::Agent] The agent instance with skill management
      # @param agent_profile [Clacky::AgentProfile, nil] Current agent profile for skill filtering
      def set_agent(agent, agent_profile = nil)
        @input_area.set_agent(agent, agent_profile)
      end

      # Append output to the output area
      # @param content [String] Content to append
      def append_output(content)
        @layout.append_output(content)
      end

      # Log message to output area (use instead of puts)
      # @param message [String] Message to log
      # @param level [Symbol] Log level (:debug, :info, :warning, :error)
      def log(message, level: :info)
        theme = ThemeManager.current_theme

        output = case level
        when :debug
          # Gray dimmed text for debug messages
          theme.format_text("    [DEBUG] #{message}", :thinking)
        when :info
          # Info symbol with normal text
          "#{theme.format_symbol(:info)} #{message}"
        when :warning
          # Warning rendering
          @renderer.render_warning(message)
        when :error
          # Error rendering
          @renderer.render_error(message)
        else
          # Default to info
          "#{theme.format_symbol(:info)} #{message}"
        end

        append_output(output)
      end

      # Update an OutputBuffer entry's content by id.
      # @param id [Integer, nil] Entry id (no-op if nil or already committed)
      # @param content [String] New content for the entry
      private def update_entry(id, content)
        return unless id
        @layout.replace_entry(id, content)
      end

      # Remove an OutputBuffer entry by id (no-op if nil or committed).
      # @param id [Integer, nil]
      private def remove_entry(id)
        return unless id
        @layout.remove_entry(id)
      end

      # Update todos display
      # @param todos [Array<Hash>] Array of todo items
      def update_todos(todos)
        @layout.update_todos(todos)
      end

      # Display token usage statistics
      # @param token_data [Hash] Token usage data containing:
      #   - delta_tokens: token delta from previous iteration
      #   - prompt_tokens: input tokens
      #   - completion_tokens: output tokens
      #   - total_tokens: total tokens
      #   - cache_write: cache write tokens
      #   - cache_read: cache read tokens
      #   - cost: cost for this iteration
      def show_token_usage(token_data)
        theme = ThemeManager.current_theme
        pastel = Pastel.new

        token_info = []

        # Delta tokens with color coding (green/yellow/red + dim)
        delta_tokens = token_data[:delta_tokens]
        delta_str = delta_tokens.negative? ? "#{delta_tokens}" : "+#{delta_tokens}"
        color_style = if delta_tokens > 10000
          :red
        elsif delta_tokens > 5000
          :yellow
        else
          :green
        end
        colored_delta = if delta_tokens.negative?
          pastel.cyan(delta_str)
        else
          pastel.decorate(delta_str, color_style, :dim)
        end
        token_info << colored_delta

        # Cache status indicator (using theme)
        cache_write = token_data[:cache_write]
        cache_read = token_data[:cache_read]
        cache_used = cache_read > 0 || cache_write > 0
        if cache_used
          token_info << pastel.dim(theme.symbol(:cached))
        end

        # Input tokens (with cache breakdown if available)
        prompt_tokens = token_data[:prompt_tokens]
        if cache_write > 0 || cache_read > 0
          input_detail = "#{prompt_tokens} (cache: #{cache_read} read, #{cache_write} write)"
          token_info << pastel.dim("Input: #{input_detail}")
        else
          token_info << pastel.dim("Input: #{prompt_tokens}")
        end

        # Output tokens
        token_info << pastel.dim("Output: #{token_data[:completion_tokens]}")

        # Total
        token_info << pastel.dim("Total: #{token_data[:total_tokens]}")

        # Cost for this iteration with color coding (red/yellow for high cost, dim for normal)
        # :api    => "$0.001234"      (exact, from API)
        # :price  => "~$0.001234"     (estimated from pricing table)
        # :default => "N/A"           (model not in pricing table, unknown cost)
        cost_source = token_data[:cost_source]
        if cost_source == :default
          token_info << pastel.dim("Cost: N/A")
        elsif token_data[:cost]
          cost = token_data[:cost]
          cost_value = cost_source == :price ? "~$#{cost.round(6)}" : "$#{cost.round(6)}"
          if cost >= 0.1
            # High cost - red warning
            colored_cost = pastel.decorate(cost_value, :red, :dim)
            token_info << pastel.dim("Cost: ") + colored_cost
          elsif cost >= 0.05
            # Medium cost - yellow warning
            colored_cost = pastel.decorate(cost_value, :yellow, :dim)
            token_info << pastel.dim("Cost: ") + colored_cost
          else
            # Low cost - normal gray
            token_info << pastel.dim("Cost: #{cost_value}")
          end
        end

        # Display through output system (already all dimmed, just add prefix)
        token_display = pastel.dim("    [Tokens] ") + token_info.join(pastel.dim(' | '))
        append_output(token_display)
      end

      # Show tool call arguments
      # @param formatted_args [String] Formatted arguments string
      def show_tool_args(formatted_args)
        theme = ThemeManager.current_theme
        append_output("\n#{theme.format_text("Args: #{formatted_args}", :thinking)}")
      end

      # Show file operation preview (Write tool)
      # @param path [String] File path
      # @param is_new_file [Boolean] Whether this is a new file
      def show_file_write_preview(path, is_new_file:)
        theme = ThemeManager.current_theme
        file_label = theme.format_symbol(:file)
        status = is_new_file ? theme.format_text("Creating new file", :success) : theme.format_text("Modifying existing file", :warning)
        append_output("\n#{file_label} #{path || '(unknown)'}")
        append_output(status)
      end

      # Show file operation preview (Edit tool)
      # @param path [String] File path
      def show_file_edit_preview(path)
        theme = ThemeManager.current_theme
        file_label = theme.format_symbol(:file)
        append_output("\n#{file_label} #{path || '(unknown)'}")
      end

      # Show file operation error
      # @param error_message [String] Error message
      def show_file_error(error_message)
        theme = ThemeManager.current_theme
        append_output("   #{theme.format_text("Warning:", :error)} #{error_message}")
      end

      # Show shell command preview
      # @param command [String] Shell command
      def show_shell_preview(command)
        theme = ThemeManager.current_theme
        cmd_label = theme.format_symbol(:command)
        append_output("\n#{cmd_label} #{command}")
      end

      # === Semantic UI Methods (for Agent to call directly) ===

      # Show assistant message
      # @param content [String] Message content
      def show_assistant_message(content, files:)
        # Filter out thinking tags from models like MiniMax M2.1 that use <think>...</think>
        filtered_content = filter_thinking_tags(content)
        return if filtered_content.nil? || filtered_content.strip.empty?

        output = @renderer.render_assistant_message(filtered_content)
        append_output(output)
      end

      # Filter out thinking tags from content
      # Some models (e.g., MiniMax M2.1) wrap their reasoning in <think>...</think> tags
      # @param content [String] Raw content from model
      # @return [String] Content with thinking tags removed
      def filter_thinking_tags(content)
        return content if content.nil?

        # Remove <think>...</think> blocks (multiline, case-insensitive)
        # Also handles variations like <thinking>...</thinking>
        filtered = content.gsub(%r{<think(?:ing)?>[\s\S]*?</think(?:ing)?>}mi, '')

        # Clean up multiple empty lines left behind (max 2 consecutive newlines)
        filtered.gsub!(/\n{3,}/, "\n\n")

        # Remove leading and trailing whitespace
        filtered.strip
      end

      # Show tool call
      # @param name [String] Tool name
      # @param args [String, Hash] Tool arguments (JSON string or Hash)
      def show_tool_call(name, args)
        # Reset stdout buffer on each new tool call so previous command output
        # doesn't bleed into the next one, and so the buffer is ready before
        # on_output starts firing (which can happen before show_progress is called).
        @stdout_lines = nil

        # Special handling for request_user_feedback: render as a readable interactive card
        # with the full question and options, rather than the truncated format_call summary.
        if name.to_s == "request_user_feedback"
          args_data = args.is_a?(String) ? (JSON.parse(args, symbolize_names: true) rescue {}) : args
          args_data = args_data.transform_keys(&:to_sym) if args_data.is_a?(Hash)

          question = args_data[:question].to_s.strip
          context  = args_data[:context].to_s.strip
          options  = Array(args_data[:options])

          theme = ThemeManager.current_theme
          parts = []

          parts << context unless context.empty?
          parts << question unless question.empty?

          if options.any?
            parts << ""
            options.each_with_index { |opt, i| parts << "  #{i + 1}. #{opt}" }
          end

          card_text = parts.join("\n")
          output = @renderer.render_system_message(card_text, prefix_newline: true)
          append_output(output)
          return
        end

        formatted_call = format_tool_call(name, args)
        output = @renderer.render_tool_call(tool_name: name, formatted_call: formatted_call)
        append_output(output)
      end

      # Show tool result
      # @param result [String] Formatted tool result
      def show_tool_result(result)
        output = @renderer.render_tool_result(result: result)
        append_output(output)
      end

      # Show tool error
      # @param error [String, Exception] Error message or exception
      def show_tool_error(error)
        error_msg = error.is_a?(Exception) ? error.message : error.to_s
        output = @renderer.render_tool_error(error: error_msg)
        append_output(output)
      end

      # Receive a chunk of shell stdout from the on_output callback.
      # Lines are buffered into @stdout_lines so that Ctrl+O can open a
      # fullscreen live view, matching the original output_buffer interaction.
      # @param lines [Array<String>] One or more stdout chunks
      def show_tool_stdout(lines)
        return if lines.nil? || lines.empty?
        @stdout_lines ||= []
        @stdout_lines.concat(lines.map(&:chomp))
      end

      # Show completion status (only for tasks with more than 5 iterations)
      # @param iterations [Integer] Number of iterations
      # @param cost [Float] Cost of this run
      # @param duration [Float] Duration in seconds
      # @param cache_stats [Hash] Cache statistics
      # @param awaiting_user_feedback [Boolean] Whether agent is waiting for user feedback
      def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false)
        # Update status back to 'idle' when task is complete
        update_sessionbar(status: 'idle')

        # Clear user tip when agent stops working
        @input_area.clear_user_tip
        @layout.render_input

        # Don't show completion message if awaiting user feedback
        return if awaiting_user_feedback

        # Only show completion message for complex tasks (>5 iterations)
        return if iterations <= 5

        cache_tokens = cache_stats&.dig(:cache_read_input_tokens)
        cache_requests = cache_stats&.dig(:total_requests)
        cache_hits = cache_stats&.dig(:cache_hit_requests)

        output = @renderer.render_task_complete(
          iterations: iterations,
          cost: cost,
          duration: duration,
          cache_tokens: cache_tokens,
          cache_requests: cache_requests,
          cache_hits: cache_hits
        )
        append_output(output)
      end

      # Show progress indicator with dynamic elapsed time
      # @param message [String] Progress message (optional, will use random thinking verb if nil)
      # ---------------------------------------------------------------------
      # Progress indicator API (v2)
      #
      # The preferred public API is +start_progress+ / +with_progress+, which
      # returns a ProgressHandle the caller owns. Use +with_progress+ whenever
      # possible — it uses +ensure+ to guarantee cleanup even on exceptions
      # (e.g. AgentInterrupted during idle compression).
      #
      # The legacy +show_progress(message, phase:, ...)+ method is kept as a
      # thin shim for existing call sites that haven't been migrated yet.
      # ---------------------------------------------------------------------

      # Start a new progress indicator and return its owned handle.
      #
      # @param message [String] Initial progress message.
      # @param style [Symbol] :primary (foreground, yellow, bumps sessionbar)
      #   or :quiet (background, gray, no sessionbar change).
      # @param quiet_on_fast_finish [Boolean] See ProgressHandle — when true,
      #   a finish that elapses under FAST_FINISH_THRESHOLD_SECONDS removes
      #   the entry instead of leaving a permanent final frame. Preferred
      #   for tool-execution wrappers.
      # @return [Clacky::UI2::ProgressHandle]
      def start_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
        display = (message.nil? || message.to_s.strip.empty?) ? Clacky::THINKING_VERBS.sample : message.to_s
        ProgressHandle.new(
          owner: self,
          message: display,
          style: style,
          quiet_on_fast_finish: quiet_on_fast_finish
        ).start
      end

      # Run the given block with a progress indicator active. The handle is
      # always finished in an +ensure+ block, so exceptions (including
      # Thread#raise) cannot leave the ticker or entry orphaned.
      #
      # @yieldparam handle [Clacky::UI2::ProgressHandle]
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

      # Returns true if any progress indicator is currently active.
      def progress_active?
        @progress_mutex.synchronize { !@progress_stack.empty? }
      end

      # Finish every active progress handle, top to bottom. Used by the
      # interrupt path (Ctrl+C) so a single keypress guarantees the UI is
      # quiescent regardless of how many nested/background progresses are
      # running.
      def interrupt_all_progress
        # Snapshot outside the handle's finish() (which also grabs the
        # mutex via unregister_progress) to avoid re-entrant lock issues.
        handles = @progress_mutex.synchronize { @progress_stack.dup }
        # Finish from top (newest) to bottom (oldest) so each top is the
        # one currently rendering when it finishes.
        handles.reverse_each(&:finish)
        # Also drop legacy-shim handle registry so a subsequent
        # show_progress(phase: "done") from unmigrated callers is a no-op.
        @legacy_progress_handles&.clear
      end

      # ----- Owner protocol for ProgressHandle ----------------------------
      #
      # These three methods implement the contract described in
      # ProgressHandle's class documentation. They are part of the public
      # API only for ProgressHandle — external callers should use
      # +start_progress+ / +with_progress+ instead.

      # Called by ProgressHandle#start.
      def register_progress(handle)
        @progress_mutex.synchronize do
          prev_top = @progress_stack.last
          if prev_top
            # Plan B: the lower handle loses its OutputBuffer entry until
            # the new top finishes. We remove its on-screen line now and
            # tell it to forget its id; we'll allocate a new id on restore.
            remove_entry(prev_top.entry_id)
            prev_top.__detach_entry!
          end

          @progress_stack.push(handle)
          entry_id = append_output(render_for(handle))
          update_sessionbar(status: 'working') if handle.style == :primary
          entry_id
        end
      end

      # Called by ProgressHandle#finish.
      def unregister_progress(handle, final_frame:)
        @progress_mutex.synchronize do
          # If this handle still holds its entry (it's currently top), we
          # render one last frame there and release the id. If it was
          # previously detached (someone above is still active), its entry
          # is already gone and the final_frame is simply dropped.
          if handle.entry_id
            if final_frame && !final_frame.to_s.strip.empty?
              update_entry(handle.entry_id, @renderer.render_progress(final_frame))
            else
              remove_entry(handle.entry_id)
            end
          end

          @progress_stack.delete(handle)

          # Restore the new top, if any: allocate a fresh entry and let it
          # resume rendering from where it left off.
          if (restored = @progress_stack.last)
            new_id = append_output(render_for(restored))
            restored.__reattach_entry!(new_id)
          else
            # No more progress handles — clear the "working" sessionbar.
            # We only flip to idle if the handle that just finished was
            # the one that brought us to working (style :primary). A quiet
            # handle finishing never touches the sessionbar.
            update_sessionbar(status: 'idle') if handle.style == :primary
          end
        end
      end

      # Called by ProgressHandle's ticker and +update+. Writes +frame+ into
      # the handle's entry iff it is currently top-of-stack. Non-top
      # handles silently do nothing (their entry was detached in
      # +register_progress+).
      def render_frame(handle, frame)
        @progress_mutex.synchronize do
          return unless @progress_stack.last == handle
          return unless handle.entry_id

          has_output = @stdout_lines && !@stdout_lines.empty?
          suffix = has_output ?
            " (Ctrl+C to interrupt · Ctrl+O to view output)" :
            " (Ctrl+C to interrupt)"
          decorated = "#{frame}#{suffix}"

          painted = handle.style == :primary ?
            @renderer.render_working(decorated) :
            @renderer.render_progress(decorated)
          update_entry(handle.entry_id, painted)
        end
      end

      # Render the very first frame of +handle+ (used when registering or
      # restoring). Mirrors +render_frame+'s formatting minus the implicit
      # elapsed-time tick (handle hasn't ticked yet).
      private def render_for(handle)
        frame = handle.current_frame
        has_output = @stdout_lines && !@stdout_lines.empty?
        suffix = has_output ?
          " (Ctrl+C to interrupt · Ctrl+O to view output)" :
          " (Ctrl+C to interrupt)"
        decorated = "#{frame}#{suffix}"
        handle.style == :primary ?
          @renderer.render_working(decorated) :
          @renderer.render_progress(decorated)
      end

      # ---------------------------------------------------------------------
      # Legacy shim: show_progress(message, phase:, progress_type:, ...)
      #
      # This method preserves the pre-refactor API so existing call sites
      # (Agent#run, Agent#think, LlmCaller retry, trigger_idle_compression,
      # MemoryUpdater) keep working until they're migrated to the owned-
      # handle API.
      #
      # Each progress_type owns its own handle slot so two concurrent
      # background flows (e.g. idle compression + thinking) can coexist
      # without stomping on each other — exactly the race that caused the
      # yellow/gray flicker bug.
      # ---------------------------------------------------------------------
      def show_progress(message = nil, prefix_newline: true, progress_type: "thinking", phase: "active", metadata: {})
        _ = prefix_newline # ignored in v2; layout is not the caller's concern

        type = progress_type.to_s
        style = %w[retrying idle_compress].include?(type) ? :quiet : :primary

        @legacy_progress_handles ||= {}

        if phase.to_s == "done"
          handle = @legacy_progress_handles.delete(type)
          handle&.finish(final_message: message)
          return
        end

        # "active" phase — start a new handle or update the existing one.
        existing = @legacy_progress_handles[type]
        if existing&.running?
          # Bare re-entry: no new info → just leave the existing spinner alone.
          # This preserves the long-standing "Agent#run and Agent#think both
          # call show_progress for fast feedback" idiom.
          return if message.nil? && metadata.empty?

          attempt = metadata[:attempt]
          total   = metadata[:total]
          suffix  = (attempt && total) ? " (#{attempt}/#{total})" : ""
          existing.update(message: "#{message || existing.message}#{suffix}", metadata: metadata)
          return
        end

        attempt = metadata[:attempt]
        total   = metadata[:total]
        suffix  = (attempt && total) ? " (#{attempt}/#{total})" : ""
        display = ((message && !message.to_s.strip.empty?) ? message.to_s : Clacky::THINKING_VERBS.sample) + suffix

        @legacy_progress_handles[type] = start_progress(message: display, style: style)
      end

      # ---------------------------------------------------------------------
      # (Legacy dead-code removed: the old imperative show_progress body
      # used to live here and is now superseded by the shim + owner
      # protocol above. Keeping this note so a future grep for
      # "@progress_id" / "@progress_thread" finds the migration explanation.)
      # ---------------------------------------------------------------------

      # Stop the fullscreen refresh thread gracefully via flag + join.
      def stop_fullscreen_refresh_thread
        @fullscreen_refresh_stop = true
        if @fullscreen_refresh_thread&.alive?
          joined = @fullscreen_refresh_thread.join(1.0)
          @fullscreen_refresh_thread.kill unless joined
        end
        @fullscreen_refresh_thread = nil
        @fullscreen_refresh_stop = false
      end

      # Show info message
      # @param message [String] Info message
      # @param prefix_newline [Boolean] Whether to add newline before message (default: true)
      def show_info(message, prefix_newline: true)
        output = @renderer.render_system_message(message, prefix_newline: prefix_newline)
        append_output(output)
      end

      # Show warning message
      # @param message [String] Warning message
      def show_warning(message)
        output = @renderer.render_warning(message)
        append_output(output)
      end

      # Show error message
      # @param message [String] Error message
      def show_error(message)
        output = @renderer.render_error(message)
        append_output(output)
      end

      # Show success message
      # @param message [String] Success message
      def show_success(message)
        output = @renderer.render_success(message)
        append_output(output)
      end

      # Set workspace status to idle (called when agent stops working)
      def set_idle_status
        update_sessionbar(status: 'idle')
        # Clear user tip when agent stops working
        @input_area.clear_user_tip
        @layout.render_input
      end

      # Set workspace status to working (called when agent starts working)
      def set_working_status
        update_sessionbar(status: 'working')
        # Show a random user tip with 40% probability when agent starts working
        @input_area.show_user_tip(probability: 0.4)
        @layout.render_input
      end

      # Show help text
      def show_help
        theme = ThemeManager.current_theme

        # Separator line
        separator = theme.format_text("─" * 60, :info)

        lines = [
          separator,
          "",
          theme.format_text("Commands:", :info),
          "  #{theme.format_text("/clear", :success)}       - Clear output and restart session",
          "  #{theme.format_text("/exit", :success)}        - Exit application",
          "",
          theme.format_text("Input:", :info),
          "  #{theme.format_text("Shift+Enter", :success)}  - New line",
          "  #{theme.format_text("Up/Down", :success)}      - History navigation",
          "  #{theme.format_text("Ctrl+V", :success)}       - Paste image (Ctrl+D to delete, max 3)",
          "  #{theme.format_text("Ctrl+C", :success)}       - Clear input (press 2x to exit)",
          "",
          theme.format_text("Other:", :info),
          "  Supports Emacs-style shortcuts (Ctrl+A, Ctrl+E, etc.)",
          "",
          separator
        ]

        lines.each { |line| append_output(line) }
      end

      # Request confirmation from user (blocking)
      # @param message [String] Confirmation prompt
      # @param default [Boolean] Default value if user presses Enter
      # @return [Boolean, String, nil] true/false for yes/no, String for feedback, nil for cancelled
      def request_confirmation(message, default: true)
        # Show question in output with theme styling
        theme = ThemeManager.current_theme
        question_symbol = theme.format_symbol(:info)
        append_output("#{question_symbol} #{message}")

        # Pause InputArea
        @input_area.pause
        @layout.recalculate_layout

        # Create InlineInput with styled prompt
        inline_input = Components::InlineInput.new(
          prompt: "Press Enter/y to approve(Shift+Tab for all), 'n' to reject, or type feedback: ",
          default: nil
        )
        @inline_input = inline_input

        # Add inline input line to output (use layout to track position)
        inline_id = @layout.append_output(inline_input.render)
        @layout.position_inline_input_cursor(inline_input)

        result_text = nil
        begin
          # Collect input (blocks until user presses Enter).
          # May raise AgentInterrupted if main thread Thread#raises the
          # worker mid-pop — we MUST still restore input state in ensure.
          result_text = inline_input.collect
        ensure
          # Clean up - remove the inline input lines (handle wrapped lines).
          # Use the tracked id so removal is safe even when more output
          # was appended in between.
          @layout.remove_entry(inline_id) if inline_id

          # Deactivate InlineInput and restore the main InputArea. This
          # MUST run even on exception so the user can type after
          # interrupting a confirmation prompt.
          @inline_input = nil
          @input_area.resume
          @layout.recalculate_layout
          @layout.render_all
        end

        # Append the final response to output (only on normal return)
        if result_text.nil?
          append_output(theme.format_text("  [Cancelled]", :error))
        else
          display_text = result_text.empty? ? (default ? "y" : "n") : result_text
          append_output(theme.format_text("  #{display_text}", :success))
        end

        # Parse result
        return nil if result_text.nil?  # Cancelled

        response = result_text.strip.downcase
        case response
        when "y", "yes" then true
        when "n", "no" then false
        when "" then default
        else
          result_text  # Return feedback text
        end
      end

      # Show diff between old and new content
      # @param old_content [String] Old content
      # @param new_content [String] New content
      # @param max_lines [Integer] Maximum lines to show
      def show_diff(old_content, new_content, max_lines: 50)
        require 'diffy'

        diff = Diffy::Diff.new(old_content, new_content, context: 3)
        diff_lines = diff.to_s(:color).lines

        # Store for fullscreen toggle
        @last_diff_lines = diff_lines

        # Show diff without line numbers
        diff_lines.take(max_lines).each do |line|
          append_output(line.chomp)
        end

        if diff_lines.size > max_lines
          append_output("\n... (#{diff_lines.size - max_lines} more lines hidden. Press Ctrl+O to open full diff in pager)")
        end
      rescue LoadError
        # Fallback if diffy is not available
        append_output("   Old size: #{old_content.bytesize} bytes")
        append_output("   New size: #{new_content.bytesize} bytes")
        @last_diff_lines = nil
      end

      # Show fullscreen diff view (only if not already expanded)
      private def redisplay_diff
        return unless @last_diff_lines
        return if @layout.fullscreen_mode?

        # Use `less -R` as pager: it handles its own alternate screen + scrolling,
        # and restores the terminal perfectly on exit — no DIY scrolling needed.
        content = @last_diff_lines.join

        # Write diff to a temp file so less can read it
        require "tempfile"
        tmpfile = Tempfile.new(["clacky_diff", ".txt"])
        tmpfile.write(content)
        tmpfile.flush

        # Suspend raw mode so less can take full control of the terminal
        @layout.screen.disable_raw_mode

        # --mouse       : enable mouse wheel scrolling inside less
        # --wheel-lines : scroll 3 lines per wheel click (comfortable default)
        # -R            : pass through ANSI colour codes
        # Unset LESSOPEN/LESSCLOSE so less doesn't try to pre-process the file
        system(
          { "LESSOPEN" => nil, "LESSCLOSE" => nil },
          "less", "--mouse", "--wheel-lines=3", "-R", tmpfile.path
        )

        # Restore raw mode and repaint the main screen
        @layout.screen.enable_raw_mode
        @layout.rerender_all
      ensure
        tmpfile&.close
        tmpfile&.unlink
      end

      # Show fullscreen command output view
      def show_command_output
        return unless @stdout_lines && !@stdout_lines.empty?
        return if @layout.fullscreen_mode?

        lines = build_command_output_lines
        @layout.enter_fullscreen(lines, hint: "Press Ctrl+O to return · Output updates in real-time")

        # Start background thread to refresh fullscreen content in real-time.
        # Use a dedicated stop flag so we can join() the thread cleanly and
        # avoid Thread#kill interrupting the thread while it holds @render_mutex.
        @fullscreen_refresh_stop = false
        @fullscreen_refresh_thread = Thread.new do
          until @fullscreen_refresh_stop || !@layout.fullscreen_mode?
            sleep 0.3
            next if @fullscreen_refresh_stop || !@layout.fullscreen_mode?

            @layout.refresh_fullscreen(build_command_output_lines)
          end
        rescue StandardError
          # Silently handle thread errors
        end
      end


      # Build command output lines snapshot from @stdout_lines
      # @return [Array<String>] Lines to display in fullscreen
      private def build_command_output_lines
        lines = @stdout_lines&.dup || []
        lines.empty? ? ["(No output yet)"] : lines
      end

      # Format tool call for display
      # @param name [String] Tool name
      # @param args [String, Hash] Tool arguments
      # @return [String] Formatted call string
      def format_tool_call(name, args)
        args_hash = args.is_a?(String) ? JSON.parse(args, symbolize_names: true) : args

        # Try to get tool instance for custom formatting
        tool = get_tool_instance(name)
        if tool
          begin
            return tool.format_call(args_hash)
          rescue StandardError
            # Fallback
          end
        end

        # Simple fallback
        "#{name}(...)"
      rescue JSON::ParserError
        "#{name}(...)"
      end

      # Get tool instance by name
      # @param tool_name [String] Tool name
      # @return [Object, nil] Tool instance or nil
      def get_tool_instance(tool_name)
        # Convert tool_name to class name (e.g., "file_reader" -> "FileReader")
        class_name = tool_name.split('_').map(&:capitalize).join

        # Try to find the class in Clacky::Tools namespace
        if Clacky::Tools.const_defined?(class_name)
          tool_class = Clacky::Tools.const_get(class_name)
          tool_class.new
        else
          nil
        end
      rescue NameError
        nil
      end

      # Display welcome banner with logo and agent info
      def display_welcome_banner
        content = @welcome_banner.render_full(
          working_dir: @config[:working_dir],
          mode: @config[:mode],
          width: @layout.screen.width
        )
        append_output(content)

        # Check if API key is configured (show warning AFTER banner)
        check_api_key_configuration
      end

      # Check if API key is configured and show warning if missing
      private def check_api_key_configuration
        config = Clacky::AgentConfig.load
        
        if !config.models_configured?
          show_warning("No models configured! Please run /config to set up your models and API keys.")
        elsif config.api_key.nil? || config.api_key.empty?
          show_warning("API key is not configured! Please run /config to set up your API key.")
        end
      end

      # Display recent user messages when loading session
      # @param user_messages [Array<String>] Array of recent user message texts
      def display_session_history(user_messages)
        theme = ThemeManager.current_theme

        # Show logo banner only
        append_output(@welcome_banner.render_logo(width: @layout.screen.width))

        # Show simple header
        append_output(theme.format_text("Recent conversation:", :info))

        # Display each user message with numbering
        user_messages.each_with_index do |msg, index|
          # Truncate long messages
          display_msg = if msg.length > 140
            "#{msg[0..137]}..."
          else
            msg
          end

          # Show with number and indentation
          append_output("  #{index + 1}. #{display_msg}")
        end

        # Bottom spacing and continuation prompt
        append_output("")
        append_output(theme.format_text("Session restored. Feel free to continue with your next task.", :success))
      end

      # Main input loop
      def input_loop
        @layout.screen.enable_raw_mode

        while @running
          # Process any pending resize events
          @layout.process_pending_resize
          
          key = @layout.screen.read_key(timeout: 0.1)
          next unless key

          handle_key(key)
        end
      rescue Clacky::AgentInterrupted
        # Signal.trap("INT") raised AgentInterrupted on the main thread.
        # Route through the normal Ctrl+C path so on_interrupt callback fires
        # (interrupt task thread if running, or exit if idle) instead of quitting blindly.
        handle_key(:ctrl_c)
      rescue => e
        stop
        raise e
      ensure
        @layout.screen.disable_raw_mode
      end

      # Handle keyboard input - delegate to InputArea or InlineInput
      # @param key [Symbol, String, Hash] Key input or rapid input hash
      def handle_key(key)
        # If in fullscreen mode, only handle Ctrl+O to exit
        if @layout.fullscreen_mode?
          if key == :ctrl_o
            # Signal the real-time refresh thread to stop gracefully, then join it.
            # Avoid Thread#kill which can interrupt the thread mid-render and
            # leave @render_mutex permanently locked.
            stop_fullscreen_refresh_thread
            @layout.exit_fullscreen
            # Restore main screen content after returning from alternate buffer
            @layout.rerender_all
          end
          return
        end

        # If InlineInput is active, delegate to it
        if @inline_input&.active?
          handle_inline_input_key(key)
          return
        end

        result = @input_area.handle_key(key)

        # Handle height change first
        if result[:height_changed]
          @layout.recalculate_layout
        end

        # Handle actions
        case result[:action]
        when :submit
          handle_submit(result[:data])
        when :exit
          stop
          exit(0)
        when :interrupt
          # Stop all active progress indicators (ticker threads + entries).
          # An interrupt may happen at any point in a nested flow (e.g.
          # idle compression during a task); finish the whole stack from
          # top to bottom so nothing is left running.
          interrupt_all_progress

          # Check if input area has content
          input_was_empty = @input_area.empty?

          # Notify CLI to handle interrupt (stop agent or exit)
          @interrupt_callback&.call(input_was_empty: input_was_empty)
        when :clear_output
          # Pass to callback with data for display
          @input_callback&.call("/clear", [], display: result[:data][:display])
        when :scroll_up
          @layout.scroll_output_up
        when :scroll_down
          @layout.scroll_output_down
        when :help
          # Pass to callback with data for display
          @input_callback&.call("/help", [], display: result[:data][:display])
        when :toggle_mode
          toggle_mode
        when :toggle_expand
          # If there's command output available, show it; otherwise show diff
          if @stdout_lines && !@stdout_lines.empty?
            show_command_output
          else
            redisplay_diff
          end
        when :time_machine
          # Trigger time machine callback
          @time_machine_callback&.call
        end

        # Always re-render input area after key handling
        @layout.render_input
      end

      # Handle key input for InlineInput
      def handle_inline_input_key(key)
        # Get old line count BEFORE modification
        old_line_count = @inline_input.line_count

        result = @inline_input.handle_key(key)

        case result[:action]
        when :update
          # Update the output area with current input (considering wrapped lines)
          @layout.update_last_line(@inline_input.render, old_line_count)
          # Position cursor for inline input
          @layout.position_inline_input_cursor(@inline_input)
        when :submit, :cancel
          # InlineInput is done, will be cleaned up by request_confirmation after collect returns
          # Don't render anything here - let request_confirmation handle cleanup
          return
        when :toggle_expand
          # If there's command output available, show it; otherwise show diff
          if @stdout_lines && !@stdout_lines.empty?
            show_command_output
          else
            redisplay_diff
          end
        when :toggle_mode
          # Update mode and session bar info, but don't render yet
          current_mode = @config[:mode]
          new_mode = case current_mode.to_s
          when /confirm_safes/
            "auto_approve"
          when /auto_approve/
            "confirm_safes"
          else
            "auto_approve"
          end

          @config[:mode] = new_mode
          @mode_toggle_callback&.call(new_mode)

          # Update session bar data (will be rendered by request_confirmation's render_all)
          @input_area.update_sessionbar(
            working_dir: @config[:working_dir],
            mode: @config[:mode],
            model: @config[:model],
            tasks: @tasks_count,
            cost: @total_cost
          )
        end
      end

      # Handle submit action
      private def handle_submit(data)
        # If any progress indicator is currently active (e.g. an idle-compression
        # :quiet handle running in the background), finish them all top-to-bottom
        # so no ticker thread is left writing into the buffer while we render
        # the new user message. Each handle's finish() renders its own final
        # frame with elapsed time, so the user still sees a summary.
        interrupt_all_progress if progress_active?

        # Also clear stdout buffer used by Ctrl+O (unrelated to progress, but
        # we don't want stale command output carried across user turns).
        @stdout_lines = nil

        # Render user message immediately before running agent
        unless data[:text].empty? && data[:files].empty?
          output = @renderer.render_user_message(data[:text], files: data[:files])
          append_output(output)
        end

        # Then call callback (allows interrupting previous agent before processing new input)
        @input_callback&.call(data[:text], data[:files])
      end

      # Show configuration modal dialog with multi-model support
      # @param current_config [Clacky::AgentConfig] Current configuration object
      # @return [Hash, nil] Hash with updated config values, or nil if cancelled
      public def show_config_modal(current_config, test_callback: nil)
        modal = Components::ModalComponent.new
        
        loop do
          # Build menu choices
          choices = []
          
          # Add model list
          current_config.models.each_with_index do |model, idx|
            is_current = (idx == current_config.current_model_index)
            model_name = model["model"] || "unnamed"
            masked_key = mask_api_key(model["api_key"])
            
            # Add type badge if present
            type_badge = case model["type"]
                        when "default" then "[default] "
                        when "lite" then "[lite] "
                        else ""
                        end
            
            display_name = "#{type_badge}#{model_name} (#{masked_key})"
            choices << {
              name: display_name,
              value: { action: :switch, model_id: model["id"] }
            }
          end
          
          # Add action buttons
          choices << { name: "─" * 50, disabled: true }
          choices << { name: "[+] Add New Model", value: { action: :add } }
          choices << { name: "[*] Edit Current Model", value: { action: :edit } }
          choices << { name: "[-] Delete Model", value: { action: :delete } } if current_config.models.length > 1
          choices << { name: "[X] Close", value: { action: :close } }
          
          # Show menu
          result = modal.show(
            title: "Model Configuration", 
            choices: choices,
            on_close: -> { @layout.rerender_all }
          )
          
          return nil if result.nil?
          
          case result[:action]
          when :switch
            # Just signal the caller which model to switch to.
            # All side effects (agent.switch_model_by_id to rebuild the Client,
            # set_default_model_by_id, persistence) are done by the CLI layer
            # in handle_config_command — this keeps show_config_modal a pure
            # UI component and avoids the modal half-mutating config while
            # the agent's @client still points at the old credentials.
            return { action: :switch, model_id: result[:model_id] }
          when :add
            new_model = show_model_edit_form(nil, test_callback: test_callback)
            if new_model
              # Determine anthropic_format based on provider
              # For Anthropic provider, use Anthropic API format
              anthropic_format = new_model[:provider] == "anthropic"

              current_config.add_model(
                model: new_model[:model],
                api_key: new_model[:api_key],
                base_url: new_model[:base_url],
                anthropic_format: anthropic_format
              )
              # Hand off the new model's stable id to the caller. CLI layer
              # decides whether to switch to it / mark default / persist.
              new_id = current_config.models.last["id"]
              return { action: :add, model_id: new_id }
            end
          when :edit
            current_model = current_config.current_model
            edited = show_model_edit_form(current_model, test_callback: test_callback)
            if edited
              # Update current model in place (keep anthropic_format unchanged).
              # Because we mutate the same hash that's in @models, the model's
              # stable id is preserved — the caller will rebuild the agent's
              # Client by calling agent.switch_model_by_id with the same id,
              # which reruns the Bedrock/anthropic/api_key detection.
              current_model["api_key"] = edited[:api_key]
              current_model["model"] = edited[:model]
              current_model["base_url"] = edited[:base_url]
              return { action: :edit, model_id: current_model["id"] }
            end
          when :delete
            if current_config.models.length <= 1
              # Can't delete - show error and continue
              next
            end

            # Delete current model — this clears @current_model_id so the
            # next current_model lookup picks type:default or index fallback.
            current_config.remove_model(current_config.current_model_index)
            # New current model id after deletion (may be nil briefly; resolved
            # on next current_model call, which also re-anchors @current_model_id).
            new_current = current_config.current_model
            return { action: :delete, model_id: new_current && new_current["id"] }
          when :close
            # Just close the modal
            return nil
          end
        end
      end

      # Show time machine menu for task undo/redo
      # @param history [Array<Hash>] Task history with format: [{task_id, summary, status, has_branches}]
      # @return [Integer, nil] Selected task ID or nil if cancelled
      public def show_time_machine_menu(history)
        modal = Components::ModalComponent.new
        
        # Build menu choices from history
        choices = history.map do |task|
          # Build visual indicator
          indicator = if task[:status] == :current
            "→ "  # Current task
          elsif task[:status] == :future
            "↯ "  # Future task (after undo)
          else
            "  "  # Past task
          end
          
          # Add branch indicator
          indicator += "⎇ " if task[:has_branches]
          
          # Truncate summary to fit on screen
          max_summary_length = 60
          summary = task[:summary]
          if summary.length > max_summary_length
            summary = summary[0...max_summary_length] + "..."
          end
          
          {
            name: "#{indicator}Task #{task[:task_id]}: #{summary}",
            value: task[:task_id]
          }
        end
        
        # Show modal
        result = modal.show(
          title: "Time Machine - Select Task to Navigate",
          choices: choices,
          on_close: -> { @layout.rerender_all }
        )
        
        result # Return selected task_id or nil
      end
      
      # Show form for editing a model
      # @param model [Hash, nil] Existing model hash or nil for new model
      # @return [Hash, nil] Updated model hash or nil if cancelled
      private def show_model_edit_form(model, test_callback: nil)
        modal = Components::ModalComponent.new
        
        is_new = model.nil?
        model ||= {}
        
        # For new models, show provider selection first
        selected_provider = nil
        if is_new
          # Build provider choices
          provider_choices = Clacky::Providers.list.map do |id, name|
            { name: name, value: id }
          end
          provider_choices << { name: "─" * 40, disabled: true }
          provider_choices << { name: "Custom (manual configuration)", value: "custom" }
          
          # Show provider selection
          selected_provider = modal.show(
            title: "Select Provider",
            choices: provider_choices,
            on_close: -> { @layout.rerender_all }
          )
          
          # User cancelled
          return nil if selected_provider.nil?
        end
        
        # Prepare masked API key for display
        masked_key = mask_api_key(model["api_key"])
        
        # Pre-fill values from provider preset if selected
        provider_preset = nil
        if selected_provider && selected_provider != "custom"
          provider_preset = Clacky::Providers.get(selected_provider)
        end
        
        # Get default values from provider or existing model
        default_model = provider_preset ? provider_preset["default_model"] : model["model"]
        default_base_url = provider_preset ? provider_preset["base_url"] : model["base_url"]
        default_api_key = model["api_key"] || ""
        
        # Define fields
        fields = [
          {
            name: :api_key,
            label: "API Key #{is_new ? '' : "(current: #{masked_key})"}:",
            default: "",
            mask: true
          },
          {
            name: :model,
            label: "Model #{is_new && default_model ? "(default: #{default_model})" : (is_new ? '' : "(current: #{model['model']})")}:",
            default: default_model || ""
          },
          {
            name: :base_url,
            label: "Base URL #{is_new && default_base_url ? "(default: #{default_base_url})" : (is_new ? '' : "(current: #{model['base_url']})")}:",
            default: default_base_url || ""
          }
        ]
        
        # Create validator if test_callback provided
        validator = if test_callback
          lambda do |values|
            # Merge values: use user input if provided, otherwise keep existing model value
            api_key = values[:api_key].to_s.empty? ? model["api_key"] : values[:api_key]
            model_name = values[:model].to_s.empty? ? model["model"] : values[:model]
            base_url = values[:base_url].to_s.empty? ? model["base_url"] : values[:base_url]
            anthropic_format = model["anthropic_format"] # Not editable in form, use model's value
            
            test_config_values = {
              "api_key" => api_key,
              "model" => model_name,
              "base_url" => base_url,
              "anthropic_format" => anthropic_format
            }
            
            # For new models, require all fields
            if is_new
              if test_config_values["api_key"].to_s.empty?
                return { success: false, error: "API Key is required for new model" }
              end
              if test_config_values["model"].to_s.empty?
                return { success: false, error: "Model name is required" }
              end
              if test_config_values["base_url"].to_s.empty?
                return { success: false, error: "Base URL is required" }
              end
            end
            
            # Create a temporary config for testing
            temp_config = Clacky::AgentConfig.new(models: [test_config_values], current_model_index: 0)
            test_callback.call(temp_config)
          end
        else
          nil
        end
        
        # Determine modal title based on provider
        modal_title = if is_new && selected_provider && selected_provider != "custom"
          provider_name = Clacky::Providers.get(selected_provider)&.dig("name") || selected_provider
          "Add #{provider_name} Model"
        elsif is_new
          "Add Custom Model"
        else
          "Edit Model"
        end
        
        # Show modal and collect values
        result = modal.show(
          title: modal_title,
          fields: fields,
          validator: validator,
          on_close: -> { @layout.rerender_all }
        )
        
        return nil if result.nil?
        
        # Merge with existing model values or provider defaults
        {
          api_key: result[:api_key].to_s.empty? ? model["api_key"] : result[:api_key],
          model: result[:model].to_s.empty? ? (model["model"] || default_model) : result[:model],
          base_url: result[:base_url].to_s.empty? ? (model["base_url"] || default_base_url) : result[:base_url],
          provider: selected_provider
        }
      end
      
      # Mask API key for display
      private def mask_api_key(api_key)
        if api_key && !api_key.empty?
          "#{api_key[0..5]}...#{api_key[-4..]}"
        else
          "not set"
        end
      end
    end
  end
end
