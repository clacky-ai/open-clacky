# frozen_string_literal: true

require "socket"

module Clacky
  module Utils
    # Detects a running browser (Chrome/Edge) that has remote debugging enabled.
    #
    # Detection strategy (in priority order):
    #
    #   1. Scan known UserData directories for DevToolsActivePort file.
    #      This file contains the exact port + WS path — most reliable.
    #      Returns { mode: :ws_endpoint, value: "ws://127.0.0.1:PORT/PATH" }
    #
    #   2. TCP port scan on common remote debugging ports (9222–9224).
    #      Chrome 146+ dropped HTTP /json/version, so we just probe TCP connectivity
    #      and hand off to chrome-devtools-mcp via --browserUrl.
    #      Returns { mode: :browser_url, value: "http://127.0.0.1:PORT" }
    #
    #   3. Nothing found → returns nil (caller should show guidance to user).
    #
    # Supported environments: WSL, Linux, macOS.
    module BrowserDetector
      # Ports to probe when DevToolsActivePort file is not found.
      TCP_PROBE_PORTS = [9222, 9223, 9224].freeze
      TCP_PROBE_TIMEOUT = 0.5 # seconds

      # Detect a running debuggable browser.
      # @return [Hash, nil] { mode: :ws_endpoint|:browser_url, value: String } or nil
      def self.detect
        result = detect_via_active_port_file
        result ||= detect_via_tcp_probe
        result
      end

      # -----------------------------------------------------------------------
      # Strategy 1: DevToolsActivePort file scan
      # -----------------------------------------------------------------------

      # @return [Hash, nil]
      def self.detect_via_active_port_file
        user_data_dirs.each do |dir|
          port_file = File.join(dir, "DevToolsActivePort")
          next unless File.exist?(port_file)

          ws = parse_active_port_file(port_file)
          return { mode: :ws_endpoint, value: ws } if ws
        end
        nil
      end

      # @return [Hash, nil]
      def self.detect_via_tcp_probe
        TCP_PROBE_PORTS.each do |port|
          return { mode: :browser_url, value: "http://127.0.0.1:#{port}" } if tcp_open?("127.0.0.1", port)
        end
        nil
      end

      # -----------------------------------------------------------------------
      # UserData directory candidates per OS
      # -----------------------------------------------------------------------

      # Returns ordered list of candidate UserData dirs to check.
      # @return [Array<String>]
      def self.user_data_dirs
        case EnvironmentDetector.os_type
        when :wsl   then wsl_user_data_dirs
        when :linux then linux_user_data_dirs
        when :macos then macos_user_data_dirs
        else []
        end
      end

      # WSL: Chrome/Edge run on Windows side — resolve via LOCALAPPDATA.
      private_class_method def self.wsl_user_data_dirs
        appdata = Utils::Encoding.cmd_to_utf8(
          `powershell.exe -NoProfile -Command '$env:LOCALAPPDATA' 2>/dev/null`
        ).strip.tr("\r\n", "")
        return [] if appdata.empty?

        win_paths = [
          "#{appdata}\\Microsoft\\Edge\\User Data",
          "#{appdata}\\Google\\Chrome\\User Data",
          "#{appdata}\\Google\\Chrome Beta\\User Data",
          "#{appdata}\\Google\\Chrome SxS\\User Data",
        ]

        win_paths.filter_map do |win_path|
          linux_path = Utils::Encoding.cmd_to_utf8(
            `wslpath '#{win_path}' 2>/dev/null`, source_encoding: "UTF-8"
          ).strip
          linux_path.empty? ? nil : linux_path
        end
      end

      # Linux: standard XDG config paths for Chrome and Edge.
      private_class_method def self.linux_user_data_dirs
        config_home = ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config")
        [
          File.join(config_home, "microsoft-edge"),
          File.join(config_home, "google-chrome"),
          File.join(config_home, "google-chrome-beta"),
          File.join(config_home, "google-chrome-unstable"),
        ]
      end

      # macOS: Application Support paths for Chrome and Edge.
      private_class_method def self.macos_user_data_dirs
        base = File.join(Dir.home, "Library", "Application Support")
        [
          File.join(base, "Microsoft Edge"),
          File.join(base, "Google", "Chrome"),
          File.join(base, "Google", "Chrome Beta"),
          File.join(base, "Google", "Chrome Canary"),
        ]
      end

      # -----------------------------------------------------------------------
      # Helpers
      # -----------------------------------------------------------------------

      # Parse DevToolsActivePort file.
      # Format: first line = port number, second line = WS path
      # @return [String, nil] ws://127.0.0.1:PORT/PATH or nil on parse error
      private_class_method def self.parse_active_port_file(path)
        lines = File.read(path, encoding: "utf-8").split("\n").map(&:strip).reject(&:empty?)
        return nil unless lines.size >= 2

        port = lines[0].to_i
        ws_path = lines[1]
        return nil if port <= 0 || port > 65_535 || ws_path.empty?

        "ws://127.0.0.1:#{port}#{ws_path}"
      rescue StandardError
        nil
      end

      # Probe TCP port with a short timeout.
      # Chrome 146+ dropped HTTP /json/version — TCP reachability is sufficient.
      # @return [Boolean]
      private_class_method def self.tcp_open?(host, port)
        Socket.tcp(host, port, connect_timeout: TCP_PROBE_TIMEOUT) { true }
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError, Errno::EHOSTUNREACH
        false
      end
    end
  end
end
