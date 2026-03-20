# frozen_string_literal: true

require_relative "screen_buffer"
require_relative "../utils/limit_stack"
require_relative "../utils/encoding"

module Clacky
  module UI2
    # LayoutManager manages screen layout with split areas (output area on top, input area on bottom)
    class LayoutManager
      attr_reader :screen, :input_area, :todo_area

      def initialize(input_area:, todo_area: nil)
        @screen = ScreenBuffer.new
        @input_area = input_area
        @todo_area = todo_area
        @render_mutex = Mutex.new
        @output_row = 0  # Track current output row position
        @last_fixed_area_height = 0  # Track previous fixed area height to detect shrinkage
        @fullscreen_mode = false  # Track if in fullscreen mode
        @resize_pending = false  # Flag to indicate resize is pending
        @output_buffer = Utils::LimitStack.new(max_size: 500)  # Buffer to store output lines with auto-rolling

        calculate_layout
        setup_resize_handler
      end

      # Calculate layout dimensions based on screen size and component heights
      def calculate_layout
        todo_height = @todo_area&.height || 0
        input_height = @input_area.required_height
        gap_height = 1  # Blank line between output and input

        # Layout: output -> gap -> todo -> input (with its own separators and status)
        @output_height = screen.height - gap_height - todo_height - input_height
        @output_height = [1, @output_height].max  # Minimum 1 line for output

        @gap_row = @output_height
        @todo_row = @gap_row + gap_height
        @input_row = @todo_row + todo_height

        # Update component dimensions
        @input_area.row = @input_row
      end

      # Recalculate layout (called when input height changes)
      def recalculate_layout
        @render_mutex.synchronize do
          # Save old layout values before recalculating
          old_gap_row = @gap_row  # This is the old fixed_area_start
          old_input_row = @input_row

          calculate_layout

          # If layout changed, clear old fixed area and re-render at new position
          if @input_row != old_input_row
            # Clear old fixed area lines (from old gap_row to screen bottom)
            ([old_gap_row, 0].max...screen.height).each do |row|
              screen.move_cursor(row, 0)
              screen.clear_line
            end

            # When input is paused (InlineInput active), fixed_area_start_row has grown
            # (input_area.required_height returns 0 while paused), so the cleared rows
            # now belong to the output area. Re-render output from buffer to fill them in.
            if input_area.paused?
              render_output_from_buffer
            else
              # Re-render fixed areas at new position
              render_fixed_areas
            end
            screen.flush
          end
        end
      end

      # Render all layout areas
      def render_all
        @render_mutex.synchronize do
          render_all_internal
        end
      end

      # Render output area - with native scroll, just ensure input stays in place
      def render_output
        @render_mutex.synchronize do
          # Output is written directly, just need to re-render fixed areas
          render_fixed_areas
          screen.flush
        end
      end

      # Render just the input area
      def render_input
        @render_mutex.synchronize do
          # Clear and re-render entire fixed area to ensure consistency
          render_fixed_areas
          screen.flush
        end
      end

      # Re-render everything from scratch (useful after modal dialogs)
      def rerender_all
        @render_mutex.synchronize do
          # Clear entire screen
          screen.clear_screen

          # Re-render output from buffer
          render_output_from_buffer

          # Re-render fixed areas at new positions
          render_fixed_areas
          screen.flush
        end
      end

      # Render output area from buffer (clears and re-renders last N lines)
      private def render_output_from_buffer
        max_output_row = fixed_area_start_row

        # Clear output area
        (0...max_output_row).each do |row|
          screen.move_cursor(row, 0)
          screen.clear_line
        end

        # Re-render from buffer (show last N lines that fit)
        @output_row = 0
        visible_lines = [@output_buffer.size, max_output_row].min

        @output_buffer.last(visible_lines).each do |line|
          screen.move_cursor(@output_row, 0)
          print line
          @output_row += 1
        end
      end

      # Position cursor for inline input in output area
      # @param inline_input [Components::InlineInput] InlineInput component
      def position_inline_input_cursor(inline_input)
        return unless inline_input

        # Use InlineInput's method to calculate cursor position (handles continuation prompt correctly)
        width = screen.width
        wrap_row, wrap_col = inline_input.cursor_position_for_display(width)

        # Get the number of lines InlineInput occupies (considering wrapping)
        line_count = inline_input.line_count(width)

        # InlineInput starts at @output_row - line_count
        # Cursor is at wrap_row within that
        cursor_row = @output_row - line_count + wrap_row
        cursor_col = wrap_col

        # Move terminal cursor to the correct position
        screen.move_cursor(cursor_row, cursor_col)
        screen.flush
      end

      # Update todos and re-render
      # @param todos [Array<Hash>] Array of todo items
      def update_todos(todos)
        return unless @todo_area

        @render_mutex.synchronize do
          old_height = @todo_area.height
          old_gap_row = @gap_row

          @todo_area.update(todos)
          new_height = @todo_area.height

          # Recalculate layout if height changed
          if old_height != new_height
            calculate_layout

            # Clear old fixed area lines (from old gap_row to screen bottom)
            ([old_gap_row, 0].max...screen.height).each do |row|
              screen.move_cursor(row, 0)
              screen.clear_line
            end
          end

          # Render fixed areas at new position
          render_fixed_areas
          screen.flush
        end
      end

      # Initialize the screen (render initial content)
      def initialize_screen
        screen.clear_screen
        screen.hide_cursor
        @output_row = 0
        render_all
      end

      # Cleanup the screen (restore cursor)
      def cleanup_screen
        @render_mutex.synchronize do
          # Clear fixed areas (gap + todo + input)
          fixed_start = fixed_area_start_row
          (fixed_start...screen.height).each do |row|
            screen.move_cursor(row, 0)
            screen.clear_line
          end

          # Move cursor to start of a new line after last output
          # Use \r to ensure we're at column 0, then move down
          screen.move_cursor([@output_row, 0].max, 0)
          print "\r"  # Carriage return to column 0
          screen.show_cursor
          screen.flush
        end
      end

      # Clear output area (for /clear command)
      def clear_output
        @render_mutex.synchronize do
          # Clear all lines in output area (from 0 to where fixed area starts)
          max_row = fixed_area_start_row
          (0...max_row).each do |row|
            screen.move_cursor(row, 0)
            screen.clear_line
          end

          # Reset output position to beginning
          @output_row = 0

          # Clear the output buffer so re-renders don't restore old content
          @output_buffer.clear

          # Re-render fixed areas to ensure they stay in place
          render_fixed_areas
          screen.flush
        end
      end

      # Append content to output area
      # This is the main output method - handles scrolling and fixed area preservation
      # @param content [String] Content to append (can be multi-line)
      def append_output(content)
        return if content.nil?

        # Scrub any invalid byte sequences before they reach the render pipeline.
        # wrap_long_line calls each_char which raises ArgumentError on invalid UTF-8.
        content = Clacky::Utils::Encoding.sanitize_utf8(content) unless content.valid_encoding?

        @render_mutex.synchronize do
          lines = content.split("\n", -1)  # -1 to keep trailing empty strings

          lines.each_with_index do |line, index|
            # Wrap long lines to prevent display issues
            wrapped_lines = wrap_long_line(line)

            wrapped_lines.each do |wrapped_line|
              write_output_line(wrapped_line)
            end
          end

          # Re-render fixed areas to ensure they stay at bottom
          render_fixed_areas
          screen.flush
        end
      end

      # Update the last N lines in output area (for inline input updates)
      # @param content [String] Content to update (may contain newlines for wrapped lines)
      # @param old_line_count [Integer] Number of lines currently occupied (for clearing)
      def update_last_line(content, old_line_count = 1)
        @render_mutex.synchronize do
          # Fullscreen owns the alternate screen; skip main-screen updates
          return if @fullscreen_mode

          return if @output_row == 0  # No output yet

          lines = content.split("\n", -1)
          new_line_count = lines.length

          # Calculate start row (last N lines)
          start_row = @output_row - old_line_count
          start_row = 0 if start_row < 0

          # If lines grew, check if we would overflow into the fixed area and scroll if needed
          if new_line_count > old_line_count
            max_output_row = fixed_area_start_row
            needed_end_row = start_row + new_line_count

            if needed_end_row > max_output_row
              # Calculate how many extra rows we need
              overflow = needed_end_row - max_output_row

              # Scroll the terminal by printing newlines at the bottom of the output area
              overflow.times do
                screen.move_cursor(screen.height - 1, 0)
                print "\n"
              end

              # Adjust start_row and output_row upward after scroll
              start_row -= overflow
              start_row = 0 if start_row < 0
              @output_row = [start_row + old_line_count, max_output_row].min

              # Re-render fixed areas after scroll to prevent corruption
              render_fixed_areas
            end
          end

          # Clear all lines that will be updated
          (start_row...@output_row).each do |row|
            screen.move_cursor(row, 0)
            screen.clear_line
          end

          # Remove old lines from buffer
          old_line_count.times do
            @output_buffer.pop if @output_buffer.size > 0
          end

          # Re-render the content
          current_row = start_row

          lines.each do |line|
            screen.move_cursor(current_row, 0)
            print line
            # Add updated line to buffer
            @output_buffer << line
            current_row += 1
          end

          # Update output_row to new line count
          @output_row = start_row + new_line_count

          # Clear any remaining old lines if new content has fewer lines
          # This handles the case where content shrinks (e.g., delete from 2 lines to 1 line)
          old_end_row = @output_row + (old_line_count - new_line_count)
          if old_end_row > @output_row && old_end_row <= start_row + old_line_count
            # Clear the extra old lines
            (@output_row...old_end_row).each do |row|
              screen.move_cursor(row, 0)
              screen.clear_line
            end
          end

          # Re-render fixed areas to restore cursor position in input area
          render_fixed_areas
          screen.flush
        end
      end

      # Remove the last N lines from output area
      # @param line_count [Integer] Number of lines to remove (default: 1)
      def remove_last_line(line_count = 1)
        @render_mutex.synchronize do
          # Fullscreen owns the alternate screen; skip main-screen updates
          return if @fullscreen_mode

          return if @output_row == 0  # No output to remove

          # Calculate start row for removal
          start_row = @output_row - line_count
          start_row = 0 if start_row < 0

          # Clear all lines being removed
          (start_row...@output_row).each do |row|
            screen.move_cursor(row, 0)
            screen.clear_line
          end

          # Also remove from output buffer to prevent re-rendering
          line_count.times do
            @output_buffer.pop if @output_buffer.size > 0
          end

          # Update output_row
          @output_row = start_row

          # Re-render fixed areas to ensure consistency
          render_fixed_areas
          screen.flush
        end
      end

      # Scroll output area up (legacy no-op)
      # @param lines [Integer] Number of lines to scroll
      def scroll_output_up(lines = 1)
        # No-op - terminal handles scrolling natively
      end

      # Scroll output area down (legacy no-op)
      # @param lines [Integer] Number of lines to scroll
      def scroll_output_down(lines = 1)
        # No-op - terminal handles scrolling natively
      end

      # Handle window resize
      private def handle_resize
        # Record old dimensions before updating to detect shrink vs grow
        old_height = screen.height
        old_width = screen.width

        # Update terminal dimensions and recalculate layout
        screen.update_dimensions
        calculate_layout

        # When shrinking: full reset (clears scrollback too), otherwise just clear current screen
        shrinking = screen.height < old_height || screen.width < old_width
        screen.clear_screen(mode: shrinking ? :reset : :current)

        # Re-render all output from buffer
        @output_row = 0
        max_output_row = fixed_area_start_row

        # Calculate how many lines we can show from the end of buffer
        visible_lines = [@output_buffer.size, max_output_row].min

        # Render the last N lines that fit in the output area
        @output_buffer.last(visible_lines).each do |line|
          screen.move_cursor(@output_row, 0)
          print line
          @output_row += 1
        end

        # Sync @last_fixed_area_height so render_fixed_areas won't think the height
        # changed and trigger a second render_output_from_buffer call
        @last_fixed_area_height = fixed_area_height

        # Re-render fixed areas at new positions
        render_fixed_areas
        screen.flush
      end

      # Write a single line to output area
      # Handles scrolling when reaching fixed area
      # @param line [String] Single line to write (should not contain newlines)
      def write_output_line(line)
        # Add to buffer so content is available when returning from fullscreen
        @output_buffer << line

        # Fullscreen owns the alternate screen; skip rendering to avoid corruption
        return if @fullscreen_mode

        # Calculate where fixed area starts (this is where output area ends)
        max_output_row = fixed_area_start_row

        # If we're about to write into the fixed area, scroll first
        if @output_row >= max_output_row
          # Trigger terminal scroll by printing newline at bottom
          screen.move_cursor(screen.height - 1, 0)
          print "\n"

          # After scroll, position to write at the last row of output area
          @output_row = max_output_row - 1

          # Important: Re-render fixed areas after scroll to prevent corruption
          render_fixed_areas
        end

        # Now write the line at current position
        screen.move_cursor(@output_row, 0)
        screen.clear_line
        print line

        # Move to next row for next write
        @output_row += 1
      end

      # Wrap a long line into multiple lines based on terminal width
      # Considers display width of multi-byte characters (e.g., Chinese characters)
      # @param line [String] Line to wrap
      # @return [Array<String>] Array of wrapped lines
      def wrap_long_line(line)
        return [""] if line.nil? || line.empty?

        max_width = screen.width
        return [line] if max_width <= 0

        # Strip ANSI codes for width calculation
        visible_line = line.gsub(/\e\[[0-9;]*m/, '')

        # Check if line needs wrapping
        display_width = calculate_display_width(visible_line)
        return [line] if display_width <= max_width

        # Line needs wrapping - split by considering display width
        wrapped = []
        current_line = ""
        current_width = 0
        ansi_codes = []  # Track ANSI codes to carry over

        # Extract ANSI codes and text segments
        segments = line.split(/(\e\[[0-9;]*m)/)

        segments.each do |segment|
          if segment =~ /^\e\[[0-9;]*m$/
            # ANSI code - add to current codes
            ansi_codes << segment
            current_line += segment
          else
            # Text segment - process character by character
            segment.each_char do |char|
              char_width = char_display_width(char)

              if current_width + char_width > max_width && !current_line.empty?
                # Complete current line
                wrapped << current_line
                # Start new line with carried-over ANSI codes
                current_line = ansi_codes.join
                current_width = 0
              end

              current_line += char
              current_width += char_width
            end
          end
        end

        # Add remaining content
        wrapped << current_line unless current_line.empty? || current_line == ansi_codes.join

        wrapped.empty? ? [""] : wrapped
      end

      # Calculate display width of a single character
      # @param char [String] Single character
      # @return [Integer] Display width (1 or 2)
      def char_display_width(char)
        code = char.ord
        # East Asian Wide and Fullwidth characters take 2 columns
        if (code >= 0x1100 && code <= 0x115F) ||
           (code >= 0x2329 && code <= 0x232A) ||
           (code >= 0x2E80 && code <= 0x303E) ||
           (code >= 0x3040 && code <= 0xA4CF) ||
           (code >= 0xAC00 && code <= 0xD7A3) ||
           (code >= 0xF900 && code <= 0xFAFF) ||
           (code >= 0xFE10 && code <= 0xFE19) ||
           (code >= 0xFE30 && code <= 0xFE6F) ||
           (code >= 0xFF00 && code <= 0xFF60) ||
           (code >= 0xFFE0 && code <= 0xFFE6) ||
           (code >= 0x1F300 && code <= 0x1F9FF) ||
           (code >= 0x20000 && code <= 0x2FFFD) ||
           (code >= 0x30000 && code <= 0x3FFFD)
          2
        else
          1
        end
      end

      # Calculate display width of a string (considering multi-byte characters)
      # @param text [String] Text to calculate
      # @return [Integer] Display width
      def calculate_display_width(text)
        width = 0
        text.each_char do |char|
          width += char_display_width(char)
        end
        width
      end

      # Calculate fixed area height (gap + todo + input)
      def fixed_area_height
        todo_height = @todo_area&.height || 0
        input_height = @input_area.required_height
        1 + todo_height + input_height  # gap + todo + input
      end

      # Calculate the starting row for fixed areas (from screen bottom)
      def fixed_area_start_row
        screen.height - fixed_area_height
      end

      # Render fixed areas (gap, todo, input) at screen bottom
      def render_fixed_areas
        # When input is paused (InlineInput active), don't render fixed areas
        # The InlineInput is rendered inline with output
        return if input_area.paused?

        # Do not corrupt the alternate screen while in fullscreen mode
        return if @fullscreen_mode

        current_fixed_height = fixed_area_height
        start_row = fixed_area_start_row
        gap_row = start_row
        todo_row = gap_row + 1
        input_row = todo_row + (@todo_area&.height || 0)

        # Detect height changes and re-render output area if needed
        if @last_fixed_area_height > 0 && @last_fixed_area_height != current_fixed_height
          # Fixed area height changed - re-render output area from buffer
          # This prevents output content from being hidden when fixed area grows
          # (e.g., multi-line input, command suggestions appearing)
          render_output_from_buffer
        end

        # Update last height for next comparison
        @last_fixed_area_height = current_fixed_height

        # Render gap line
        screen.move_cursor(gap_row, 0)
        screen.clear_line

        # Render todo
        if @todo_area&.visible?
          @todo_area.render(start_row: todo_row)
        end

        # Render input (InputArea renders its own visual cursor via render_line_with_cursor)
        input_area.render(start_row: input_row, width: screen.width)
      end

      # Internal render all (without mutex)
      def render_all_internal
        # Output flows naturally, just render fixed areas
        render_fixed_areas
        screen.flush
      end

      # Restore cursor to input area
      def restore_cursor_to_input
        input_row = fixed_area_start_row + 1 + (@todo_area&.height || 0)
        input_area.position_cursor(input_row)
        screen.show_cursor
      end

      # Restore screen from fullscreen mode (re-render everything)
      def restore_screen
        @render_mutex.synchronize do
          screen.clear_screen
          screen.hide_cursor
          render_all_internal
        end
      end

      # Check if in fullscreen mode
      # @return [Boolean]
      def fullscreen_mode?
        @fullscreen_mode
      end

      # Enter fullscreen mode with alternate screen buffer
      # @param lines [Array<String>] Lines to display
      # @param hint [String] Hint message at bottom
      def enter_fullscreen(lines, hint: "Press Ctrl+O to return")
        @render_mutex.synchronize do
          return if @fullscreen_mode

          @fullscreen_mode = true
          @fullscreen_hint = hint

          # Enter alternate screen buffer and do a full clean:
          #   \e[?1049h  - switch to alternate screen buffer (separate from primary)
          #   \e[2J      - erase the entire visible screen
          #   \e[H       - move cursor to top-left
          # The alternate screen buffer has no scrollback history by design, so
          # there is nothing to scroll up to once we clear the visible area.
          print "\e[?1049h\e[2J\e[H"
          $stdout.flush

          render_fullscreen_content(lines)
        end
      end

      # Refresh fullscreen content in-place (for real-time updates without re-entering alt screen)
      # @param lines [Array<String>] Updated lines to display
      def refresh_fullscreen(lines)
        @render_mutex.synchronize do
          return unless @fullscreen_mode

          # Move cursor to top-left and erase visible area, then redraw
          print "\e[2J\e[H"
          render_fullscreen_content(lines)
        end
      end

      # Exit fullscreen mode and restore previous screen
      def exit_fullscreen
        @render_mutex.synchronize do
          return unless @fullscreen_mode

          @fullscreen_mode = false
          @fullscreen_hint = nil

          # Exit alternate screen buffer (automatically restores previous screen content)
          print "\e[?1049l"
          $stdout.flush
        end
      end

      # Render lines to the alternate screen (called by enter_fullscreen / refresh_fullscreen)
      # Fills the entire screen: content at top, hint pinned at the very bottom row.
      # This prevents the terminal from showing any blank scrollable area above the hint.
      # @param lines [Array<String>] Lines to render
      private def render_fullscreen_content(lines)
        term_height = screen.height
        term_width  = screen.width

        # Reserve the bottom row for the hint bar
        content_rows = term_height - 1

        # Trim or pad lines to exactly fill the content area
        display_lines = lines.first(content_rows)

        # Print each content line, padded with spaces to full terminal width so
        # no stale characters from a previous render remain on the right side.
        display_lines.each do |line|
          # Strip trailing whitespace then pad to terminal width (ignoring ANSI codes for width calc)
          visible = line.chomp.gsub(/\e\[[0-9;]*m/, "")
          padding = [term_width - visible.length, 0].max
          print line.chomp + (" " * padding) + "\r\n"
        end

        # Fill any remaining content rows with blank lines so nothing from a
        # previous render bleeds through when content shrinks.
        blank_row = " " * term_width
        (display_lines.length...content_rows).each do
          print blank_row + "\r\n"
        end

        # Pin the hint bar at the very bottom row using absolute cursor positioning.
        # \e[{row};{col}H moves to the given 1-based row/col.
        hint_text = "\e[36m#{@fullscreen_hint}\e[0m"
        print "\e[#{term_height};1H#{hint_text}\e[0K"

        $stdout.flush
      end

      # Setup handler for window resize
      # Note: Signal handlers run in trap context where many operations are restricted
      private def setup_resize_handler
        Signal.trap("WINCH") do
          # Simply set a flag - actual resize handling happens in main thread
          @resize_pending = true
        end
      rescue ArgumentError => e
        # Signal already trapped (shouldn't happen now)
        warn "WINCH signal already trapped: #{e.message}"
      end

      # Check and process pending resize (should be called from main thread periodically)
      def process_pending_resize
        return unless @resize_pending

        @resize_pending = false
        handle_resize_safely
      end

      # Thread-safe wrapper for handle_resize
      private def handle_resize_safely
        @render_mutex.synchronize do
          handle_resize
        end
      rescue => e
        # Catch and log errors to prevent resize from crashing the app
        warn "Resize error: #{e.message}"
        warn e.backtrace.first(5).join("\n") if e.backtrace
      end
    end
  end
end
