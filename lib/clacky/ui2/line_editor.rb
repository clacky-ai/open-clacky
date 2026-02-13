# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    # LineEditor module provides single-line text editing functionality
    # Shared by InputArea and InlineInput components
    module LineEditor
      # Maximum content width ratio (percentage of terminal width)
      # Use 90% of terminal width for better readability on wide screens
      # This dynamically adjusts based on terminal size
      MAX_CONTENT_WIDTH_RATIO = 0.9

      attr_reader :cursor_position

      def initialize_line_editor
        @line = ""
        @cursor_position = 0
        @pastel = Pastel.new
      end

      # Get current line content
      def current_line
        @line
      end

      # Set line content
      def set_line(text)
        @line = text
        @cursor_position = [@cursor_position, @line.chars.length].min
      end

      # Clear line
      def clear_line_content
        @line = ""
        @cursor_position = 0
      end

      # Insert character at cursor position
      def insert_char(char)
        chars = @line.chars
        chars.insert(@cursor_position, char)
        @line = chars.join
        @cursor_position += 1
      end

      # Backspace - delete character before cursor
      def backspace
        return if @cursor_position == 0
        chars = @line.chars
        chars.delete_at(@cursor_position - 1)
        @line = chars.join
        @cursor_position -= 1
      end

      # Delete character at cursor position
      def delete_char
        chars = @line.chars
        return if @cursor_position >= chars.length
        chars.delete_at(@cursor_position)
        @line = chars.join
      end

      # Move cursor left
      def cursor_left
        @cursor_position = [@cursor_position - 1, 0].max
      end

      # Move cursor right
      def cursor_right
        @cursor_position = [@cursor_position + 1, @line.chars.length].min
      end

      # Move cursor to start of line
      def cursor_home
        @cursor_position = 0
      end

      # Move cursor to end of line
      def cursor_end
        @cursor_position = @line.chars.length
      end

      # Kill from cursor to end of line (Ctrl+K)
      def kill_to_end
        chars = @line.chars
        @line = chars[0...@cursor_position].join
      end

      # Kill from start to cursor (Ctrl+U)
      def kill_to_start
        chars = @line.chars
        @line = chars[@cursor_position..-1]&.join || ""
        @cursor_position = 0
      end

      # Kill word before cursor (Ctrl+W)
      def kill_word
        chars = @line.chars
        pos = @cursor_position - 1

        # Skip whitespace
        while pos >= 0 && chars[pos] =~ /\s/
          pos -= 1
        end
        # Delete word characters
        while pos >= 0 && chars[pos] =~ /\S/
          pos -= 1
        end

        delete_start = pos + 1
        chars.slice!(delete_start...@cursor_position)
        @line = chars.join
        @cursor_position = delete_start
      end

      # Insert text at cursor position
      def insert_text(text)
        return if text.nil? || text.empty?
        chars = @line.chars
        text.chars.each_with_index do |c, i|
          chars.insert(@cursor_position + i, c)
        end
        @line = chars.join
        @cursor_position += text.length
      end

      # Expand placeholders and normalize line endings
      def expand_placeholders(text, placeholders)
        result = text.dup
        placeholders.each do |placeholder, actual_content|
          # Normalize line endings to \n
          normalized_content = actual_content.gsub(/\r\n|\r/, "\n")
          result.gsub!(placeholder, normalized_content)
        end
        result
      end

      # Render line with cursor highlight
      # @return [String] Rendered line with cursor
      def render_line_with_cursor
        chars = @line.chars
        before_cursor = chars[0...@cursor_position].join
        cursor_char = chars[@cursor_position] || " "
        after_cursor = chars[(@cursor_position + 1)..-1]&.join || ""

        "#{@pastel.white(before_cursor)}#{@pastel.on_white(@pastel.black(cursor_char))}#{@pastel.white(after_cursor)}"
      end

      # Calculate display width of a string, considering multi-byte characters
      # East Asian Wide and Fullwidth characters (like Chinese) take 2 columns
      # @param text [String] UTF-8 encoded text
      # @return [Integer] Display width in terminal columns
      def calculate_display_width(text)
        width = 0
        text.each_char do |char|
          code = char.ord
          # East Asian Wide and Fullwidth characters
          # See: https://www.unicode.org/reports/tr11/
          if (code >= 0x1100 && code <= 0x115F) ||   # Hangul Jamo
             (code >= 0x2329 && code <= 0x232A) ||   # Left/Right-Pointing Angle Brackets
             (code >= 0x2E80 && code <= 0x303E) ||   # CJK Radicals Supplement .. CJK Symbols and Punctuation
             (code >= 0x3040 && code <= 0xA4CF) ||   # Hiragana .. Yi Radicals
             (code >= 0xAC00 && code <= 0xD7A3) ||   # Hangul Syllables
             (code >= 0xF900 && code <= 0xFAFF) ||   # CJK Compatibility Ideographs
             (code >= 0xFE10 && code <= 0xFE19) ||   # Vertical Forms
             (code >= 0xFE30 && code <= 0xFE6F) ||   # CJK Compatibility Forms .. Small Form Variants
             (code >= 0xFF00 && code <= 0xFF60) ||   # Fullwidth Forms
             (code >= 0xFFE0 && code <= 0xFFE6) ||   # Fullwidth Forms
             (code >= 0x1F300 && code <= 0x1F9FF) || # Emoticons, Symbols, etc.
             (code >= 0x20000 && code <= 0x2FFFD) || # CJK Unified Ideographs Extension B..F
             (code >= 0x30000 && code <= 0x3FFFD)    # CJK Unified Ideographs Extension G
            width += 2
          else
            width += 1
          end
        end
        width
      end

      # Strip ANSI escape codes from a string
      # @param text [String] Text with ANSI codes
      # @return [String] Text without ANSI codes
      def strip_ansi_codes(text)
        text.gsub(/\e\[[0-9;]*m/, '')
      end

      # Get cursor column position (considering multi-byte characters)
      # @param prompt [String] Prompt string before the line (may contain ANSI codes)
      # @return [Integer] Column position for cursor
      def cursor_column(prompt = "")
        # Strip ANSI codes from prompt to get actual display width
        visible_prompt = strip_ansi_codes(prompt)
        prompt_display_width = calculate_display_width(visible_prompt)

        # Calculate display width of text before cursor
        chars = @line.chars
        text_before_cursor = chars[0...@cursor_position].join
        text_display_width = calculate_display_width(text_before_cursor)

        prompt_display_width + text_display_width
      end

      # Get cursor position considering line wrapping
      # @param prompt [String] Prompt string before the line (may contain ANSI codes)
      # @param width [Integer] Terminal width for wrapping
      # @param continuation_prompt [String] Prompt for continuation lines (default: "> ")
      # @return [Array<Integer>] Row and column position (0-indexed)
      def cursor_position_with_wrap(prompt = "", width = TTY::Screen.width, continuation_prompt = "> ")
        return [0, cursor_column(prompt)] if width <= 0

        prompt_width = calculate_display_width(strip_ansi_codes(prompt))
        available_width = width - prompt_width

        # Get wrapped segments for current line
        wrapped_segments = wrap_line(@line, available_width)

        # Find which segment contains cursor
        cursor_segment_idx = 0
        cursor_pos_in_segment = @cursor_position

        wrapped_segments.each_with_index do |segment, idx|
          if @cursor_position >= segment[:start] && @cursor_position < segment[:end]
            cursor_segment_idx = idx
            cursor_pos_in_segment = @cursor_position - segment[:start]
            break
          elsif @cursor_position >= segment[:end] && idx == wrapped_segments.size - 1
            cursor_segment_idx = idx
            cursor_pos_in_segment = segment[:end] - segment[:start]
            break
          end
        end

        # Calculate display width of text before cursor in this segment
        chars = @line.chars
        segment_start = wrapped_segments[cursor_segment_idx][:start]
        text_in_segment_before_cursor = chars[segment_start...(segment_start + cursor_pos_in_segment)].join
        display_width = calculate_display_width(text_in_segment_before_cursor)

        # Use appropriate prompt width based on which segment (row) we're on
        # First line uses original prompt, subsequent lines use continuation prompt
        actual_prompt_width = if cursor_segment_idx == 0
          prompt_width
        else
          calculate_display_width(strip_ansi_codes(continuation_prompt))
        end

        col = actual_prompt_width + display_width
        row = cursor_segment_idx

        [row, col]
      end

      # Wrap a line into multiple segments based on available width
      # Considers display width of characters (multi-byte characters like Chinese)
      # @param line [String] The line to wrap
      # @param max_width [Integer] Maximum display width per wrapped line
      # @return [Array<Hash>] Array of segment info: { text: String, start: Integer, end: Integer }
      def wrap_line(line, max_width)
        return [{ text: "", start: 0, end: 0 }] if line.empty?
        return [{ text: line, start: 0, end: line.length }] if max_width <= 0

        segments = []
        chars = line.chars
        segment_start = 0
        current_width = 0
        current_end = 0

        chars.each_with_index do |char, idx|
          char_width = char_display_width(char)

          # If adding this character exceeds max width, complete current segment
          if current_width + char_width > max_width && current_end > segment_start
            segments << {
              text: chars[segment_start...current_end].join,
              start: segment_start,
              end: current_end
            }
            segment_start = idx
            current_end = idx + 1
            current_width = char_width
          else
            current_end = idx + 1
            current_width += char_width
          end
        end

        # Add the last segment
        if current_end > segment_start
          segments << {
            text: chars[segment_start...current_end].join,
            start: segment_start,
            end: current_end
          }
        end

        segments.empty? ? [{ text: "", start: 0, end: 0 }] : segments
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

      # Calculate effective content width (respecting MAX_CONTENT_WIDTH_RATIO)
      # @param screen_width [Integer] Terminal screen width
      # @return [Integer] Effective content width to use
      private def effective_content_width(screen_width)
        (screen_width * MAX_CONTENT_WIDTH_RATIO).to_i
      end

      # Render a segment of a line with cursor if cursor is in this segment
      # @param line [String] Full line text
      # @param segment_start [Integer] Start position of segment in line (char index)
      # @param segment_end [Integer] End position of segment in line (char index)
      # @return [String] Rendered segment with cursor if applicable
      def render_line_segment_with_cursor(line, segment_start, segment_end)
        chars = line.chars
        segment_chars = chars[segment_start...segment_end]

        # Check if cursor is in this segment
        if @cursor_position >= segment_start && @cursor_position < segment_end
          # Cursor is in this segment
          cursor_pos_in_segment = @cursor_position - segment_start
          before_cursor = segment_chars[0...cursor_pos_in_segment].join
          cursor_char = segment_chars[cursor_pos_in_segment] || " "
          after_cursor = segment_chars[(cursor_pos_in_segment + 1)..-1]&.join || ""

          "#{@pastel.white(before_cursor)}#{@pastel.on_white(@pastel.black(cursor_char))}#{@pastel.white(after_cursor)}"
        elsif @cursor_position == segment_end && segment_end == line.length
          # Cursor is at the very end of the line, show it in last segment
          segment_text = segment_chars.join
          "#{@pastel.white(segment_text)}#{@pastel.on_white(@pastel.black(' '))}"
        else
          # Cursor is not in this segment, just format normally
          @pastel.white(segment_chars.join)
        end
      end
    end
  end
end
