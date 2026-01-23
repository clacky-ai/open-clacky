# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    # LineEditor module provides single-line text editing functionality
    # Shared by InputArea and InlineInput components
    module LineEditor
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
    end
  end
end
