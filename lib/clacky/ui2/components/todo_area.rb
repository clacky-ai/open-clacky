# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # TodoArea displays active todos above the separator line
      class TodoArea
        attr_accessor :height
        attr_reader :todos

        MAX_DISPLAY_TASKS = 2  # Show current + next task

        def initialize
          @todos = []
          @pastel = Pastel.new
          @width = TTY::Screen.width
          @height = 0  # Dynamic height based on todos
        end

        # Update todos list
        # @param todos [Array<Hash>] Array of todo items
        def update(todos)
          @todos = todos || []
          @pending_todos = @todos.select { |t| t[:status] == "pending" }
          @completed_count = @todos.count { |t| t[:status] == "completed" }
          @total_count = @todos.size

          # Hide TODO area when there are no pending tasks
          # Show single line for current task + next task
          @height = @pending_todos.empty? ? 0 : 1
        end

        # Check if there are todos to display
        def visible?
          @height > 0
        end

        # Render todos area
        # @param start_row [Integer] Screen row to start rendering
        def render(start_row:)
          return unless visible?

          update_width

          move_cursor(start_row, 0)
          clear_line

          # Build single line: [##] Task [2/4]: #3 - Current task (Next: #4 - Next task)
          progress = "#{@completed_count}/#{@total_count}"
          current_task = @pending_todos[0]
          next_task = @pending_todos[1]

          # Calculate available width for task text
          prefix = "[##] Task [#{progress}]: "
          prefix_length = prefix.length
          available_width = @width - prefix_length - 2

          # Build current task text
          current_text = "##{current_task[:id]} - #{current_task[:task]}"
          
          # Build next task text if exists
          next_text = next_task ? " (Next: ##{next_task[:id]} - #{next_task[:task]})" : ""
          
          # Combine and truncate
          combined_text = current_text + next_text
          if combined_text.length > available_width
            # Truncate, prioritize current task
            if current_text.length > available_width - 3
              combined_text = truncate_text(current_text, available_width)
            else
              # Show current task + truncated next
              remaining = available_width - current_text.length
              if remaining > 10  # Only show next if we have space
                next_text = truncate_text(next_text, remaining)
                combined_text = current_text + next_text
              else
                combined_text = current_text
              end
            end
          end

          # Build final line with colors
          line = "#{@pastel.cyan("[##]")} Task [#{progress}]: #{combined_text}"
          print line

          flush
        end

        # Clear the area
        def clear
          @todos = []
          @pending_todos = []
          @completed_count = 0
          @total_count = 0
          @height = 0
        end

        private

        # Truncate text to fit width
        def truncate_text(text, max_width)
          return "" if text.nil?

          if text.length > max_width
            text[0...(max_width - 3)] + "..."
          else
            text
          end
        end

        # Update width on resize
        def update_width
          @width = TTY::Screen.width
        end

        # Move cursor to position
        def move_cursor(row, col)
          print "\e[#{row + 1};#{col + 1}H"
        end

        # Clear current line
        def clear_line
          print "\e[2K"
        end

        # Flush output
        def flush
          $stdout.flush
        end
      end
    end
  end
end
