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

      # Open a file with the OS-default application.
      # On WSL, uses "cmd.exe /c start" instead of explorer.exe so the opened
      # window receives foreground focus even when called from a background
      # thread (e.g. WEBrick request handler).
      # @param path [String] Linux-side file path
      # @return [Boolean, nil] true/false from system(), or nil on unsupported OS
      def self.open_file(path)
        case os_type
        when :macos then system("open", path)
        when :linux then system("xdg-open", path)
        when :wsl
          win_path = linux_to_win_path(path)
          system("cmd.exe", "/c", "start", "", win_path)
        end
      end

      # Convert a Windows-style path to a WSL/Linux-side path.
      # e.g. "C:/Users/foo/file.txt" → "/mnt/c/Users/foo/file.txt"
      # Returns the original path unchanged on non-WSL or if already a Linux path.
      # @param path [String]
      # @return [String]
      def self.win_to_linux_path(path)
        return path unless os_type == :wsl && path.match?(/\A[A-Za-z]:[\/\\]/)

        drive = path[0].downcase
        rest  = path[2..].gsub("\\", "/")
        "/mnt/#{drive}#{rest}"
      end

      # Convert a Linux-side path to a Windows-style path via wslpath.
      # e.g. "/mnt/c/Users/foo/file.txt" → "C:\Users\foo\file.txt"
      # Returns the original path unchanged on non-WSL.
      # @param path [String]
      # @return [String]
      def self.linux_to_win_path(path)
        return path unless os_type == :wsl

        Clacky::Utils::Encoding.cmd_to_utf8(
          `wslpath -w '#{path.gsub("'", "'\''")}'`,
          source_encoding: "UTF-8"
        ).strip
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

      # Build a command through the user's shell so version managers and PATH
      # hooks are available. macOS commonly keeps Node manager setup in
      # interactive rc files; elsewhere, prefer non-interactive startup to avoid
      # terminal-only shell setup blocking Open3.
      def self.login_shell_command(command)
        shell = ENV["SHELL"].to_s
        shell = "/bin/bash" if shell.empty? || !File.executable?(shell)
        shell = "/bin/bash" unless %w[zsh bash fish].include?(File.basename(shell))
        return [shell, "-l", "-i", "-c", command] if os_type == :macos

        [shell, "-l", "-c", command]
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
