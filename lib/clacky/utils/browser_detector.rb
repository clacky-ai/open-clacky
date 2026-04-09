# frozen_string_literal: true

require "socket"

module Clacky
  module Utils
    # Detects a running browser (Chrome/Edge) that has remote debugging enabled.
    #
    # Detection strategy:
    #
    #   1. Scan known UserData directories for DevToolsActivePort file.
    #      This file contains the exact port + WS path — most reliable.
    #      Returns { mode: :ws_endpoint, value: "ws://127.0.0.1:PORT/PATH" }
    #
    #   2. Verify the port is actually reachable via TCP probe.
    #
    #   3. Nothing found or port unreachable → returns nil (browser not running).
    #
    # Supported environments: WSL, Linux, macOS.
    module BrowserDetector

      # Detect a running debuggable browser.
      # Scans for DevToolsActivePort file across all platforms (macOS/Linux/WSL).
      # Returns the detected WebSocket endpoint only if the port is reachable.
      # @return [Hash] { mode: :ws_endpoint, value: String, status: :ok|:not_found }
      def self.detect
        os = EnvironmentDetector.os_type
        Clacky::Logger.debug("[BrowserDetector] Starting browser detection (OS: #{os})...")
        
        detected = detect_via_active_port_file
        
        unless detected
          Clacky::Logger.warn("[BrowserDetector] ✗ No reachable browser found")
          return { status: :not_found }
        end
        
        Clacky::Logger.info("[BrowserDetector] ✓ Browser detected and reachable: #{detected[:mode]} → #{detected[:value]}")
        detected.merge(status: :ok)
      end

      # -----------------------------------------------------------------------
      # DevToolsActivePort file scan
      # -----------------------------------------------------------------------

      # @return [Hash, nil]
      def self.detect_via_active_port_file
        Clacky::Logger.debug("[BrowserDetector] Scanning UserData directories for DevToolsActivePort...")
        
        dirs = user_data_dirs
        Clacky::Logger.debug("[BrowserDetector] Candidate directories: #{dirs.size} found")
        
        dirs.each do |dir|
          port_file = File.join(dir, "DevToolsActivePort")
          next unless File.exist?(port_file)

          Clacky::Logger.debug("[BrowserDetector] Found DevToolsActivePort: #{port_file}")
          
          ws = parse_active_port_file(port_file)
          unless ws
            Clacky::Logger.debug("[BrowserDetector] ✗ Failed to parse #{port_file}")
            next
          end
          
          Clacky::Logger.debug("[BrowserDetector] Parsed WS endpoint: #{ws}")
          
          # ⭐️ Verify port BEFORE returning — skip stale files
          candidate = { mode: :ws_endpoint, value: ws }
          if verify_port(candidate)
            Clacky::Logger.debug("[BrowserDetector] ✓ Port is reachable, using this endpoint")
            return candidate
          else
            Clacky::Logger.debug("[BrowserDetector] ✗ Port not reachable, trying next directory...")
          end
        end
        
        Clacky::Logger.debug("[BrowserDetector] No reachable browser found")
        nil
      end

      # Verify that the detected browser port is actually reachable.
      # Extracts port from ws:// URL and attempts TCP connection.
      # @param detected [Hash] { mode: :ws_endpoint, value: String }
      # @return [Boolean] true if port is open and reachable
      def self.verify_port(detected)
        return false unless detected

        port = case detected[:mode]
        when :ws_endpoint
          # ws://127.0.0.1:9222/devtools/...
          detected[:value][/ws:\/\/127\.0\.0\.1:(\d+)/, 1]&.to_i
        end

        return false unless port && port > 0

        reachable = tcp_open?("127.0.0.1", port)
        Clacky::Logger.debug("[BrowserDetector] Port #{port} reachable: #{reachable}")
        reachable
      end

      # -----------------------------------------------------------------------
      # UserData directory candidates per OS
      # -----------------------------------------------------------------------

      # Returns ordered list of candidate UserData dirs to check.
      # @return [Array<String>]
      def self.user_data_dirs
        os = EnvironmentDetector.os_type
        Clacky::Logger.debug("[BrowserDetector] Detected OS: #{os}")
        
        case os
        when :wsl   then wsl_user_data_dirs
        when :linux then linux_user_data_dirs
        when :macos then macos_user_data_dirs
        else
          Clacky::Logger.warn("[BrowserDetector] Unknown OS type: #{os}")
          []
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

      # Probe TCP port with a short timeout to verify port is actually reachable.
      # @param host [String] hostname
      # @param port [Integer] port number
      # @return [Boolean] true if port is open and reachable
      private_class_method def self.tcp_open?(host, port)
        Socket.tcp(host, port, connect_timeout: 0.5) { true }
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError, Errno::EHOSTUNREACH
        false
      end
    end
  end
end
