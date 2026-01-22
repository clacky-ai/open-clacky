# frozen_string_literal: true

require_relative "screen_buffer"

module Clacky
  module UI2
    # LayoutManager manages screen layout with split areas (output area on top, input area on bottom)
    class LayoutManager
      attr_reader :screen, :output_area, :input_area, :todo_area

      def initialize(output_area:, input_area:, todo_area: nil)
        @screen = ScreenBuffer.new
        @output_area = output_area
        @input_area = input_area
        @todo_area = todo_area
        @render_mutex = Mutex.new
        @output_row = 0  # Track current output row position

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
        @output_area.height = @output_height
        @input_area.row = @input_row
      end

      # Recalculate layout (called when input height changes)
      def recalculate_layout
        @render_mutex.synchronize do
          old_input_row = @input_row
          calculate_layout

          # If layout changed, need to re-render
          if @input_row != old_input_row
            screen.clear_screen
            render_all_internal
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
          input_row = fixed_area_start_row + 1 + (@todo_area&.height || 0)
          input_area.render(start_row: input_row, width: screen.width)
          screen.flush
        end
      end

      # Position cursor for inline input in output area
      # @param inline_input [Components::InlineInput] InlineInput component
      def position_inline_input_cursor(inline_input)
        return unless inline_input

        # Cursor is at the last line of output area
        # Calculate which row that is based on visible lines
        visible_range = output_area.visible_range
        last_visible_row = [visible_range[:end] - 1, 0].max
        cursor_row = [last_visible_row, @output_height - 1].min
        cursor_col = inline_input.cursor_col

        screen.move_cursor(cursor_row, cursor_col)
        screen.show_cursor
        screen.flush
      end

      # Update todos and re-render
      # @param todos [Array<Hash>] Array of todo items
      def update_todos(todos)
        return unless @todo_area

        @render_mutex.synchronize do
          old_height = @todo_area.height
          @todo_area.update(todos)
          new_height = @todo_area.height

          # Recalculate layout if height changed
          if old_height != new_height
            calculate_layout
            screen.clear_screen
          end

          render_all_internal
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
        screen.move_cursor(screen.height - 1, 0)
        screen.show_cursor
      end

      # Append content to output area
      # Track current row, scroll when reaching fixed area
      # @param content [String] Content to append
      def append_output(content)
        return if content.nil? || content.empty?

        @render_mutex.synchronize do
          max_output_row = fixed_area_start_row - 1

          content.split("\n").each do |line|
            # If at max row, need to scroll before outputting
            if @output_row > max_output_row
              # Move to bottom of screen and print newline to trigger scroll
              screen.move_cursor(screen.height - 1, 0)
              print "\n"
              # Stay at max_output_row for next output
              @output_row = max_output_row
            end

            # Output line at current position
            screen.move_cursor(@output_row, 0)
            screen.clear_line
            output_area.append(line)
            @output_row += 1
          end

          # Re-render fixed areas at screen bottom
          render_fixed_areas
          screen.flush
        end
      end

      # Update the last line in output area (for progress indicator)
      # @param content [String] Content to update
      def update_last_line(content)
        @render_mutex.synchronize do
          # Last output line is at @output_row - 1
          last_row = [@output_row - 1, 0].max
          screen.move_cursor(last_row, 0)
          screen.clear_line
          output_area.append(content)
          render_fixed_areas
          screen.flush
        end
      end

      # Remove the last line from output area
      def remove_last_line
        @render_mutex.synchronize do
          last_row = [@output_row - 1, 0].max
          screen.move_cursor(last_row, 0)
          screen.clear_line
          @output_row = last_row if @output_row > 0
          render_fixed_areas
          screen.flush
        end
      end

      # Scroll output area up
      # @param lines [Integer] Number of lines to scroll
      def scroll_output_up(lines = 1)
        output_area.scroll_up(lines)
        render_output
      end

      # Scroll output area down
      # @param lines [Integer] Number of lines to scroll
      def scroll_output_down(lines = 1)
        output_area.scroll_down(lines)
        render_output
      end

      # Handle window resize
      def handle_resize
        screen.update_dimensions
        calculate_layout
        # Adjust output_row if it exceeds new max
        max_row = fixed_area_start_row - 1
        @output_row = max_row if @output_row > max_row
        screen.clear_screen
        render_all
      end

      private

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
        start_row = fixed_area_start_row
        gap_row = start_row
        todo_row = gap_row + 1
        input_row = todo_row + (@todo_area&.height || 0)

        # Render gap line
        screen.move_cursor(gap_row, 0)
        screen.clear_line

        # Render todo
        if @todo_area&.visible?
          @todo_area.render(start_row: todo_row)
        end

        # Render input
        input_area.render(start_row: input_row, width: screen.width)
        unless input_area.paused?
          screen.show_cursor
        end
      end

      # Internal render all (without mutex)
      def render_all_internal
        output_area.render(start_row: 0)
        render_fixed_areas
        screen.flush
      end

      # Restore cursor to input area
      def restore_cursor_to_input
        input_row = fixed_area_start_row + 1 + (@todo_area&.height || 0)
        input_area.position_cursor(input_row)
        screen.show_cursor
      end

      # Setup handler for window resize
      def setup_resize_handler
        Signal.trap("WINCH") do
          handle_resize
        end
      rescue ArgumentError
        # Signal already trapped, ignore
      end
    end
  end
end
