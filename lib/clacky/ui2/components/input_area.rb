# frozen_string_literal: true

require "pastel"
require "tempfile"
require_relative "../theme_manager"
require_relative "../line_editor"
require_relative "command_suggestions"
require_relative "../../utils/encoding"

module Clacky
  module UI2
    module Components
      # InputArea manages the fixed input area at the bottom of the screen
      # Enhanced with multi-line support, image paste, and more
      class InputArea
        include LineEditor

        # User tips pool - can be extended with more tips over time
        USER_TIPS = [
          "Shift+Tab to toggle permission mode (confirm_safes ⇄ auto_approve)",
          "Ctrl+C to interrupt AI execution or clear input",
          "Shift+Enter to create multi-line input",
          "Ctrl+V to paste images (supports up to 3 images)",
          "Ctrl+D to delete pasted images",
          "Use /clear to restart session, /help for commands"
        ].freeze

        attr_accessor :row
        attr_reader :cursor_position, :line_index, :files, :tips_message, :tips_type

        def initialize(row: 0)
          @row = row
          @lines = [""]
          @line_index = 0
          @cursor_position = 0
          @history = []
          @history_index = -1
          @pastel = Pastel.new
          @width = TTY::Screen.width

          @files = []
          @paste_counter = 0
          @paste_placeholders = {}
          @last_ctrl_c_time = nil
          @tips_message = nil
          @tips_type = :info
          @tips_timer = nil
          @last_render_row = nil

          # User tip (usage suggestion) - separate from system tips
          @user_tip = nil
          @user_tip_timer = nil
          @user_tip_count = 0

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

          # Animation state for working status
          @animation_frame = 0
          @last_animation_update = Time.now
          @working_frames = ["❄", "❅", "❆"]

          # Command suggestions dropdown
          @command_suggestions = CommandSuggestions.new
          @skill_loader = nil  # Will be set via set_skill_loader method
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

          height = 0
          
          # Session bar - calculate actual wrapped height
          height += calculate_sessionbar_height
          
          # Separator after session bar
          height += 1
          
          # Images
          height += @files.size
          
          # Calculate height considering wrapped lines
          # Use effective content width (respecting MAX_CONTENT_WIDTH_RATIO)
          content_width = effective_content_width(@width)
          @lines.each_with_index do |line, idx|
            prefix = if idx == 0
              prompt
            else
              " " * prompt.length
            end
            prefix_width = calculate_display_width(strip_ansi_codes(prefix))
            available_width = [content_width - prefix_width, 20].max  # At least 20 chars
            wrapped_segments = wrap_line(line, available_width)
            height += wrapped_segments.size
          end
          
          # Bottom separator
          height += 1
          
          # Command suggestions (rendered above input)
          height += @command_suggestions.required_height if @command_suggestions
          
          # Tips and user tips
          height += 1 if @tips_message
          height += 1 if @user_tip
          
          height
        end

        # Set skill loader for command suggestions
        # @param skill_loader [Clacky::SkillLoader] The skill loader instance
        # @param agent_profile [Clacky::AgentProfile, nil] Current agent profile for skill filtering
        def set_skill_loader(skill_loader, agent_profile = nil)
          @skill_loader = skill_loader
          @command_suggestions.load_skill_commands(skill_loader, agent_profile) if skill_loader
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

          # Handle command suggestions navigation first if visible
          if @command_suggestions.visible
            case key
            when :up_arrow
              @command_suggestions.select_previous
              return { action: nil }
            when :down_arrow
              @command_suggestions.select_next
              return { action: nil }
            when :enter
              # Accept selected command and submit immediately
              if @command_suggestions.has_suggestions?
                selected = @command_suggestions.selected_command_text
                if selected
                  # Replace current input with selected command
                  @lines = [selected]
                  @line_index = 0
                  @cursor_position = selected.length
                  @command_suggestions.hide
                  # Submit the command immediately
                  return handle_enter
                end
              end
              # Fall through to normal enter handling if no suggestion
            when :escape
              @command_suggestions.hide
              return { action: nil }
            when :tab
              # Tab accepts the currently highlighted suggestion
              if @command_suggestions.has_suggestions?
                selected = @command_suggestions.selected_command_text
                if selected
                  hint = @command_suggestions.selected_argument_hint
                  completed = "#{selected} "
                  @lines = [completed]
                  @line_index = 0
                  @cursor_position = completed.length
                  @command_suggestions.hide
                  # Show argument hint as a tip if available
                  set_tips("Usage: #{selected} #{hint}", type: :info) if hint && !hint.empty?
                  return { action: nil }
                end
              end
            end
          end

          # Tab with no visible suggestions: trigger slash-command completion
          if key == :tab
            trigger_tab_completion
            return { action: nil }
          end

          result = case key
          when Hash
            if key[:type] == :rapid_input
              insert_text(key[:text])
              clear_tips
              update_command_suggestions
            end
            { action: nil }
          when :enter then handle_enter
          when :newline then newline; { action: nil }
          when :backspace 
            backspace
            update_command_suggestions
            { action: nil }
          when :delete 
            delete_char
            update_command_suggestions
            { action: nil }
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
          when :ctrl_o then { action: :toggle_expand }
          when :shift_tab then { action: :toggle_mode }
          when :escape 
            if @command_suggestions.visible
              @command_suggestions.hide
              { action: nil }
            else
              # Trigger time machine when ESC is pressed and suggestions not visible
              { action: :time_machine }
            end
          else
            if key.is_a?(String) && key.length >= 1 && key.ord >= 32
              insert_char(key)
              update_command_suggestions
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

          # Files (images / documents)
          @files.each_with_index do |f, idx|
            move_cursor(current_row, 0)
            filename = f[:name] || f["name"] || "file"
            content = @pastel.dim("[File #{idx + 1}] #{filename} (Ctrl+D to delete)")
            print_with_padding(content)
            current_row += 1
          end

          # Input lines with auto-wrap support
          current_row = render_input_lines(current_row)

          # Bottom separator
          render_separator(current_row)
          current_row += 1

          # Command suggestions (rendered above tips)
          if @command_suggestions && @command_suggestions.visible
            # Render suggestions at current row
            print @command_suggestions.render(row: current_row, col: 0, width: [@width - 4, 60].min)
            current_row += @command_suggestions.required_height
          end

          # Tips bar (if any)
          if @tips_message
            move_cursor(current_row, 0)
            content = format_tips(@tips_message, @tips_type)
            print_with_padding(content)
            current_row += 1
          end

          # User tip (if any)
          if @user_tip
            move_cursor(current_row, 0)
            content = format_user_tip(@user_tip)
            print_with_padding(content)
            current_row += 1
          end

          # Position cursor at current edit position
          position_cursor(start_row)
          flush
        end

        def position_cursor(start_row)
          # Calculate which wrapped line the cursor is on
          cursor_row = start_row + 2 + @files.size  # session_bar + separator + images
          # Use effective content width (respecting MAX_CONTENT_WIDTH_RATIO)
          content_width = effective_content_width(@width)
          
          # Add rows for lines before current line
          @lines[0...@line_index].each_with_index do |line, idx|
            prefix = if idx == 0
              prompt
            else
              " " * prompt.length
            end
            prefix_width = calculate_display_width(strip_ansi_codes(prefix))
            available_width = [content_width - prefix_width, 20].max
            wrapped_segments = wrap_line(line, available_width)
            cursor_row += wrapped_segments.size
          end
          
          # Find which wrapped segment of current line contains cursor
          current = current_line
          prefix = if @line_index == 0
            prompt
          else
            " " * prompt.length
          end
          prefix_width = calculate_display_width(strip_ansi_codes(prefix))
          available_width = [content_width - prefix_width, 20].max
          wrapped_segments = wrap_line(current, available_width)
          
          # Find cursor segment and position within segment
          cursor_segment_idx = 0
          cursor_pos_in_segment = @cursor_position
          
          wrapped_segments.each_with_index do |segment, idx|
            if @cursor_position >= segment[:start] && @cursor_position < segment[:end]
              cursor_segment_idx = idx
              cursor_pos_in_segment = @cursor_position - segment[:start]
              break
            elsif @cursor_position >= segment[:end] && idx == wrapped_segments.size - 1
              # Cursor at very end
              cursor_segment_idx = idx
              cursor_pos_in_segment = segment[:end] - segment[:start]
              break
            end
          end
          
          cursor_row += cursor_segment_idx
          
          # Calculate display width of text before cursor in this segment
          chars = current.chars
          segment_start = wrapped_segments[cursor_segment_idx][:start]
          text_in_segment_before_cursor = chars[segment_start...(segment_start + cursor_pos_in_segment)].join
          display_width = calculate_display_width(text_in_segment_before_cursor)
          
          cursor_col = prefix_width + display_width
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
            tips_row = @last_render_row + 2 + @files.size + @lines.size + 1
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

        # Show a random user tip with probability and auto-rotation (max 3 tips)
        # @param probability [Float] Probability of showing tip (0.0 to 1.0, default: 0.4)
        # @param rotation_interval [Integer] Seconds between tip rotation (default: 12)
        # @param max_tips [Integer] Maximum number of tips to show before stopping (default: 3)
        def show_user_tip(probability: 0.4, rotation_interval: 12, max_tips: 3)
          # Random chance to show tip
          return unless rand < probability
          
          # Stop existing timer if any
          stop_user_tip_timer
          
          # Reset counter and pick first random tip
          @user_tip_count = 1
          @user_tip = USER_TIPS.sample
          
          # Start rotation timer (will show max_tips total)
          @user_tip_timer = Thread.new do
            while @user_tip_count < max_tips
              sleep rotation_interval
              @user_tip_count += 1
              
              # Pick a different tip
              old_tip = @user_tip
              loop do
                @user_tip = USER_TIPS.sample
                break if @user_tip != old_tip || USER_TIPS.size == 1
              end
            end
            
            # After showing max_tips, wait then clear
            sleep rotation_interval
            @user_tip = nil
            @user_tip_count = 0
          rescue => e
            # Silently handle thread errors
          end
        end

        # Clear user tip and stop rotation
        def clear_user_tip
          stop_user_tip_timer
          @user_tip = nil
          @user_tip_count = 0
        end

        private def stop_user_tip_timer
          if @user_tip_timer&.alive?
            @user_tip_timer.kill
            @user_tip_timer = nil
          end
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
          
          # If both text and images are empty, return empty string
          return "" if text.empty? && @files.empty?

          # Format user input with color and spacing from theme
          symbol = theme.format_symbol(:user)
          content = theme.format_text(text, :user)

          result = "\n#{symbol} #{content}\n"
          
          # Append file information if present
          if @files.any?
            @files.each_with_index do |f, idx|
              filename = f[:name] || f["name"] || "file"
              result += @pastel.dim("    [File #{idx + 1}] #{filename}") + "\n"
            end
          end
          
          result
        end

        def current_value
          expand_placeholders(@lines.join("\n"))
        end

        def empty?
          @lines.all?(&:empty?) && @files.empty?
        end

        def multiline?
          @lines.size > 1
        end

        def has_images?
          @files.any?
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
          @files = []
          @paste_counter = 0
          @paste_placeholders = {}
          clear_tips
          @command_suggestions.hide if @command_suggestions
        end

        def submit
          text = current_value
          files = @files.dup
          add_to_history(text) unless text.empty?
          clear
          { text: text, files: files }
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

        # Update command suggestions based on current input
        # Shows suggestions when input starts with /
        private def update_command_suggestions
          return unless @command_suggestions

          current = current_line.strip

          # Check if we should show suggestions (input starts with /)
          if current.start_with?('/') && @line_index == 0
            # Extract the filter text (everything after /)
            filter_text = current[1..-1] || ""
            @command_suggestions.show(filter_text)
          else
            @command_suggestions.hide
          end
        end

        # Trigger tab completion: show all commands or filter by current slash input
        # Called when Tab is pressed and no suggestions dropdown is visible
        private def trigger_tab_completion
          return unless @command_suggestions

          current = current_line.strip

          if current.empty?
            # Empty input: type "/" and show all commands
            insert_char("/")
            @command_suggestions.show("")
          elsif current.start_with?("/")
            # Already typing a slash command: show/refresh filtered suggestions
            filter_text = current[1..-1] || ""
            @command_suggestions.show(filter_text)
          end
          # Tab on normal text has no effect
        end

        # Render all input lines with auto-wrap support
        # @param start_row [Integer] Starting row position
        # @return [Integer] Next available row after rendering all lines
        def render_input_lines(start_row)
          current_row = start_row
          # Use effective content width (respecting MAX_CONTENT_WIDTH_RATIO)
          content_width = effective_content_width(@width)
          
          @lines.each_with_index do |line, line_idx|
            prefix = calculate_line_prefix(line_idx)
            prefix_width = calculate_display_width(strip_ansi_codes(prefix))
            available_width = content_width - prefix_width
            wrapped_segments = wrap_line(line, available_width)

            wrapped_segments.each_with_index do |segment_info, wrap_idx|
              content = render_line_segment(line, line_idx, segment_info, wrap_idx, prefix, prefix_width)
              move_cursor(current_row, 0)
              print_with_padding(content)
              current_row += 1
            end
          end
          
          current_row
        end

        # Calculate the prefix (prompt or indent) for a given line index
        # @param line_idx [Integer] Index of the line
        # @return [String] Prefix string (with formatting)
        private def calculate_line_prefix(line_idx)
          if line_idx == 0
            theme.format_symbol(:user) + " "
          else
            " " * prompt.length
          end
        end

        # Render a single segment of a line (handling cursor and wrapping)
        # @param line [String] Full line text
        # @param line_idx [Integer] Index of the line in @lines
        # @param segment_info [Hash] Segment information from wrap_line
        # @param wrap_idx [Integer] Index of this segment in wrapped segments
        # @param prefix [String] Line prefix (prompt or indent)
        # @param prefix_width [Integer] Display width of the prefix
        # @return [String] Formatted content for this segment
        private def render_line_segment(line, line_idx, segment_info, wrap_idx, prefix, prefix_width)
          segment_text = segment_info[:text]
          segment_start = segment_info[:start]
          segment_end = segment_info[:end]
          
          is_current_line = (line_idx == @line_index)
          is_first_segment = (wrap_idx == 0)
          
          # Determine the line prefix
          line_prefix = if is_first_segment
            prefix
          else
            " " * prefix_width  # Continuation indent
          end
          
          # Render the segment content (with or without cursor)
          segment_content = if is_current_line
            render_line_segment_with_cursor(line, segment_start, segment_end)
          else
            theme.format_text(segment_text, :user)
          end
          
          "#{line_prefix}#{segment_content}"
        end

        # Wrap a line into multiple segments based on available width
        # Considers display width of characters (multi-byte characters like Chinese)
        # @param line [String] The line to wrap
        # @param max_width [Integer] Maximum display width per wrapped line
        # @return [Array<Hash>] Array of segment info: { text: String, start: Integer, end: Integer }
        def wrap_line(line, max_width)
          super(line, max_width)
        end

        # Calculate display width of a single character
        # @param char [String] Single character
        # @return [Integer] Display width (1 or 2)
        def char_display_width(char)
          super(char)
        end

        # Strip ANSI escape codes from a string
        # @param text [String] Text with ANSI codes
        # @return [String] Text without ANSI codes
        def strip_ansi_codes(text)
          text.gsub(/\e\[[0-9;]*m/, '')
        end

        # Print content and pad with spaces to clear any remaining characters from previous render
        # This avoids flickering from clear_line while ensuring old content is erased
        def print_with_padding(content)
          # Calculate visible width (strip ANSI codes for width calculation)
          visible_content = content.gsub(/\e\[[0-9;]*m/, '')
          visible_width = calculate_display_width(visible_content)
          
          # IMPORTANT: If content exceeds screen width, truncate to prevent terminal auto-wrap
          if visible_width > @width
            # Content too long - truncate to fit (loses ANSI colors but prevents wrapping)
            truncate_at = 0
            current_width = 0
            visible_content.each_char.with_index do |char, idx|
              char_width = char_display_width(char)
              break if current_width + char_width + 3 > @width  # Reserve 3 for "..."
              current_width += char_width
              truncate_at = idx + 1
            end
            print visible_content[0...truncate_at]
            print "..."
            # Pad remaining
            remaining = @width - current_width - 3
            print " " * remaining if remaining > 0
          else
            # Content fits - print normally
            print content
            # Pad with spaces if needed to clear old content
            remaining = @width - visible_width
            print " " * remaining if remaining > 0
          end
        end

        def handle_enter
          text = current_value.strip

          # Prepare display content and data BEFORE clearing
          content_to_display = current_content
          result_text = current_value
          result_files = @files.dup

          # Handle commands (with or without slash)
          if text.start_with?('/')
            # Check if it's a command (single slash followed by English letters only)
            # Paths like /xxx/xxxx should not be treated as commands
            if text =~ /^\/([a-zA-Z-]+)$/
              case text
              when '/clear'
                add_to_history(result_text) unless result_text.empty?
                clear
                return { action: :clear_output, data: { text: result_text, files: result_files, display: content_to_display } }
              when '/help'
                add_to_history(result_text) unless result_text.empty?
                clear
                return { action: :help, data: { text: result_text, files: result_files, display: content_to_display } }
              when '/exit', '/quit'
                return { action: :exit }
              else
                # Let other commands (like skills) pass through to agent
                # Fall through to submit
              end
            end
            # If it's not a command pattern (e.g., /xxx/xxxx), treat as normal input
          elsif text == '?'
            add_to_history(result_text) unless result_text.empty?
            clear
            return { action: :help, data: { text: result_text, files: result_files, display: content_to_display } }
          elsif text == 'exit' || text == 'quit'
            return { action: :exit }
          end

          if text.empty? && @files.empty?
            return { action: nil }
          end

          add_to_history(result_text) unless result_text.empty?
          clear

          { action: :submit, data: { text: result_text, files: result_files, display: content_to_display } }
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
            if @files.size == 1
              @files.clear
            else
              @files.shift
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
            path = pasted[:path]
            mime_type = pasted[:mime_type] || "image/png"
            @files << { name: File.basename(path), mime_type: mime_type, path: path }
            clear_tips
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
          text = Clacky::Utils::Encoding.to_utf8(text)
          { type: :text, text: text }
        rescue => e
          { type: :text, text: "" }
        end

        def paste_from_clipboard_linux
          if system("which xclip >/dev/null 2>&1")
            text = `xclip -selection clipboard -o 2>/dev/null`.to_s
            text = Clacky::Utils::Encoding.to_utf8(text)
            { type: :text, text: text }
          elsif system("which xsel >/dev/null 2>&1")
            text = `xsel --clipboard --output 2>/dev/null`.to_s
            text = Clacky::Utils::Encoding.to_utf8(text)
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

        # Render a segment of a line with cursor if cursor is in this segment
        # Applies theme colors to the text
        # @param line [String] Full line text
        # @param segment_start [Integer] Start position of segment in line (char index)
        # @param segment_end [Integer] End position of segment in line (char index)
        # @return [String] Rendered segment with cursor and theme colors applied
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

            # Apply theme color to text parts, keep cursor highlight as is
            "#{theme.format_text(before_cursor, :user)}#{@pastel.on_white(@pastel.black(cursor_char))}#{theme.format_text(after_cursor, :user)}"
          elsif @cursor_position == segment_end && segment_end == line.length
            # Cursor is at the very end of the line, show it in last segment
            segment_text = segment_chars.join
            "#{theme.format_text(segment_text, :user)}#{@pastel.on_white(@pastel.black(' '))}"
          else
            # Cursor is not in this segment, apply theme color
            theme.format_text(segment_chars.join, :user)
          end
        end

        # Render a separator line (ensures it doesn't exceed screen width)
        # @param row [Integer] Row position to render
        def render_separator(row)
          move_cursor(row, 0)
          # Ensure separator doesn't exceed screen width to prevent wrapping
          separator_width = [@width, 1].max
          content = @pastel.dim("─" * separator_width)
          print content
          # Clear any remaining space
          remaining = @width - separator_width
          print " " * remaining if remaining > 0
        end

        # Render session bar with wrapping support
        # @param row [Integer] Starting row position
        # @return [Integer] Number of rows actually used
        def render_sessionbar(row)
          move_cursor(row, 0)

          # If no sessionbar info, just render a separator
          unless @sessionbar_info[:working_dir]
            separator_width = [@width, 1].max
            content = @pastel.dim("─" * separator_width)
            print content
            remaining = @width - separator_width
            print " " * remaining if remaining > 0
            return 1
          end

          session_line = build_sessionbar_content
          
          # IMPORTANT: Always use print_with_padding which handles truncation
          # to prevent terminal auto-wrap
          print_with_padding(session_line)
          1
        end
        
        # Build the session bar content string
        # @return [String] Formatted session bar content
        private def build_sessionbar_content
          parts = []
          separator = @pastel.dim(" │ ")

          # Workspace status with animation
          if @sessionbar_info[:status]
            status_color = status_color_for(@sessionbar_info[:status])
            status_indicator = get_status_indicator(@sessionbar_info[:status], status_color)
            parts << "#{status_indicator} #{@pastel.public_send(status_color, @sessionbar_info[:status])}"
          end

          # Working directory (shortened if too long)
          if @sessionbar_info[:working_dir]
            dir_display = shorten_path(@sessionbar_info[:working_dir])
            parts << theme.format_text(dir_display, :statusbar_path)
          end

          # Permission mode
          if @sessionbar_info[:mode]
            mode_color = mode_color_for(@sessionbar_info[:mode])
            parts << @pastel.public_send(mode_color, @sessionbar_info[:mode])
          end

          # Model
          if @sessionbar_info[:model]
            parts << theme.format_text(@sessionbar_info[:model], :statusbar_secondary)
          end

          # Tasks count
          parts << theme.format_text("#{@sessionbar_info[:tasks]} tasks", :statusbar_secondary)

          # Cost
          cost_display = format("$%.1f", @sessionbar_info[:cost])
          parts << theme.format_text(cost_display, :statusbar_secondary)

          " " + parts.join(separator)
        end
        
        # Truncate session bar content to fit within max length
        # @param content [String] Full session bar content with ANSI codes
        # @param max_length [Integer] Maximum visible length
        # @return [String] Truncated content
        private def truncate_sessionbar_content(content, max_length)
          # Strip ANSI codes to calculate visible length
          visible_content = strip_ansi_codes(content)
          visible_width = calculate_display_width(visible_content)
          
          return content if visible_width <= max_length
          
          # Truncate from the end with "..." indicator
          chars = visible_content.chars
          current_width = 0
          truncate_at = 0
          
          chars.each_with_index do |char, idx|
            char_width = char_display_width(char)
            if current_width + char_width + 3 > max_length  # Reserve 3 for "..."
              truncate_at = idx
              break
            end
            current_width += char_width
            truncate_at = idx + 1
          end
          
          # For simplicity with ANSI codes, just show first part + ...
          # This is a simplified version - proper implementation would preserve ANSI codes
          visible_content[0...truncate_at] + "..."
        end
        
        # Calculate how many rows the session bar will occupy
        # @return [Integer] Number of rows needed
        private def calculate_sessionbar_height
          return 1 unless @sessionbar_info[:working_dir]
          
          # Session bar always renders on one line (we truncate if needed)
          1
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
            :magenta
          when /confirm_safes/
            :cyan
          else
            :white
          end
        end

        def status_color_for(status)
          case status.to_s.downcase
          when 'idle'
            :cyan  # Use darker cyan for idle state
          when 'working'
            :yellow  # Use yellow to highlight working state
          else
            :cyan
          end
        end

        def get_status_indicator(status, color)
          case status.to_s.downcase
          when 'working'
            # Update animation frame if enough time has passed
            now = Time.now
            if now - @last_animation_update >= 0.3
              @animation_frame = (@animation_frame + 1) % @working_frames.length
              @last_animation_update = now
            end
            @pastel.public_send(color, @working_frames[@animation_frame])
          else
            @pastel.public_send(color, "●")  # Idle indicator with same color as text
          end
        end

        def format_tips(message, type)
          # Limit message length to prevent line wrapping
          # Reserve space for prefix like "[Warn] " (about 8 chars) and some margin
          max_length = @width - 10
          if message.length > max_length
            message = message[0...(max_length - 3)] + "..."
          end
          
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

        # Format user tip (usage suggestion) with lightbulb icon
        # @param tip [String] Tip message
        # @return [String] Formatted tip with styling
        def format_user_tip(tip)
          # Limit message length to prevent line wrapping
          max_length = @width - 5  # Reserve space for icon and margins
          if tip.length > max_length
            tip = tip[0...(max_length - 3)] + "..."
          end
          
          # Use lightbulb icon and dim cyan color for subtle appearance
          @pastel.dim(@pastel.cyan("💡 #{tip}"))
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
