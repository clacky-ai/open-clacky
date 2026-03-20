# frozen_string_literal: true

require "tty-screen"
require "io/console"
require_relative "../utils/encoding"

module Clacky
  module UI2
    # ScreenBuffer manages terminal screen state and provides low-level rendering primitives
    class ScreenBuffer
      attr_reader :width, :height

      def initialize
        @width = TTY::Screen.width
        @height = TTY::Screen.height
        @buffer = []
        @last_input_time = nil
        @rapid_input_threshold = 0.01 # 10ms threshold for detecting paste-like rapid input

        # Keep stdin in UTF-8 mode so getc returns complete multi-byte characters (e.g. CJK).
        # Switching to BINARY would cause getc to return one byte at a time, breaking Chinese input.
        $stdin.set_encoding('UTF-8')
      end

      # Move cursor to specific position (0-indexed)
      # @param row [Integer] Row position
      # @param col [Integer] Column position
      def move_cursor(row, col)
        print "\e[#{row + 1};#{col + 1}H"
      end

      # Clear screen with different modes:
      #   :preserve - clear visible screen, scrollback history preserved (default)
      #   :current  - cursor to top-left and erase to end, no new scrollback produced
      #   :reset    - clear visible screen AND scrollback history (full reset)
      # @param mode [Symbol] Clear mode (:preserve, :current, :reset)
      def clear_screen(mode: :preserve)
        case mode
        when :reset
          print "\e[3J"    # erase scrollback buffer
          print "\e[H\e[J" # cursor to top-left, erase to end of screen
        when :current
          print "\e[H\e[J" # cursor to top-left, erase to end of screen
        else # :preserve
          print "\e[2J\e[H"    # erase visible screen, scrollback preserved
        end
        move_cursor(0, 0)
      end

      # Clear current line
      def clear_line
        print "\e[2K"
      end

      # Clear from cursor to end of line
      def clear_to_eol
        print "\e[K"
      end

      # Hide cursor
      def hide_cursor
        print "\e[?25l"
      end

      # Show cursor
      def show_cursor
        print "\e[?25h"
      end

      # Save cursor position
      def save_cursor
        print "\e[s"
      end

      # Restore cursor position
      def restore_cursor
        print "\e[u"
      end

      # Enable alternative screen buffer (like vim/less)
      def enable_alt_screen
        print "\e[?1049h"
      end

      # Disable alternative screen buffer
      def disable_alt_screen
        print "\e[?1049l"
      end

      # Set scroll region (DECSTBM - DEC Set Top and Bottom Margins)
      # Content written in this region will scroll, content outside will stay fixed
      # @param top [Integer] Top row (1-indexed)
      # @param bottom [Integer] Bottom row (1-indexed)
      def set_scroll_region(top, bottom)
        print "\e[#{top};#{bottom}r"
      end

      # Reset scroll region to full screen
      def reset_scroll_region
        print "\e[r"
      end

      # Scroll the scroll region up by n lines
      # @param n [Integer] Number of lines to scroll
      def scroll_up(n = 1)
        print "\e[#{n}S"
      end

      # Scroll the scroll region down by n lines
      # @param n [Integer] Number of lines to scroll
      def scroll_down(n = 1)
        print "\e[#{n}T"
      end

      # Get current screen dimensions
      def update_dimensions
        @width = TTY::Screen.width
        @height = TTY::Screen.height
      end

      # Enable raw mode (disable line buffering)
      def enable_raw_mode
        $stdin.raw!
      end

      # Disable raw mode
      def disable_raw_mode
        $stdin.cooked!
      end

      # Read a single character without echo
      # @param timeout [Float] Timeout in seconds (nil for blocking)
      # @return [String, nil] Character or nil if timeout
      def read_char(timeout: nil)
        if timeout
          return nil unless IO.select([$stdin], nil, nil, timeout)
        end

        $stdin.getc
      end

      # Read a key including special keys (arrows, etc.)
      # @param timeout [Float] Timeout in seconds
      # @return [Symbol, String, Hash, nil] Key symbol, character, or { type: :rapid_input, text: String }
      def read_key(timeout: nil)
        current_time = Time.now.to_f
        is_rapid_input = @last_input_time && (current_time - @last_input_time) < @rapid_input_threshold
        @last_input_time = current_time

        char = read_char(timeout: timeout)
        return nil unless char

        # Convert raw BINARY bytes to valid UTF-8. Invalid/undefined bytes are dropped
        # rather than raising ArgumentError (which would crash the input loop).
        char = safe_to_utf8(char) if char.is_a?(String)

        # Handle escape sequences for special keys
        if char == "\e"
          # Non-blocking read for escape sequence
          char2 = read_char(timeout: 0.01)
          return :escape unless char2

          if char2 == "["
            char3 = read_char(timeout: 0.01)
            case char3
            when "A" then return :up_arrow
            when "B" then return :down_arrow
            when "C" then return :right_arrow
            when "D" then return :left_arrow
            when "H" then return :home
            when "F" then return :end
            when "Z" then return :shift_tab
            when "3"
              char4 = read_char(timeout: 0.01)
              return :delete if char4 == "~"
            end
          end
        end

        # Check if there are more characters available (for rapid input detection)
        has_more_input = IO.select([$stdin], nil, nil, 0)

        # If this is rapid input or there are more characters available
        if is_rapid_input || has_more_input
          buffer = char.to_s.dup

          # Keep reading available characters
          loop_count = 0
          empty_checks = 0

          loop do
            # Check if there's data available immediately
            has_data = IO.select([$stdin], nil, nil, 0)

            if has_data
              next_char = $stdin.getc rescue nil
              break unless next_char

              next_char = safe_to_utf8(next_char)
              buffer << next_char
              loop_count += 1
              empty_checks = 0  # Reset empty check counter
            else
              # No immediate data, but wait a bit to see if more is coming
              # This handles the case where paste data arrives in chunks
              empty_checks += 1
              if empty_checks == 1
                # First empty check - wait 10ms for more data
                sleep 0.01
              else
                # Second empty check - really no more data
                break
              end
            end
          end

          # If we buffered multiple characters or newlines, treat as rapid input (paste)
          if buffer.length > 1 || buffer.include?("\n") || buffer.include?("\r")
            # Ensure the accumulated buffer is valid UTF-8 before regex operations
            buffer = safe_to_utf8(buffer)
            # Remove any trailing \r or \n from rapid input buffer
            cleaned_buffer = buffer.gsub(/[\r\n]+\z/, '')
            return { type: :rapid_input, text: cleaned_buffer } if cleaned_buffer.length > 0
          end

          # Single character, continue to normal handling
          char = buffer[0] if buffer.length == 1
        end

        # Handle control characters
        case char
        when "\r" then :enter
        when "\n" then :newline  # Shift+Enter sends \n
        when "\u007F", "\b" then :backspace
        when "\u0001" then :ctrl_a
        when "\u0002" then :ctrl_b
        when "\u0003" then :ctrl_c
        when "\u0004" then :ctrl_d
        when "\u0005" then :ctrl_e
        when "\u0006" then :ctrl_f
        when "\u000B" then :ctrl_k
        when "\u000C" then :ctrl_l
        when "\u000F" then :ctrl_o
        when "\u0012" then :ctrl_r
        when "\u0015" then :ctrl_u
        when "\u0016" then :ctrl_v
        when "\u0017" then :ctrl_w
        when "\t"     then :tab
        else char
        end
      end

      # Flush output
      def flush
        $stdout.flush
      end

      private

      # Ensure a string is valid UTF-8.
      # stdin stays in UTF-8 mode so getc returns complete characters (including CJK).
      # This method handles the rare case where an invalid byte slips through
      # (e.g. a stray terminal escape or a partial sequence) by scrubbing it out
      # rather than letting ArgumentError crash the input loop.
      # @param str [String] String from getc (UTF-8 encoded, but may have invalid bytes)
      # @return [String] Valid UTF-8 string
      private def safe_to_utf8(str)
        return str if str.valid_encoding?

        Clacky::Utils::Encoding.sanitize_utf8(str)
      end
    end
  end
end
