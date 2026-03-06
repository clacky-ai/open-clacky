# frozen_string_literal: true

require "shellwords"
require "socket"
require "uri"
require_relative "base"
require_relative "shell"

module Clacky
  module Tools
    class Browser < Base
      self.tool_name = "browser"
      self.tool_description = <<~DESC
        Use this tool ONLY when the task requires the user's login session, such as:
        - Posting on social media
        - Accessing account pages or dashboards
        - Filling forms while logged in
        - Any action that requires authentication

        Do NOT use this tool for:
        - Simply opening or visiting a URL
        - General web search
        - Fetching public information

        For those cases, use web_search or web_fetch instead.
      DESC
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          command: {
            type: "string",
            description: "agent-browser command and arguments. Examples: 'open https://example.com', 'snapshot -i', 'click @e1', 'fill @e2 \"hello\"', 'get text @e3', 'screenshot', 'scroll down'"
          },
          session: {
            type: "string",
            description: "Named session for parallel browser instances (optional, defaults to shared session)"
          },
          isolated: {
            type: "boolean",
            description: "Use isolated browser without user's cookies/login (default: false, uses user's Chrome)"
          }
        },
        required: ["command"]
      }

      AGENT_BROWSER_BIN = "agent-browser"
      DEFAULT_SESSION_NAME = "clacky"
      CHROME_DEBUG_PORT = 9222
      CHROME_DEBUG_PAGE = "chrome://inspect/#remote-debugging"

      def execute(command:, session: nil, isolated: nil, working_dir: nil)
        # Default: try to connect to user's Chrome (unless isolated mode requested)
        use_auto_connect = !isolated
        persistent_session_name = nil

        # Ensure Chrome is reachable via CDP before invoking agent-browser.
        # agent-browser silently falls back to launching a new Chromium when --auto-connect
        # fails (exit 0), so we must detect and handle this ourselves.
        if use_auto_connect && !chrome_debug_running?
          launch_result = ensure_chrome_debug_ready
          if launch_result == :not_installed
            # Chrome not installed: fall back to isolated mode with a persistent
            # session so the user only needs to log in once.
            use_auto_connect = false
            persistent_session_name = DEFAULT_SESSION_NAME
          elsif !launch_result
            return chrome_setup_instructions
          end
        end

        full_command = build_command(command, session, auto_connect: use_auto_connect, session_name: persistent_session_name)

        result = Shell.new.execute(command: full_command, hard_timeout: 60)

        # Safety net: catch explicit connection errors in stderr
        if use_auto_connect && !result[:success] && result[:stderr].to_s.include?("Could not connect")
          return chrome_setup_instructions
        end

        result[:command] = command
        result
      rescue StandardError => e
        { error: "Failed to run agent-browser: #{e.message}" }
      end

      def format_call(args)
        cmd = args[:command] || args["command"] || ""
        session = args[:session] || args["session"]
        session_label = session ? " [#{session}]" : ""
        "browser(#{cmd})#{session_label}"
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error][0..80]}"
        elsif result[:success]
          stdout = result[:stdout] || ""
          lines = stdout.lines.size
          "[OK] #{lines > 0 ? "#{lines} lines" : "Done"}"
        else
          stderr = result[:stderr] || "Failed"
          "[Failed] #{stderr[0..80]}"
        end
      end

      private

      def build_command(command, session, auto_connect: false, session_name: nil)
        parts = [AGENT_BROWSER_BIN]
        parts << "--auto-connect" if auto_connect
        parts += ["--session", Shellwords.escape(session)] if session
        parts += ["--session-name", Shellwords.escape(session_name)] if session_name
        parts << command
        parts.join(" ")
      end

      def chrome_debug_running?
        TCPSocket.new("127.0.0.1", CHROME_DEBUG_PORT).close
        true
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError
        false
      end

      def find_chrome
        @chrome_path ||= resolve_chrome_path
      end

      def resolve_chrome_path
        %w[CHROME_PATH CHROME_BIN GOOGLE_CHROME_BIN].each do |var|
          path = ENV[var]
          return path if path && File.executable?(path)
        end

        %w[google-chrome google-chrome-stable chromium chromium-browser].each do |bin|
          path = find_in_path(bin)
          return path if path
        end

        paths = []

        if macos?
          paths += [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "#{Dir.home}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
          ]
        end

        if linux?
          paths += [
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/snap/bin/chromium"
          ]
        end

        paths.find { |path| File.executable?(path) }
      end

      def find_in_path(bin)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, bin)
          return path if File.executable?(path) && !File.directory?(path)
        end
        nil
      end

      def ensure_chrome_debug_ready
        executable = find_chrome
        return :not_installed unless executable

        pid = Process.spawn([executable, executable], out: File::NULL, err: File::NULL)
        Process.detach(pid)
        open_chrome_remote_debugging_page
        false
      end

      def open_chrome_remote_debugging_page
        if macos?
          system("open", "-a", "Google Chrome", CHROME_DEBUG_PAGE)
        else
          executable = find_chrome
          if executable
            system("sh", "-c", "#{Shellwords.escape(executable)} #{Shellwords.escape(CHROME_DEBUG_PAGE)} > /dev/null 2>&1 &")
          end
        end
      end

      def macos?
        RbConfig::CONFIG["host_os"].include?("darwin")
      end

      def linux?
        RbConfig::CONFIG["host_os"].include?("linux")
      end

      def chrome_setup_instructions
        {
          error: "Cannot connect to Chrome browser",
          message: "Opened #{CHROME_DEBUG_PAGE} in Chrome. Please enable the 'Allow remote debugging for this browser instance' toggle, then tell me when done.",
          instructions: "Follow this two-phase flow with the user: " \
            "Phase 1 — Ask the user to: open #{CHROME_DEBUG_PAGE}, enable the 'Allow remote debugging for this browser instance' toggle, then tell you when done. " \
            "Phase 2 — Once the user confirms the toggle is enabled, warn them BEFORE retrying: 'Chrome will now show an Allow remote debugging confirmation dialog — please click Allow.' Then retry the browser command.",
          note: "Do NOT retry immediately. Wait for the user to confirm the toggle is enabled, warn about the Allow dialog, then retry."
        }
      end
    end
  end
end
