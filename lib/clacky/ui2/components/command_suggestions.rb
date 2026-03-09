# frozen_string_literal: true

require "pastel"
require_relative "../theme_manager"

module Clacky
  module UI2
    module Components
      # CommandSuggestions displays a dropdown menu of available commands
      # Supports keyboard navigation and filtering
      class CommandSuggestions
        attr_reader :selected_index, :visible

        # System commands available by default
        SYSTEM_COMMANDS = [
          { command: "/clear", description: "Clear chat history and restart session" },
          { command: "/config", description: "Open configuration (models, API keys, settings)" },
          { command: "/undo", description: "Undo the last task and restore previous state" },
          { command: "/help", description: "Show help information" },
          { command: "/exit", description: "Exit the chat session" },
          { command: "/quit", description: "Quit the application" }
        ].freeze

        def initialize
          @pastel = Pastel.new
          @commands = []
          @filtered_commands = []
          @selected_index = 0
          @visible = false
          @filter_text = ""
          @skill_commands = []
          
          # Initialize with system commands
          update_commands
        end

        # Get current theme from ThemeManager
        def theme
          UI2::ThemeManager.current_theme
        end

        # Load skill commands from skill loader, filtered by agent profile whitelist
        # @param skill_loader [Clacky::SkillLoader] The skill loader instance
        # @param agent_profile [Clacky::AgentProfile, nil] Current agent profile (nil = allow all)
        def load_skill_commands(skill_loader, agent_profile = nil)
          return unless skill_loader

          skills = skill_loader.user_invocable_skills
          skills = skills.select { |s| agent_profile.skill_allowed?(s.identifier) } if agent_profile

          @skill_commands = skills.map do |skill|
            {
              command: skill.slash_command,
              description: skill.description || "No description available",
              type: :skill,
              argument_hint: skill.argument_hint
            }
          end

          update_commands
        end

        # Show the suggestions dropdown
        # @param filter_text [String] Initial filter text (everything after the /)
        def show(filter_text = "")
          @filter_text = filter_text
          @visible = true
          update_filtered_commands
          @selected_index = 0
        end

        # Hide the suggestions dropdown
        def hide
          @visible = false
          @filter_text = ""
          @filtered_commands = []
          @selected_index = 0
        end

        # Update filter text and refresh filtered commands
        # @param text [String] Filter text (everything after the /)
        def update_filter(text)
          @filter_text = text
          update_filtered_commands
          @selected_index = 0  # Reset selection when filter changes
        end

        # Move selection up
        def select_previous
          return if @filtered_commands.empty?
          @selected_index = (@selected_index - 1) % @filtered_commands.size
        end

        # Move selection down
        def select_next
          return if @filtered_commands.empty?
          @selected_index = (@selected_index + 1) % @filtered_commands.size
        end

        # Get the currently selected command
        # @return [Hash, nil] Selected command hash or nil if none selected
        def selected_command
          return nil if @filtered_commands.empty?
          @filtered_commands[@selected_index]
        end

        # Get the currently selected command text
        # @return [String, nil] Selected command text or nil if none selected
        def selected_command_text
          cmd = selected_command
          cmd ? cmd[:command] : nil
        end

        # Get the argument hint for the currently selected command
        # @return [String, nil] Argument hint string or nil if none
        def selected_argument_hint
          cmd = selected_command
          cmd ? cmd[:argument_hint] : nil
        end

        # Check if there are any suggestions to show
        # @return [Boolean]
        def has_suggestions?
          @visible && !@filtered_commands.empty?
        end

        # Calculate required height for rendering
        # @return [Integer] Number of lines needed
        def required_height
          return 0 unless @visible
          return 0 if @filtered_commands.empty?

          # Header + commands + footer
          1 + [@filtered_commands.size, 5].min + 1  # Max 5 visible items
        end

        # Render the suggestions dropdown
        # @param row [Integer] Starting row position
        # @param col [Integer] Starting column position
        # @param width [Integer] Maximum width for the dropdown
        # @return [String] Rendered output
        def render(row:, col:, width: 60)
          return "" unless @visible
          return "" if @filtered_commands.empty?

          output = []
          max_items = 5  # Maximum visible items
          visible_commands = @filtered_commands.take(max_items)

          # Header
          header = @pastel.dim("┌─ Commands ") + @pastel.dim("─" * (width - 13)) + @pastel.dim("┐")
          output << position_cursor(row, col) + header

          # Items
          visible_commands.each_with_index do |cmd, idx|
            is_selected = (idx == @selected_index)
            line = render_command_item(cmd, is_selected, width)
            output << position_cursor(row + 1 + idx, col) + line
          end

          # Footer with navigation hint
          footer_row = row + 1 + visible_commands.size
          total = @filtered_commands.size
          hint = total > max_items ? " (#{total - max_items} more...)" : ""
          footer = @pastel.dim("└") + @pastel.dim("─" * (width - 2)) + @pastel.dim("┘")
          output << position_cursor(footer_row, col) + footer

          output.join
        end

        # Clear the rendered dropdown from screen
        # @param row [Integer] Starting row position
        # @param col [Integer] Starting column position
        def clear_from_screen(row:, col:)
          return unless @visible

          height = required_height
          output = []
          
          height.times do |i|
            output << position_cursor(row + i, col) + clear_line
          end
          
          print output.join
          flush
        end

        private

        # Update the complete commands list (system + skills)
        private def update_commands
          system_cmds = SYSTEM_COMMANDS.map { |c| c.merge(type: :system) }
          @commands = system_cmds + @skill_commands
          update_filtered_commands if @visible
        end

        # Update filtered commands based on current filter text
        private def update_filtered_commands
          if @filter_text.empty?
            @filtered_commands = @commands
          else
            filter_lower = @filter_text.downcase
            @filtered_commands = @commands.select do |cmd|
              # Remove leading / for comparison
              cmd_name = cmd[:command].sub(/^\//, "")
              # Only match command name, not description
              cmd_name.downcase.start_with?(filter_lower)
            end
          end
        end

        # Render a single command item
        # @param cmd [Hash] Command hash with :command and :description
        # @param selected [Boolean] Whether this item is selected
        # @param width [Integer] Maximum width
        # @return [String] Rendered item
        private def render_command_item(cmd, selected, width)
          # Calculate available space
          available = width - 4  # Account for borders and padding

          # Format command (e.g., "/clear")
          command_text = cmd[:command]
          
          # Format description
          max_desc_length = available - command_text.length - 3  # 3 for spacing
          description = truncate_text(cmd[:description], max_desc_length)

          # Build line
          if selected
            # Highlighted selection
            line = @pastel.on_blue(@pastel.white(" #{command_text} "))
            line += @pastel.on_blue(@pastel.dim(" #{description}"))
            # Pad to full width
            content_length = command_text.length + description.length + 2
            padding = " " * [available - content_length, 0].max
            line += @pastel.on_blue(padding)
            @pastel.dim("│") + line + @pastel.dim("│")
          else
            # Normal item
            line = " #{@pastel.cyan(command_text)} #{@pastel.dim(description)}"
            # Pad to full width
            content_length = strip_ansi(line).length
            padding = " " * [available - content_length, 0].max
            @pastel.dim("│") + line + padding + @pastel.dim("│")
          end
        end

        # Truncate text to maximum length
        # @param text [String] Text to truncate
        # @param max_length [Integer] Maximum length
        # @return [String] Truncated text
        private def truncate_text(text, max_length)
          return "" if max_length <= 3
          return text if text.length <= max_length

          text[0...(max_length - 3)] + "..."
        end

        # Strip ANSI codes from text
        # @param text [String] Text with ANSI codes
        # @return [String] Plain text
        private def strip_ansi(text)
          text.gsub(/\e\[[0-9;]*m/, '')
        end

        # Position cursor at specific row and column
        # @param row [Integer] Row position (0-indexed)
        # @param col [Integer] Column position (0-indexed)
        # @return [String] ANSI escape sequence
        private def position_cursor(row, col)
          "\e[#{row + 1};#{col + 1}H"
        end

        # Clear current line
        # @return [String] ANSI escape sequence
        private def clear_line
          "\e[2K"
        end

        # Flush output to terminal
        private def flush
          $stdout.flush
        end
      end
    end
  end
end
