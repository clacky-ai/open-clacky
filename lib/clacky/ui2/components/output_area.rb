# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # OutputArea writes content directly to terminal
      # Terminal handles scrolling natively via scrollback buffer
      class OutputArea
        attr_accessor :height

        def initialize(height:)
          @height = height
          @pastel = Pastel.new
          @width = TTY::Screen.width
          @last_line_row = nil  # Track last line position for updates
        end

        # Append single line content directly to terminal (no newline)
        # Multi-line handling is done by LayoutManager
        # @param content [String] Single line content to append
        def append(content)
          return if content.nil? || content.empty?

          update_width
          print truncate_line(content)
          flush
        end

        # Initial render - no-op, output flows naturally
        # @param start_row [Integer] Screen row (ignored)
        def render(start_row:)
          # No-op - output flows naturally from current position
        end

        # Update the last line (for progress indicator)
        # Uses carriage return to overwrite current line
        # @param content [String] New content for last line
        def update_last_line(content)
          print "\r"
          clear_line
          print truncate_line(content)
          flush
        end

        # Remove the last line from output
        def remove_last_line
          print "\r"
          clear_line
          flush
        end

        # Clear - no-op for natural scroll mode
        def clear
          # No-op
        end

        # Legacy scroll methods (no-op, terminal handles scrolling)
        def scroll_up(lines = 1); end
        def scroll_down(lines = 1); end
        def scroll_to_top; end
        def scroll_to_bottom; end
        def at_bottom?; true; end
        def scroll_percentage; 0.0; end

        def visible_range
          { start: 1, end: @height, total: @height }
        end

        private

        # Truncate line to fit screen width
        def truncate_line(line)
          return "" if line.nil?

          visible_length = line.gsub(/\e\[[0-9;]*m/, "").length

          if visible_length > @width
            truncated = line[0...(@width - 3)]
            truncated + @pastel.dim("...")
          else
            line
          end
        end

        def update_width
          @width = TTY::Screen.width
        end

        def move_cursor(row, col)
          print "\e[#{row + 1};#{col + 1}H"
        end

        def clear_line
          print "\e[2K"
        end

        def flush
          $stdout.flush
        end
      end
    end
  end
end
