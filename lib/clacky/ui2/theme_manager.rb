# frozen_string_literal: true

require_relative "themes/base_theme"
require_relative "themes/hacker_theme"
require_relative "themes/minimal_theme"

module Clacky
  module UI2
    # ThemeManager handles theme registration and switching
    class ThemeManager
      class << self
        def instance
          @instance ||= new
        end

        # Delegate methods to instance
        def current_theme
          instance.current_theme
        end

        def set_theme(name)
          instance.set_theme(name)
        end

        def available_themes
          instance.available_themes
        end

        def register_theme(name, theme_class)
          instance.register_theme(name, theme_class)
        end
      end

      def initialize
        @themes = {}
        @current_theme = nil
        @is_dark_background = nil  # Store detected background mode
        register_default_themes
        set_theme(:hacker)
      end

      # Set the detected terminal background mode
      # This should be called BEFORE UI starts (from CLI)
      # @param is_dark [Boolean] true if dark background, false if light
      def set_background_mode(is_dark)
        @is_dark_background = is_dark
        # Pass to current theme if already initialized
        @current_theme&.set_background_mode(is_dark)
      end

      # Get the detected background mode
      # @return [Boolean, nil] true if dark, false if light, nil if not detected
      def dark_background?
        @is_dark_background
      end

      def current_theme
        @current_theme
      end

      def set_theme(name)
        name = name.to_sym
        raise ArgumentError, "Unknown theme: #{name}" unless @themes.key?(name)

        @current_theme = @themes[name].new
        # Pass background mode to new theme if already detected
        @current_theme.set_background_mode(@is_dark_background) unless @is_dark_background.nil?
      end

      def available_themes
        @themes.keys
      end

      def register_theme(name, theme_class)
        @themes[name.to_sym] = theme_class
      end


      def register_default_themes
        register_theme(:hacker, Themes::HackerTheme)
        register_theme(:minimal, Themes::MinimalTheme)
      end
    end
  end
end
