# frozen_string_literal: true

require_relative "layout_manager"
require_relative "view_renderer"
require_relative "components/input_area"
require_relative "components/todo_area"
require_relative "components/welcome_banner"
require_relative "components/inline_input"
require_relative "../thinking_verbs"

module Clacky
  module UI2
    # UIController is the MVC controller layer that coordinates UI state and user interactions
    class UIController
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
        @tasks_count = 0
        @total_cost = 0.0
        @progress_thread = nil
        @progress_start_time = nil
        @progress_message = nil
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

      # Update session bar with current stats
      # @param tasks [Integer] Number of completed tasks (optional)
      # @param cost [Float] Total cost (optional)
      # @param status [String] Workspace status ('idle' or 'working') (optional)
      def update_sessionbar(tasks: nil, cost: nil, status: nil)
        @tasks_count = tasks if tasks
        @total_cost = cost if cost
        @input_area.update_sessionbar(
          working_dir: @config[:working_dir],
          mode: @config[:mode],
          model: @config[:model],
          tasks: @tasks_count,
          cost: @total_cost,
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

      # Set skill loader for command suggestions
      # @param skill_loader [Clacky::SkillLoader] The skill loader instance
      def set_skill_loader(skill_loader)
        @input_area.set_skill_loader(skill_loader)
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

      # Update the last line in output area (for progress indicator)
      # @param content [String] Content to update
      def update_progress_line(content)
        @layout.update_last_line(content)
      end

      # Clear the progress line (remove last line)
      def clear_progress_line
        @layout.remove_last_line
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
        if token_data[:cost]
          cost = token_data[:cost]
          cost_value = "$#{cost.round(6)}"
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

      # Show user message
      # @param content [String] Message content
      # @param images [Array] Image paths (optional)
      def show_user_message(content, images: [])
        output = @renderer.render_user_message(content)
        append_output(output)
      end

      # Show assistant message
      # @param content [String] Message content
      def show_assistant_message(content)
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
      # @param prefix_newline [Boolean] Whether to add a blank line before progress (default: true)
      def show_progress(message = nil, prefix_newline: true)
        # Stop any existing progress thread
        stop_progress_thread

        # Update status to 'working'
        update_sessionbar(status: 'working')

        @progress_message = message || Clacky::THINKING_VERBS.sample
        @progress_start_time = Time.now

        # Show initial progress (yellow, active)
        append_output("") if prefix_newline
        output = @renderer.render_working("#{@progress_message}… (ctrl+c to interrupt)")
        append_output(output)

        # Start background thread to update elapsed time
        @progress_thread = Thread.new do
          while @progress_start_time
            sleep 0.5
            next unless @progress_start_time

            elapsed = (Time.now - @progress_start_time).to_i
            update_progress_line(@renderer.render_working("#{@progress_message}… (ctrl+c to interrupt · #{elapsed}s)"))
          end
        rescue => e
          # Silently handle thread errors
        end
      end

      # Clear progress indicator
      def clear_progress
        # Calculate elapsed time before stopping
        elapsed_time = @progress_start_time ? (Time.now - @progress_start_time).to_i : 0

        # Stop the progress thread
        stop_progress_thread

        # Update the final progress line to gray (stopped state)
        if @progress_message && elapsed_time > 0
          final_output = @renderer.render_progress("#{@progress_message}… (#{elapsed_time}s)")
          update_progress_line(final_output)
        else
          clear_progress_line
        end
      end

      # Stop the progress update thread
      def stop_progress_thread
        @progress_start_time = nil
        if @progress_thread&.alive?
          @progress_thread.kill
          @progress_thread = nil
        end
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
        append_output("\n#{question_symbol} #{message}")

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
        @layout.append_output(inline_input.render)
        @layout.position_inline_input_cursor(inline_input)

        # Collect input (blocks until user presses Enter)
        result_text = inline_input.collect

        # Clean up - remove the inline input lines (handle wrapped lines)
        line_count = inline_input.line_count
        @layout.remove_last_line(line_count)

        # Append the final response to output
        if result_text.nil?
          append_output(theme.format_text("  [Cancelled]", :error))
        else
          display_text = result_text.empty? ? (default ? "y" : "n") : result_text
          append_output(theme.format_text("  #{display_text}", :success))
        end

        # Deactivate and clean up
        @inline_input = nil
        @input_area.resume
        @layout.recalculate_layout
        @layout.render_all

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

        # Show diff without line numbers
        diff_lines.take(max_lines).each do |line|
          append_output(line.chomp)
        end

        if diff_lines.size > max_lines
          append_output("\n... (#{diff_lines.size - max_lines} more lines, diff truncated)")
        end
      rescue LoadError
        # Fallback if diffy is not available
        append_output("   Old size: #{old_content.bytesize} bytes")
        append_output("   New size: #{new_content.bytesize} bytes")
      end

      private

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
          mode: @config[:mode]
        )
        append_output(content)

        # Check if API key is configured
        check_api_key_configuration
      end

      # Check if API key is configured and show warning if missing
      private def check_api_key_configuration
        config = Clacky::Config.load
        
        if config.api_key.nil? || config.api_key.empty?
          show_warning("API key is not configured! Please run /config to set up your API key.")
        end
      end

      # Display recent user messages when loading session
      # @param user_messages [Array<String>] Array of recent user message texts
      def display_session_history(user_messages)
        theme = ThemeManager.current_theme

        # Show logo banner only
        append_output(@welcome_banner.render_logo)

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
          key = @layout.screen.read_key(timeout: 0.1)
          next unless key

          handle_key(key)
        end
      rescue => e
        stop
        raise e
      ensure
        @layout.screen.disable_raw_mode
      end

      # Handle keyboard input - delegate to InputArea or InlineInput
      # @param key [Symbol, String, Hash] Key input or rapid input hash
      def handle_key(key)
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
          # Stop progress indicator
          stop_progress_thread

          # Check if input area has content
          input_was_empty = @input_area.empty?

          # Notify CLI to handle interrupt (stop agent or exit)
          @interrupt_callback&.call(input_was_empty: input_was_empty)
        when :clear_output
          # Clear the screen
          @layout.clear_output
          # Notify the callback to reset session/agent
          @input_callback&.call("/clear", [])
        when :scroll_up
          @layout.scroll_output_up
        when :scroll_down
          @layout.scroll_output_down
        when :help
          show_help
          @input_area.clear
        when :toggle_mode
          toggle_mode
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
          nil
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
        # Call callback first (allows interrupting previous agent before showing new input)
        @input_callback&.call(data[:text], data[:images])

        # Append the input content to output area after callback completes
        @layout.append_output(data[:display]) unless data[:display].empty?
      end

      # Show configuration modal dialog
      # @param current_config [Clacky::Config] Current configuration object
      # @return [Hash, nil] Hash with updated config values, or nil if cancelled
      public def show_config_modal(current_config)
        modal = Components::ModalComponent.new

        # Prepare masked API key for display
        masked_key = if current_config.api_key && !current_config.api_key.empty?
          "#{current_config.api_key[0..7]}#{'*' * 20}#{current_config.api_key[-4..]}"
        else
          "not set"
        end

        # Define fields
        fields = [
          {
            name: :api_key,
            label: "API Key (current: #{masked_key}):",
            default: "",
            mask: true
          },
          {
            name: :model,
            label: "Model (current: #{current_config.model}):",
            default: ""
          },
          {
            name: :base_url,
            label: "Base URL (current: #{current_config.base_url}):",
            default: ""
          }
        ]

        # Show modal and collect values
        modal.show(title: "Configuration", fields: fields)
      end
    end
  end
end
