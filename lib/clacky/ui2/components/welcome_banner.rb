# frozen_string_literal: true

require "pastel"
require_relative "../../version"

module Clacky
  module UI2
    module Components
      # WelcomeBanner displays the startup screen with ASCII logo, tagline, tips, and agent info
      class WelcomeBanner
        LOGO = <<~'LOGO'
           ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗  ██████╗██╗  ██╗██╗   ██╗
          ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██╔════╝██║ ██╔╝╚██╗ ██╔╝
          ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║     █████╔╝  ╚████╔╝
          ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║     ██╔═██╗   ╚██╔╝
          ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚██████╗██║  ██╗   ██║
           ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝
        LOGO

        TAGLINE = "[>] AI Coding Assistant & Technical Co-founder"

        TIPS = [
          "[*] Ask questions, edit files, or run commands",
          "[*] Be specific for the best results",
          "[*] Create .clackyrules to customize interactions",
          "[*] Type /help for more commands"
        ].freeze

        def initialize
          @pastel = Pastel.new
        end

        # Render only the logo (ASCII art)
        # @return [String] Formatted logo only
        def render_logo
          lines = []
          lines << ""
          lines << @pastel.bright_green(LOGO)
          lines << ""
          lines.join("\n")
        end

        # Render startup banner
        # @return [String] Formatted startup banner
        def render_startup
          lines = []
          lines << ""
          lines << @pastel.bright_green(LOGO)
          lines << ""
          lines << @pastel.bright_cyan(TAGLINE)
          lines << @pastel.dim("    Version #{Clacky::VERSION}")
          lines << ""
          TIPS.each do |tip|
            lines << @pastel.dim(tip)
          end
          lines << ""
          lines.join("\n")
        end

        # Render agent welcome section
        # @param working_dir [String] Working directory
        # @param mode [String] Permission mode
        # @return [String] Formatted agent welcome section
        def render_agent_welcome(working_dir:, mode:)
          lines = []
          lines << ""
          lines << separator("=")
          lines << @pastel.bright_green("[+] AGENT MODE INITIALIZED")
          lines << separator("=")
          lines << ""
          lines << info_line("Working Directory", working_dir)
          lines << info_line("Permission Mode", mode)
          lines << ""
          lines << @pastel.dim("[!] Type 'exit' or 'quit' to terminate session")
          lines << separator("-")
          lines << ""
          lines.join("\n")
        end

        # Render full welcome (startup + agent info)
        # @param working_dir [String] Working directory
        # @param mode [String] Permission mode
        # @return [String] Full welcome content
        def render_full(working_dir:, mode:)
          render_startup + render_agent_welcome(
            working_dir: working_dir,
            mode: mode
          )
        end

        private

        def info_line(label, value)
          label_text = @pastel.cyan("[#{label}]")
          value_text = @pastel.white(value)
          "    #{label_text} #{value_text}"
        end

        def separator(char = "-")
          @pastel.dim(char * 80)
        end
      end
    end
  end
end
