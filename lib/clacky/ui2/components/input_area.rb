# frozen_string_literal: true

require "pastel"
require "tempfile"
require_relative "../theme_manager"
require_relative "../line_editor"

module Clacky
  module UI2
    module Components
      # InputArea manages the fixed input area at the bottom of the screen
      # Enhanced with multi-line support, image paste, and more
      class InputArea
        include LineEditor

        attr_accessor :row
        attr_reader :cursor_position, :line_index, :images, :tips_message, :tips_type

        def initialize(row: 0)
          @row = row
          @lines = [""]
          @line_index = 0
          @cursor_position = 0
          @history = []
          @history_index = -1
          @pastel = Pastel.new
          @width = TTY::Screen.width

          @images = []
          @max_images = 3
          @paste_counter = 0
          @paste_placeholders = {}
          @last_ctrl_c_time = nil
          @tips_message = nil
          @tips_type = :info
          @tips_timer = nil
          @last_render_row = nil

          # Paused state - when InlineInput is active
          @paused = false

          # Session bar info
          @sessionbar_info = {
            working_dir: nil,
            mode: nil,
            model: nil,
            tasks: 0,
            cost: 0.0,
            status: 'idle'  # Workspace status: 'idle' or 'working'
          }
        end

        # Get current theme from ThemeManager
        def theme
          UI2::ThemeManager.current_theme
        end

        # Get prompt symbol from theme
        def prompt
          "#{theme.symbol(:user)} "
        end

        def required_height
          # When paused (InlineInput active), don't take up any space
          return 0 if @paused

          height = 1  # Session bar (top)
          height += 1  # Separator after session bar
          height += @images.size
          height += @lines.size
          height += 1  # Bottom separator
          height += 1 if @tips_message
          height
        end

        # Update session bar info
        # @param working_dir [String] Working directory
        # @param mode [String] Permission mode
        # @param model [String] AI model name
        # @param tasks [Integer] Number of completed tasks
        # @param cost [Float] Total cost
        # @param status [String] Workspace status ('idle' or 'working')
        def update_sessionbar(working_dir: nil, mode: nil, model: nil, tasks: nil, cost: nil, status: nil)
          @sessionbar_info[:working_dir] = working_dir if working_dir
          @sessionbar_info[:mode] = mode if mode
          @sessionbar_info[:model] = model if model
          @sessionbar_info[:tasks] = tasks if tasks
          @sessionbar_info[:cost] = cost if cost
          @sessionbar_info[:status] = status if status
        end

        def input_buffer
          @lines.join("\n")
        end

        def handle_key(key)
          # Ignore input when paused (InlineInput is active)
          return { action: nil } if @paused

          old_height = required_height

          result = case key
          when Hash
            if key[:type] == :rapid_input
              insert_text(key[:text])
              clear_tips
            end
            { action: nil }
          when :enter then handle_enter
          when :newline then newline; { action: nil }
          when :backspace then backspace; { action: nil }
          when :delete then delete_char; { action: nil }
          when :left_arrow, :ctrl_b then cursor_left; { action: nil }
          when :right_arrow, :ctrl_f then cursor_right; { action: nil }
          when :up_arrow then handle_up_arrow
          when :down_arrow then handle_down_arrow
          when :home, :ctrl_a then cursor_home; { action: nil }
          when :end, :ctrl_e then cursor_end; { action: nil }
          when :ctrl_k then kill_to_end; { action: nil }
          when :ctrl_u then kill_to_start; { action: nil }
          when :ctrl_w then kill_word; { action: nil }
          when :ctrl_c then handle_ctrl_c
          when :ctrl_d then handle_ctrl_d
          when :ctrl_v then handle_paste
          when :shift_tab then { action: :toggle_mode }
          when :escape then { action: nil }
          else
            if key.is_a?(String) && key.length >= 1 && key.ord >= 32
              insert_char(key)
            end
            { action: nil }
          end

          new_height = required_height
          if new_height != old_height
            result[:height_changed] = true
            result[:new_height] = new_height
          end

          result
        end

        def render(start_row:, width: nil)
          @width = width || TTY::Screen.width
          @last_render_row = start_row  # Save for tips auto-clear

          # When paused, don't render anything (InlineInput is active)
          return if @paused

          current_row = start_row

          # Session bar at top
          render_sessionbar(current_row)
          current_row += 1

          # Separator after session bar
          render_separator(current_row)
          current_row += 1

          # Images
          @images.each_with_index do |img_path, idx|
            move_cursor(current_row, 0)
            filename = File.basename(img_path)
            filesize = File.exist?(img_path) ? format_filesize(File.size(img_path)) : "N/A"
            content = @pastel.dim("[Image #{idx + 1}] #{filename} (#{filesize}) (Ctrl+D to delete)")
            print_with_padding(content)
            current_row += 1
          end

          # Input lines
          @lines.each_with_index do |line, idx|
            move_cursor(current_row, 0)

            content = if idx == 0
              prompt_text = theme.format_symbol(:user) + " "
              if idx == @line_index
                "#{prompt_text}#{render_line_with_cursor(line)}"
              else
                "#{prompt_text}#{theme.format_text(line, :user)}"
              end
            else
              indent = " " * prompt.length
              if idx == @line_index
                "#{indent}#{render_line_with_cursor(line)}"
              else
                "#{indent}#{theme.format_text(line, :user)}"
              end
            end
            print_with_padding(content)
            current_row += 1
          end

          # Bottom separator
          render_separator(current_row)
          current_row += 1

          # Tips bar (if any)
          if @tips_message
            move_cursor(current_row, 0)
            content = format_tips(@tips_message, @tips_type)
            print_with_padding(content)
            current_row += 1
          end

          # Position cursor at current edit position
          position_cursor(start_row)
          flush
        end

        def position_cursor(start_row)
          # Cursor is in input area: start_row + session_bar(1) + separator(1) + images + line_index
          cursor_row = start_row + 2 + @images.size + @line_index
          # Calculate display width of text before cursor (considering multi-byte characters like Chinese)
          chars = current_line.chars
          text_before_cursor = chars[0...@cursor_position].join
          display_width = calculate_display_width(text_before_cursor)
          cursor_col = prompt.length + display_width
          move_cursor(cursor_row, cursor_col)
        end

        def set_tips(message, type: :info)
          # Cancel existing timer if any
          if @tips_timer&.alive?
            @tips_timer.kill
          end

          @tips_message = message
          @tips_type = type

          # Auto-clear tips after 2 seconds
          @tips_timer = Thread.new do
            sleep 2
            # Clear tips from state and screen
            @tips_message = nil
            # Tips row: start_row + session_bar(1) + separator(1) + images + lines + separator(1)
            tips_row = @last_render_row + 2 + @images.size + @lines.size + 1
            move_cursor(tips_row, 0)
            clear_line
            flush
          end
        end

        def clear_tips
          # Cancel timer if any
          if @tips_timer&.alive?
            @tips_timer.kill
          end
          @tips_message = nil
        end

        # Pause input area (when InlineInput is active)
        def pause
          @paused = true
        end

        # Resume input area (when InlineInput is done)
        def resume
          @paused = false
        end

        # Check if paused
        def paused?
          @paused
        end

        def current_content
          text = expand_placeholders(@lines.join("\n"))
          return "" if text.empty?

          # Format user input with color and spacing from theme
          symbol = theme.format_symbol(:user)
          content = theme.format_text(text, :user)

          "\n#{symbol} #{content}\n"
        end

        def current_value
          expand_placeholders(@lines.join("\n"))
        end

        def empty?
          @lines.all?(&:empty?) && @images.empty?
        end

        def multiline?
          @lines.size > 1
        end

        def has_images?
          @images.any?
        end

        def set_prompt(prompt)
          prompt = prompt
        end

        # --- Public editing methods ---

        def insert_char(char)
          chars = current_line.chars
          chars.insert(@cursor_position, char)
          @lines[@line_index] = chars.join
          @cursor_position += 1
        end

        def backspace
          if @cursor_position > 0
            chars = current_line.chars
            chars.delete_at(@cursor_position - 1)
            @lines[@line_index] = chars.join
            @cursor_position -= 1
          elsif @line_index > 0
            prev_line = @lines[@line_index - 1]
            current = @lines[@line_index]
            @lines.delete_at(@line_index)
            @line_index -= 1
            @cursor_position = prev_line.chars.length
            @lines[@line_index] = prev_line + current
          end
        end

        def delete_char
          chars = current_line.chars
          return if @cursor_position >= chars.length
          chars.delete_at(@cursor_position)
          @lines[@line_index] = chars.join
        end

        def cursor_left
          @cursor_position = [@cursor_position - 1, 0].max
        end

        def cursor_right
          @cursor_position = [@cursor_position + 1, current_line.chars.length].min
        end

        def cursor_home
          @cursor_position = 0
        end

        def cursor_end
          @cursor_position = current_line.chars.length
        end

        def clear
          @lines = [""]
          @line_index = 0
          @cursor_position = 0
          @history_index = -1
          @images = []
          @paste_counter = 0
          @paste_placeholders = {}
          clear_tips
        end

        def submit
          text = current_value
          imgs = @images.dup
          add_to_history(text) unless text.empty?
          clear
          { text: text, images: imgs }
        end

        def history_prev
          return if @history.empty?
          if @history_index == -1
            @history_index = @history.size - 1
          else
            @history_index = [@history_index - 1, 0].max
          end
          load_history_entry
        end

        def history_next
          return if @history_index == -1
          @history_index += 1
          if @history_index >= @history.size
            @history_index = -1
            @lines = [""]
            @line_index = 0
            @cursor_position = 0
          else
            load_history_entry
          end
        end

        private

        # Print content and pad with spaces to clear any remaining characters from previous render
        # This avoids flickering from clear_line while ensuring old content is erased
        def print_with_padding(content)
          # Calculate visible width (strip ANSI codes for width calculation)
          visible_content = content.gsub(/\e\[[0-9;]*m/, '')
          visible_width = calculate_display_width(visible_content)
          
          # Print content
          print content
          
          # Pad with spaces if needed to clear old content
          remaining = @width - visible_width
          print " " * remaining if remaining > 0
        end

        def handle_enter
          text = current_value.strip

          # Handle commands (with or without slash)
          if text.start_with?('/')
            case text
            when '/clear'
              clear
              return { action: :clear_output }
            when '/help'
              return { action: :help }
            when '/exit', '/quit'
              return { action: :exit }
            else
              set_tips("Unknown command: #{text} (Available: /clear, /help, /exit)", type: :warning)
              return { action: nil }
            end
          elsif text == '?'
            return { action: :help }
          elsif text == 'exit' || text == 'quit'
            return { action: :exit }
          end

          if text.empty? && @images.empty?
            return { action: nil }
          end

          content_to_display = current_content
          result_text = current_value
          result_images = @images.dup

          add_to_history(result_text) unless result_text.empty?
          clear

          { action: :submit, data: { text: result_text, images: result_images, display: content_to_display } }
        end

        def handle_up_arrow
          if multiline?
            unless cursor_up
              history_prev
            end
          else
            # Navigate history when single line (empty or not)
            history_prev
          end
          { action: nil }
        end

        def handle_down_arrow
          if multiline?
            unless cursor_down
              history_next
            end
          else
            # Navigate history when single line (empty or not)
            history_next
          end
          { action: nil }
        end

        def handle_ctrl_c
          { action: :interrupt }
        end

        def handle_ctrl_d
          if has_images?
            if @images.size == 1
              @images.clear
            else
              @images.shift
            end
            clear_tips
            { action: nil }
          elsif empty?
            { action: :exit }
          else
            { action: nil }
          end
        end

        def handle_paste
          pasted = paste_from_clipboard
          if pasted[:type] == :image
            if @images.size < @max_images
              @images << pasted[:path]
              clear_tips
            else
              set_tips("Maximum #{@max_images} images allowed. Delete an image first (Ctrl+D).", type: :warning)
            end
          else
            insert_text(pasted[:text])
            clear_tips
          end
          { action: nil }
        end

        def insert_text(text)
          return if text.nil? || text.empty?

          text_lines = text.split(/\r\n|\r|\n/)

          if text_lines.size > 1
            @paste_counter += 1
            placeholder = "[##{@paste_counter} Paste Text]"
            @paste_placeholders[placeholder] = text

            chars = current_line.chars
            chars.insert(@cursor_position, *placeholder.chars)
            @lines[@line_index] = chars.join
            @cursor_position += placeholder.length
          else
            chars = current_line.chars
            text.chars.each_with_index do |c, i|
              chars.insert(@cursor_position + i, c)
            end
            @lines[@line_index] = chars.join
            @cursor_position += text.length
          end
        end

        def newline
          chars = current_line.chars
          @lines[@line_index] = chars[0...@cursor_position].join
          @lines.insert(@line_index + 1, chars[@cursor_position..-1]&.join || "")
          @line_index += 1
          @cursor_position = 0
        end

        def cursor_up
          return false if @line_index == 0
          @line_index -= 1
          @cursor_position = [@cursor_position, current_line.chars.length].min
          true
        end

        def cursor_down
          return false if @line_index >= @lines.size - 1
          @line_index += 1
          @cursor_position = [@cursor_position, current_line.chars.length].min
          true
        end

        def kill_to_end
          chars = current_line.chars
          @lines[@line_index] = chars[0...@cursor_position].join
        end

        def kill_to_start
          chars = current_line.chars
          @lines[@line_index] = chars[@cursor_position..-1]&.join || ""
          @cursor_position = 0
        end

        def kill_word
          chars = current_line.chars
          pos = @cursor_position - 1

          while pos >= 0 && chars[pos] =~ /\s/
            pos -= 1
          end
          while pos >= 0 && chars[pos] =~ /\S/
            pos -= 1
          end

          delete_start = pos + 1
          chars.slice!(delete_start...@cursor_position)
          @lines[@line_index] = chars.join
          @cursor_position = delete_start
        end

        def load_history_entry
          return unless @history_index >= 0 && @history_index < @history.size
          entry = @history[@history_index]
          @lines = entry.split("\n")
          @lines = [""] if @lines.empty?
          @line_index = @lines.size - 1
          @cursor_position = current_line.chars.length
        end

        def add_to_history(entry)
          @history << entry
          @history = @history.last(100) if @history.size > 100
        end

        def paste_from_clipboard
          case RbConfig::CONFIG["host_os"]
          when /darwin/i
            paste_from_clipboard_macos
          when /linux/i
            paste_from_clipboard_linux
          else
            { type: :text, text: "" }
          end
        end

        def paste_from_clipboard_macos
          has_image = system("osascript -e 'try' -e 'the clipboard as «class PNGf»' -e 'on error' -e 'return false' -e 'end try' >/dev/null 2>&1")

          if has_image
            temp_dir = Dir.tmpdir
            temp_filename = "clipboard-#{Time.now.to_i}-#{rand(10000)}.png"
            temp_path = File.join(temp_dir, temp_filename)

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

          text = `pbpaste 2>/dev/null`.to_s
          text.force_encoding('UTF-8')
          text = text.encode('UTF-8', invalid: :replace, undef: :replace)
          { type: :text, text: text }
        rescue => e
          { type: :text, text: "" }
        end

        def paste_from_clipboard_linux
          if system("which xclip >/dev/null 2>&1")
            text = `xclip -selection clipboard -o 2>/dev/null`.to_s
            text.force_encoding('UTF-8')
            text = text.encode('UTF-8', invalid: :replace, undef: :replace)
            { type: :text, text: text }
          elsif system("which xsel >/dev/null 2>&1")
            text = `xsel --clipboard --output 2>/dev/null`.to_s
            text.force_encoding('UTF-8')
            text = text.encode('UTF-8', invalid: :replace, undef: :replace)
            { type: :text, text: text }
          else
            { type: :text, text: "" }
          end
        rescue => e
          { type: :text, text: "" }
        end

        def current_line
          @lines[@line_index] || ""
        end

        def expand_placeholders(text)
          super(text, @paste_placeholders)
        end

        def render_line_with_cursor(line)
          chars = line.chars
          before_cursor = chars[0...@cursor_position].join
          cursor_char = chars[@cursor_position] || " "
          after_cursor = chars[(@cursor_position + 1)..-1]&.join || ""

          "#{@pastel.white(before_cursor)}#{@pastel.on_white(@pastel.black(cursor_char))}#{@pastel.white(after_cursor)}"
        end

        def render_separator(row)
          move_cursor(row, 0)
          content = @pastel.dim("─" * @width)
          print_with_padding(content)
        end

        def render_sessionbar(row)
          move_cursor(row, 0)

          # If no sessionbar info, just render a separator
          unless @sessionbar_info[:working_dir]
            content = @pastel.dim("─" * @width)
            print_with_padding(content)
            return
          end

          parts = []
          separator = @pastel.dim(" │ ")

          # Workspace status
          if @sessionbar_info[:status]
            status_theme_key = status_theme_key_for(@sessionbar_info[:status])
            parts << theme.format_text(@sessionbar_info[:status], status_theme_key)
          end

          # Working directory (shortened if too long)
          if @sessionbar_info[:working_dir]
            dir_display = shorten_path(@sessionbar_info[:working_dir])
            parts << @pastel.bright_cyan(dir_display)
          end

          # Permission mode
          if @sessionbar_info[:mode]
            mode_color = mode_color_for(@sessionbar_info[:mode])
            parts << @pastel.public_send(mode_color, @sessionbar_info[:mode])
          end

          # Model
          if @sessionbar_info[:model]
            parts << @pastel.bright_white(@sessionbar_info[:model])
          end

          # Tasks count
          parts << @pastel.yellow("#{@sessionbar_info[:tasks]} tasks")

          # Cost
          cost_display = format("$%.1f", @sessionbar_info[:cost])
          parts << @pastel.yellow(cost_display)

          session_line = " " + parts.join(separator)
          print_with_padding(session_line)
        end

        def shorten_path(path)
          return path if path.length <= 40

          # Replace home directory with ~
          home = ENV["HOME"]
          if home && path.start_with?(home)
            path = path.sub(home, "~")
          end

          # If still too long, show last parts
          if path.length > 40
            parts = path.split("/")
            if parts.length > 3
              ".../" + parts[-3..-1].join("/")
            else
              path[0..40] + "..."
            end
          else
            path
          end
        end

        def mode_color_for(mode)
          case mode.to_s
          when /auto_approve/
            :bright_magenta
          when /confirm_safes/
            :bright_yellow
          when /confirm_edits/
            :bright_green
          when /plan_only/
            :bright_blue
          else
            :white
          end
        end

        def status_theme_key_for(status)
          case status.to_s.downcase
          when 'idle'
            :info  # Use info color for idle state
          when 'working'
            :progress  # Use progress color for working state
          else
            :info
          end
        end

        def format_tips(message, type)
          case type
          when :warning
            @pastel.dim("[") + @pastel.yellow("Warn") + @pastel.dim("] ") + @pastel.yellow(message)
          when :error
            @pastel.dim("[") + @pastel.red("Error") + @pastel.dim("] ") + @pastel.red(message)
          else
            @pastel.dim("[") + @pastel.cyan("Info") + @pastel.dim("] ") + @pastel.white(message)
          end
        end

        def format_filesize(size)
          if size < 1024
            "#{size}B"
          elsif size < 1024 * 1024
            "#{(size / 1024.0).round(1)}KB"
          else
            "#{(size / 1024.0 / 1024.0).round(1)}MB"
          end
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
