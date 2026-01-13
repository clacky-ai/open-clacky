# frozen_string_literal: true

require "readline"
require "pastel"
require "tty-screen"

module Clacky
  module UI
    # Enhanced input prompt with box drawing and status info
    class Prompt
      def initialize
        @pastel = Pastel.new
      end

      # Read user input with enhanced prompt box
      # @param prefix [String] Prompt prefix (default: "You:")
      # @param placeholder [String] Placeholder text (not shown when using Readline)
      # @return [String, nil] User input or nil on EOF
      def read_input(prefix: "You:", placeholder: nil)
        width = [TTY::Screen.width - 5, 70].min

        # Display complete box frame first
        puts @pastel.dim("╭" + "─" * width + "╮")

        # Empty input line with borders (width - 2 for left/right padding)
        padding = " " * (width - 2)
        puts @pastel.dim("│ #{padding} │")

        # Bottom border
        puts @pastel.dim("╰" + "─" * width + "╯")

        # Move cursor back up to input line (2 lines up)
        print "\e[2A"  # Move up 2 lines
        print "\r"     # Move to beginning of line
        print "\e[2C"  # Move right 2 chars to after "│ "

        # Read input with Readline
        prompt_text = @pastel.bright_blue("#{prefix} ")
        input = read_with_readline(prompt_text)

        # After input, clear the input box completely
        # Move cursor up 2 lines to the top of the box
        print "\e[2A"
        print "\r"
        
        # Clear all 3 lines of the box
        3.times do
          print "\e[2K"  # Clear entire line
          print "\e[1B"  # Move down 1 line
          print "\r"     # Move to beginning of line
        end
        
        # Move cursor back up to where the box started
        print "\e[3A"
        print "\r"
        
        input
      end

      private

      def read_with_readline(prompt)
        Readline.readline(prompt, true)
      rescue Interrupt
        puts
        nil
      end
    end
  end
end
