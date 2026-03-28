# frozen_string_literal: true

require "tty-markdown"
require_relative "theme_manager"

module Clacky
  module UI2
    # MarkdownRenderer handles rendering Markdown content with syntax highlighting
    module MarkdownRenderer
      class << self
        # Render markdown content with theme-aware colors
        # @param content [String] Markdown content to render
        # @return [String] Rendered content with ANSI colors
        def render(content)
          return content if content.nil? || content.empty?

          # Get current theme colors
          theme = ThemeManager.current_theme

          # Configure tty-markdown with custom theme and symbols
          parsed = TTY::Markdown.parse(content, 
            theme: theme_colors,
            symbols: custom_symbols,
            width: TTY::Screen.width - 4  # Leave some margin
          )

          parsed
        rescue StandardError => e
          # Fallback to plain content if rendering fails
          content
        end

        # Check if content looks like markdown
        # @param content [String] Content to check
        # @return [Boolean] true if content appears to be markdown
        def markdown?(content)
          return false if content.nil? || content.empty?

          # Check for common markdown patterns
          content.match?(/^#+ /) ||           # Headers
            content.match?(/```/) ||          # Code blocks
            content.match?(/^\s*[-*+] /) ||   # Unordered lists
            content.match?(/^\s*\d+\. /) ||   # Ordered lists
            content.match?(/\[.+\]\(.+\)/) || # Links
            content.match?(/^\s*> /) ||       # Blockquotes
            content.match?(/\*\*.+\*\*/) ||   # Bold
            content.match?(/`.+`/) ||         # Inline code
            content.match?(/^\s*\|.+\|/) ||   # Tables
            content.match?(/^---+$/)          # Horizontal rules
        end


        # Get theme-aware colors for markdown rendering
        # @return [Hash] Color configuration for tty-markdown
        def theme_colors
          theme = ThemeManager.current_theme

          # Map our theme colors to tty-markdown's expected format
          # Note: theme.colors values are already arrays, so we need to flatten when adding styles
          {
            # Headers use info color (cyan/blue)
            h1: Array(theme.colors[:info]) + [:bold],
            h2: Array(theme.colors[:info]) + [:bold],
            h3: Array(theme.colors[:info]),
            h4: Array(theme.colors[:info]),
            h5: Array(theme.colors[:info]),
            h6: Array(theme.colors[:info]),
            # Horizontal rule - make it subtle (dim gray)
            hr: [:bright_black],
            # Code blocks use dim color
            code: Array(theme.colors[:thinking]),
            # Links use success color (green)
            link: Array(theme.colors[:success]),
            # Lists use default text color
            list: [:bright_white],
            # Strong/bold use bright white
            strong: [:bright_white, :bold],
            # Emphasis/italic use white
            em: [:white],
            # Note/blockquote use dim color
            note: Array(theme.colors[:thinking]),
            quote: Array(theme.colors[:thinking]),
          }
        end

        # Get custom symbols for markdown rendering
        # @return [Hash] Symbol configuration for tty-markdown
        def custom_symbols
          {
            override: {
              # Make horizontal rule simpler - just a line without decorative diamonds
              diamond: "",
              line: "-"
            }
          }
        end
      end
    end
  end
end
