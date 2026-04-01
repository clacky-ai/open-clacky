# frozen_string_literal: true

module Clacky
  module Utils
    # Detects the current operating system environment and desktop path.
    module EnvironmentDetector
      # Detect OS type.
      # @return [Symbol] :wsl, :linux, :macos, or :unknown
      def self.os_type
        return @os_type if defined?(@os_type)

        @os_type = if wsl?
          :wsl
        elsif RUBY_PLATFORM.include?("darwin")
          :macos
        elsif RUBY_PLATFORM.include?("linux")
          :linux
        else
          :unknown
        end
      end

      # Human-readable OS label for injection into session context.
      def self.os_label
        case os_type
        when :wsl    then "WSL/Windows"
        when :macos  then "macOS"
        when :linux  then "Linux"
        else              "Unknown"
        end
      end

      # Detect the desktop directory path for the current environment.
      # @return [String, nil] absolute path to desktop, or nil if not found
      def self.desktop_path
        return @desktop_path if defined?(@desktop_path)

        @desktop_path = case os_type
        when :wsl
          wsl_desktop_path
        when :macos
          macos_desktop_path
        when :linux
          linux_desktop_path
        else
          fallback_desktop_path
        end
      end

      def self.wsl?
        File.exist?("/proc/version") &&
          File.read("/proc/version").downcase.include?("microsoft")
      rescue
        false
      end

      private_class_method def self.wsl_desktop_path
        if Utils::Encoding.cmd_to_utf8(`which powershell.exe 2>/dev/null`).strip.empty?
          return fallback_desktop_path
        end

        # powershell.exe on Chinese Windows outputs GBK bytes; decode explicitly
        win_path = Utils::Encoding.cmd_to_utf8(
          `powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("Desktop")' 2>/dev/null`
        ).strip.tr("\r\n", "")
        return fallback_desktop_path if win_path.empty?

        # wslpath output is UTF-8 (Linux side)
        linux_path = Utils::Encoding.cmd_to_utf8(`wslpath '#{win_path}' 2>/dev/null`, source_encoding: "UTF-8").strip
        return linux_path if !linux_path.empty? && Dir.exist?(linux_path)

        fallback_desktop_path
      end

      private_class_method def self.linux_desktop_path
        path = Utils::Encoding.cmd_to_utf8(`xdg-user-dir DESKTOP 2>/dev/null`, source_encoding: "UTF-8").strip
        return path if !path.empty? && path != Dir.home && Dir.exist?(path)

        fallback_desktop_path
      end

      private_class_method def self.macos_desktop_path
        path = Utils::Encoding.cmd_to_utf8(`osascript -e 'POSIX path of (path to desktop)' 2>/dev/null`, source_encoding: "UTF-8").strip.chomp("/")
        return path if !path.empty? && Dir.exist?(path)

        fallback_desktop_path
      end

      private_class_method def self.fallback_desktop_path
        [
          File.join(Dir.home, "Desktop"),
          File.join(Dir.home, "桌面"),
        ].find { |p| Dir.exist?(p) }
      end
    end
  end
end
