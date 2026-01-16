# frozen_string_literal: true

require "io/console"
require "pastel"
require "tty-screen"
require "tempfile"
require "base64"

module Clacky
  module UI
    # Enhanced input prompt with multi-line support and image paste
    # 
    # Features:
    # - Shift+Enter: Add new line
    # - Enter: Submit message
    # - Ctrl+V: Paste text or images from clipboard
    # - Image preview and management
    class EnhancedPrompt
      attr_reader :images

      def initialize
        @pastel = Pastel.new
        @images = [] # Array of image file paths
        @paste_counter = 0 # Counter for paste operations
        @paste_placeholders = {} # Map of placeholder text to actual pasted content
      end

      # Read user input with enhanced features
      # @param prefix [String] Prompt prefix (default: "You:")
      # @return [Hash, nil] { text: String, images: Array } or nil on EOF
      def read_input(prefix: "You:")
        @images = []
        lines = []
        cursor_pos = 0
        line_index = 0

        loop do
          # Display the prompt box
          display_prompt_box(lines, prefix, line_index, cursor_pos)

          # Read a single character/key
          begin
            key = read_key
          rescue Interrupt
            return nil
          end

          case key
          when "\n" # Shift+Enter - newline (Linux/Mac sends \n for Shift+Enter in some terminals)
            # Add new line
            if lines[line_index]
              # Split current line at cursor (use chars for UTF-8)
              chars = lines[line_index].chars
              lines[line_index] = chars[0...cursor_pos].join
              lines.insert(line_index + 1, chars[cursor_pos..-1].join || "")
            else
              lines.insert(line_index + 1, "")
            end
            line_index += 1
            cursor_pos = 0

          when "\r" # Enter - submit
            # Submit if not empty
            unless lines.join.strip.empty? && @images.empty?
              clear_prompt_display(lines.size)
              # Replace placeholders with actual pasted content
              final_text = expand_placeholders(lines.join("\n"))
              return { text: final_text, images: @images.dup }
            end

          when "\u0003" # Ctrl+C
            clear_prompt_display(lines.size)
            return nil

          when "\u0016" # Ctrl+V - Paste
            pasted = paste_from_clipboard
            if pasted[:type] == :image
              # Save image and add to list
              @images << pasted[:path]
            else
              # Handle pasted text
              pasted_text = pasted[:text]
              pasted_lines = pasted_text.split("\n")
              
              if pasted_lines.size > 1
                # Multi-line paste - use placeholder for display
                @paste_counter += 1
                placeholder = "[##{@paste_counter} Paste Text]"
                @paste_placeholders[placeholder] = pasted_text
                
                # Insert placeholder at cursor position
                chars = (lines[line_index] || "").chars
                placeholder_chars = placeholder.chars
                chars.insert(cursor_pos, *placeholder_chars)
                lines[line_index] = chars.join
                cursor_pos += placeholder_chars.length
              else
                # Single line paste - insert at cursor (use chars for UTF-8)
                chars = (lines[line_index] || "").chars
                pasted_chars = pasted_text.chars
                chars.insert(cursor_pos, *pasted_chars)
                lines[line_index] = chars.join
                cursor_pos += pasted_chars.length
              end
            end

          when "\u007F", "\b" # Backspace
            if cursor_pos > 0
              # Delete character before cursor (use chars for UTF-8)
              chars = (lines[line_index] || "").chars
              chars.delete_at(cursor_pos - 1)
              lines[line_index] = chars.join
              cursor_pos -= 1
            elsif line_index > 0
              # Join with previous line
              prev_line = lines[line_index - 1]
              current_line = lines[line_index]
              lines.delete_at(line_index)
              line_index -= 1
              cursor_pos = prev_line.chars.length
              lines[line_index] = prev_line + current_line
            end

          when "\e[A" # Up arrow
            if line_index > 0
              line_index -= 1
              cursor_pos = [cursor_pos, (lines[line_index] || "").chars.length].min
            end

          when "\e[B" # Down arrow
            if line_index < lines.size - 1
              line_index += 1
              cursor_pos = [cursor_pos, (lines[line_index] || "").chars.length].min
            end

          when "\e[C" # Right arrow
            current_line = lines[line_index] || ""
            cursor_pos = [cursor_pos + 1, current_line.chars.length].min

          when "\e[D" # Left arrow
            cursor_pos = [cursor_pos - 1, 0].max

          when "\u0004" # Ctrl+D - Delete image by number
            if @images.any?
              print "\nEnter image number to delete (1-#{@images.size}): "
              num = STDIN.gets.to_i
              if num > 0 && num <= @images.size
                @images.delete_at(num - 1)
              end
            end

          else
            # Regular character input - support UTF-8
            if key.length >= 1 && key != "\e" && !key.start_with?("\e") && key.ord >= 32
              lines[line_index] ||= ""
              current_line = lines[line_index]
              
              # Insert character at cursor position (using character index, not byte index)
              chars = current_line.chars
              chars.insert(cursor_pos, key)
              lines[line_index] = chars.join
              cursor_pos += 1
            end
          end

          # Ensure we have at least one line
          lines << "" if lines.empty?
        end
      end

      private

      # Expand placeholders to actual pasted content
      def expand_placeholders(text)
        result = text.dup
        @paste_placeholders.each do |placeholder, actual_content|
          result.gsub!(placeholder, actual_content)
        end
        result
      end

      # Display the prompt box with images and input
      def display_prompt_box(lines, prefix, line_index, cursor_pos)
        width = [TTY::Screen.width - 5, 80].min

        # Clear previous display if exists
        if @last_display_lines && @last_display_lines > 0
          # Move cursor up and clear each line
          @last_display_lines.times do
            print "\e[1A"  # Move up one line
            print "\e[2K"  # Clear entire line
          end
          print "\r"  # Move to beginning of line
        end

        lines_to_display = []

        # Display images if any
        if @images.any?
          lines_to_display << @pastel.dim("╭─ Attached Images " + "─" * (width - 19) + "╮")
          @images.each_with_index do |img_path, idx|
            filename = File.basename(img_path)
            # Check if file exists before getting size
            filesize = File.exist?(img_path) ? format_filesize(File.size(img_path)) : "N/A"
            line_content = " #{idx + 1}. #{filename} (#{filesize})"
            display_content = line_content.ljust(width - 2)
            lines_to_display << @pastel.dim("│ ") + display_content + @pastel.dim(" │")
          end
          lines_to_display << @pastel.dim("╰" + "─" * width + "╯")
          lines_to_display << ""
        end

        # Display input box
        hint = "Shift+Enter:newline | Enter:submit | Ctrl+C:cancel"
        lines_to_display << @pastel.dim("╭─ Message " + "─" * (width - 10) + "╮")
        hint_line = @pastel.dim(hint)
        padding = " " * [(width - hint.length - 2), 0].max
        lines_to_display << @pastel.dim("│ ") + hint_line + padding + @pastel.dim(" │")
        lines_to_display << @pastel.dim("├" + "─" * width + "┤")

        # Display input lines
        display_lines = lines.empty? ? [""] : lines
        max_display_lines = 10 # Limit display to 10 lines
        start_idx = [line_index - 5, 0].max
        end_idx = [start_idx + max_display_lines - 1, display_lines.size - 1].min
        
        (start_idx..end_idx).each do |idx|
          line = display_lines[idx] || ""
          line_chars = line.chars
          
          # Truncate if too long (use character count)
          display_chars = line_chars[0...width - 2]
          display_line = display_chars.join.ljust(width - 2)
          
          if idx == line_index
            # Show cursor on current line
            visible_cursor_pos = [cursor_pos, width - 3].min
            before_cursor = display_chars[0...visible_cursor_pos].join
            cursor_char = display_chars[visible_cursor_pos] || " "
            after_cursor_chars = display_chars[(visible_cursor_pos + 1)..-1]
            after_cursor = after_cursor_chars ? after_cursor_chars.join : ""
            
            # Ensure total width is correct
            total_before = before_cursor.length + cursor_char.length + after_cursor.length
            padding = " " * [width - 2 - total_before, 0].max
            
            line_display = before_cursor + @pastel.on_white(@pastel.black(cursor_char)) + after_cursor + padding
            lines_to_display << @pastel.dim("│ ") + line_display + @pastel.dim(" │")
          else
            lines_to_display << @pastel.dim("│ ") + display_line + @pastel.dim(" │")
          end
        end

        # Footer - calculate width properly
        footer_text = "Line #{line_index + 1}/#{display_lines.size} | Char #{cursor_pos}/#{(display_lines[line_index] || "").chars.length}"
        # Total width = "╰─ " (3) + footer_text + " ─...─╯" (width - 3 - footer_text.length)
        remaining_width = width - footer_text.length - 3  # 3 = "╰─ " length
        footer_line = @pastel.dim("╰─ ") + @pastel.dim(footer_text) + @pastel.dim(" ") + @pastel.dim("─" * [remaining_width - 1, 0].max) + @pastel.dim("╯")
        lines_to_display << footer_line
        
        # Output all lines at once (use print to avoid extra newline at the end)
        print lines_to_display.join("\n")
        print "\n"  # Add one controlled newline
        
        # Remember how many lines we displayed
        @last_display_lines = lines_to_display.size
      end

      # Clear prompt display after submission
      def clear_prompt_display(num_lines)
        # Clear the prompt box we just displayed
        if @last_display_lines && @last_display_lines > 0
          @last_display_lines.times do
            print "\e[1A"  # Move up one line
            print "\e[2K"  # Clear entire line
          end
          print "\r"  # Move to beginning of line
        end
      end

      # Read a single key press with escape sequence handling
      # Handles UTF-8 multi-byte characters correctly
      def read_key
        $stdin.set_encoding('UTF-8')
        $stdin.raw do |io|
          c = io.getc
          
          # Handle escape sequences (arrow keys, special keys)
          if c == "\e"
            # Read the next 2 characters for escape sequences
            begin
              extra = io.read_nonblock(2)
              c = c + extra
            rescue IO::WaitReadable, Errno::EAGAIN
              # No more characters available
            end
          end
          
          c
        end
      rescue Errno::EINTR
        "\u0003" # Treat interrupt as Ctrl+C
      end

      # Paste from clipboard (cross-platform)
      # @return [Hash] { type: :text/:image, text: String, path: String }
      def paste_from_clipboard
        case RbConfig::CONFIG["host_os"]
        when /darwin/i
          paste_from_clipboard_macos
        when /linux/i
          paste_from_clipboard_linux
        when /mswin|mingw|cygwin/i
          paste_from_clipboard_windows
        else
          { type: :text, text: "" }
        end
      end

      # Paste from macOS clipboard
      def paste_from_clipboard_macos
        require 'shellwords'
        require 'fileutils'
        
        # First check if there's an image in clipboard
        # Use osascript to check clipboard content type
        has_image = system("osascript -e 'try' -e 'the clipboard as «class PNGf»' -e 'on error' -e 'return false' -e 'end try' >/dev/null 2>&1")
        
        if has_image
          # Create a persistent temporary file (won't be auto-deleted)
          temp_dir = Dir.tmpdir
          temp_filename = "clipboard-#{Time.now.to_i}-#{rand(10000)}.png"
          temp_path = File.join(temp_dir, temp_filename)
          
          # Extract image using osascript
          script = <<~APPLESCRIPT
            set png_data to the clipboard as «class PNGf»
            set the_file to open for access POSIX file "#{temp_path}" with write permission
            write png_data to the_file
            close access the_file
          APPLESCRIPT
          
          success = system("osascript", "-e", script, out: File::NULL, err: File::NULL)
          
          if success && File.exist?(temp_path) && File.size(temp_path) > 0
            return { type: :image, path: temp_path }
          end
        end

        # No image, try text
        text = `pbpaste 2>/dev/null`.to_s
        { type: :text, text: text }
      rescue => e
        # Fallback to empty text on error
        { type: :text, text: "" }
      end

      # Paste from Linux clipboard
      def paste_from_clipboard_linux
        require 'shellwords'
        
        # Check if xclip is available
        if system("which xclip >/dev/null 2>&1")
          # Try to get image first
          temp_file = Tempfile.new(["clipboard-", ".png"])
          temp_file.close
          
          # Try different image MIME types
          ["image/png", "image/jpeg", "image/jpg"].each do |mime_type|
            if system("xclip -selection clipboard -t #{mime_type} -o > #{Shellwords.escape(temp_file.path)} 2>/dev/null")
              if File.size(temp_file.path) > 0
                return { type: :image, path: temp_file.path }
              end
            end
          end
          
          # No image, get text
          text = `xclip -selection clipboard -o 2>/dev/null`.to_s
          { type: :text, text: text }
        elsif system("which xsel >/dev/null 2>&1")
          # Fallback to xsel for text only
          text = `xsel --clipboard --output 2>/dev/null`.to_s
          { type: :text, text: text }
        else
          { type: :text, text: "" }
        end
      rescue => e
        { type: :text, text: "" }
      end

      # Paste from Windows clipboard
      def paste_from_clipboard_windows
        # Try to get image using PowerShell
        temp_file = Tempfile.new(["clipboard-", ".png"])
        temp_file.close
        
        ps_script = <<~POWERSHELL
          Add-Type -AssemblyName System.Windows.Forms
          $img = [Windows.Forms.Clipboard]::GetImage()
          if ($img) {
            $img.Save('#{temp_file.path.gsub("'", "''")}', [System.Drawing.Imaging.ImageFormat]::Png)
            exit 0
          } else {
            exit 1
          }
        POWERSHELL
        
        success = system("powershell", "-NoProfile", "-Command", ps_script, out: File::NULL, err: File::NULL)
        
        if success && File.exist?(temp_file.path) && File.size(temp_file.path) > 0
          return { type: :image, path: temp_file.path }
        end

        # No image, get text
        text = `powershell -NoProfile -Command "Get-Clipboard" 2>nul`.to_s
        { type: :text, text: text }
      rescue => e
        { type: :text, text: "" }
      end

      # Format file size for display
      def format_filesize(size)
        if size < 1024
          "#{size}B"
        elsif size < 1024 * 1024
          "#{(size / 1024.0).round(1)}KB"
        else
          "#{(size / 1024.0 / 1024.0).round(1)}MB"
        end
      end
    end
  end
end
