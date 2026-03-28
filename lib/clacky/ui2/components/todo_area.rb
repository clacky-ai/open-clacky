# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # TodoArea displays active todos above the separator line
      class TodoArea
        attr_accessor :height
        attr_reader :todos

        MAX_DISPLAY_TASKS = 3  # Show current + next 2 tasks

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

          # Calculate height: 0 if no pending, otherwise 1 line per task (up to MAX_DISPLAY_TASKS)
          if @pending_todos.empty?
            @height = 0
          else
            @height = [@pending_todos.size, MAX_DISPLAY_TASKS].min
          end
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

          # Render each task on separate line
          tasks_to_show = @pending_todos.take(MAX_DISPLAY_TASKS)
          
          tasks_to_show.each_with_index do |task, index|
            move_cursor(start_row + index, 0)
            
            # Build the line content
            line_content = if index == 0
              # First line: Task [2/4]: #3 - Current task description
              progress = "#{@completed_count}/#{@total_count}"
              prefix = "Task [#{progress}]: "
              task_text = "##{task[:id]} - #{task[:task]}"
              available_width = @width - prefix.length - 2
              truncated_task = truncate_text(task_text, available_width)
              
              "#{@pastel.cyan(prefix)}#{truncated_task}"
            else
              # Subsequent lines: -> Next: #4 - Next task description
              label = index == 1 ? "Next" : "After"
              prefix = "-> #{label}: "
              task_text = "##{task[:id]} - #{task[:task]}"
              available_width = @width - prefix.length - 2
              truncated_task = truncate_text(task_text, available_width)
              
              "#{@pastel.dim(prefix)}#{@pastel.dim(truncated_task)}"
            end

            # Use carriage return and print content directly (overwrite existing content)
            print "\r#{line_content}"
            # Clear any remaining characters from previous render if line is shorter
            clear_to_end_of_line
          end

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

        # Clear from cursor to end of line
        def clear_to_end_of_line
          print "\e[0K"
        end

        # Flush output
        def flush
          $stdout.flush
        end
      end
    end
  end
end
