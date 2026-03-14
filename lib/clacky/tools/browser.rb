# frozen_string_literal: true

require "shellwords"
require "socket"
require "tmpdir"
require_relative "base"
require_relative "shell"

module Clacky
  module Tools
    class Browser < Base
      self.tool_name = "browser"
      self.tool_description = <<~DESC
        Browser automation for login-related operations (sign-in, OAuth, form submission requiring session). For simple page fetch or search, prefer web_fetch or web_search instead.

        isolated: true = built-in browser (default, no setup, login persists). false = user's Chrome (keeps cookies/login, needs one-time debug setup; opens URLs in new tab).

        SNAPSHOT — always run before interacting with a page. Refs (@e1, @e2...) expire after page changes, always re-snapshot before acting on a changed page:
        - 'snapshot -i -C' — interactive + cursor-clickable elements (recommended default)
        - 'snapshot -i' — interactive elements only (faster, for simple forms)
        - 'snapshot' — full accessibility tree (when above miss elements)

        ELEMENT SELECTION — prefer in this order:
        1. Refs: 'click @e1', 'fill @e2 "text"'
        2. Semantic find: 'find text "Submit" click', 'find role button "Login" click', 'find label "Email" fill "user@example.com"'
        3. CSS: 'click "#submit-btn"'

        OTHER COMMANDS:
        - 'open <url>', 'back', 'reload', 'press Enter', 'key Control+a'
        - 'scroll down/up', 'scrollintoview @e1', 'wait @e1', 'wait --text "..."', 'wait --load networkidle'
        - 'dialog accept/dismiss', 'tab new <url>', 'tab <n>'

        SCREENSHOT: NEVER call on your own — costs far more tokens than snapshot. Last resort only. Ask user first: "Screenshots cost more tokens. Approve?" When approved: 'screenshot --screenshot-format jpeg --screenshot-quality 50'.
      DESC
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          command: {
            type: "string",
            description: "agent-browser command, e.g. 'open https://...', 'snapshot -i', 'click @e1', 'fill @e2 \"text\"'"
          },
          session: {
            type: "string",
            description: "Named session for parallel browser instances (optional)"
          },
          isolated: {
            type: "boolean",
            description: "true = built-in browser (default, no setup, login persists). false = user's Chrome (keeps login, needs one-time debug setup; opens URLs in new tab). Default true when omitted."
          }
        },
        required: ["command"]
      }

      AGENT_BROWSER_BIN = "agent-browser"
      DEFAULT_SESSION_NAME = "clacky"
      CHROME_DEBUG_PORT = 9222
      BROWSER_COMMAND_TIMEOUT = 30
      CHROME_DEBUG_PAGE = "chrome://inspect/#remote-debugging"
      MIN_AGENT_BROWSER_VERSION = "0.20.0"

      def execute(command:, session: nil, isolated: nil, working_dir: nil)
        # Handle explicit install command
        if command.strip == "install"
          return do_install_agent_browser
        end

        if !agent_browser_installed?
          return {
            error: "agent-browser not installed",
            message: "agent-browser is required for browser automation but is not installed.",
            instructions: "Tell the user: 'agent-browser is not installed. It's required for browser automation. Run `browser(command: \"install\")` to install it — this may take a minute. Would you like me to install it now?' Wait for user confirmation before calling install."
          }
        end

        if agent_browser_outdated?
          current = `agent-browser --version 2>/dev/null`.strip.split.last
          return {
            error: "agent-browser version too old",
            message: "agent-browser #{current} is installed but version >= #{MIN_AGENT_BROWSER_VERSION} is required.",
            instructions: "Tell the user: 'agent-browser needs to be upgraded from #{current} to #{MIN_AGENT_BROWSER_VERSION}+. Run `browser(command: \"install\")` to upgrade — this may take a minute. Would you like me to upgrade it now?' Wait for user confirmation before calling install."
          }
        end

        # Default to built-in browser (isolated=true). Only use user's Chrome when explicitly isolated=false.
        use_auto_connect = isolated == false
        persistent_session_name = use_auto_connect ? nil : DEFAULT_SESSION_NAME

        we_launched_chrome = false
        if use_auto_connect && !chrome_debug_running?
          launch_result = ensure_chrome_debug_ready
          if launch_result == :not_installed
            use_auto_connect = false
            persistent_session_name = DEFAULT_SESSION_NAME
          elsif launch_result
            we_launched_chrome = true
          else
            return chrome_setup_instructions
          end
        end

        build_opts = {
          auto_connect: use_auto_connect,
          session_name: persistent_session_name,
          headed: use_auto_connect ? false : true
        }
        effective_command = command
        if use_auto_connect && (m = command.strip.match(/\A(open|goto|navigate)\s+(.+)\z/i))
          effective_command = "tab new #{m[2].strip}"
        end
        full_command = build_command(effective_command, session, **build_opts)

        result = Shell.new.execute(command: full_command, hard_timeout: BROWSER_COMMAND_TIMEOUT, working_dir: working_dir)

        if !result[:success] && session_closed_error?(result) && persistent_session_name
          full_command = build_command(
            effective_command, session,
            auto_connect: use_auto_connect,
            session_name: nil,
            headed: use_auto_connect ? false : true
          )
          result = Shell.new.execute(command: full_command, hard_timeout: BROWSER_COMMAND_TIMEOUT, working_dir: working_dir)
        end

        if use_auto_connect && !result[:success] && connection_error?(result)
          if we_launched_chrome
            result = Shell.new.execute(command: full_command, hard_timeout: BROWSER_COMMAND_TIMEOUT, working_dir: working_dir)
          end
          if !result[:success] && connection_error?(result)
            open_chrome_remote_debugging_page
            return chrome_setup_instructions
          end
        end

        if use_auto_connect && !result[:success] && timeout?(result)
          return chrome_setup_instructions(timeout: true)
        end

        result[:command] = command
        result
      rescue StandardError => e
        { error: "Failed to run agent-browser: #{e.message}" }
      end

      def format_call(args)
        cmd = args[:command] || args["command"] || ""
        session = args[:session] || args["session"]
        isolated = args[:isolated] || args["isolated"]
        session_label = session ? " [#{session}]" : ""
        isolated_label = (isolated != false) ? " [built-in]" : " [user Chrome]"
        "browser(#{cmd})#{session_label}#{isolated_label}"
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

      MAX_LLM_OUTPUT_CHARS = 6000
      # Snapshot-specific limit: accessibility trees can be huge; compress aggressively
      MAX_SNAPSHOT_CHARS = 4000

      def format_result_for_llm(result)
        return result if result[:error]

        stdout = result[:stdout] || ""
        stderr = result[:stderr] || ""
        command_name = command_name_for_temp(result[:command])

        compact = {
          command: result[:command],
          success: result[:success],
          exit_code: result[:exit_code]
        }

        # Apply snapshot-specific compression before generic truncation
        if snapshot_command?(result[:command])
          stdout = compress_snapshot(stdout)
          max_chars = MAX_SNAPSHOT_CHARS
        else
          max_chars = MAX_LLM_OUTPUT_CHARS
        end

        stdout_info = truncate_and_save(stdout, max_chars, "stdout", command_name)
        compact[:stdout] = stdout_info[:content]
        compact[:stdout_full] = stdout_info[:temp_file] if stdout_info[:temp_file]

        stderr_info = truncate_and_save(stderr, 500, "stderr", command_name)
        compact[:stderr] = stderr_info[:content] unless stderr.empty?
        compact[:stderr_full] = stderr_info[:temp_file] if stderr_info[:temp_file]

        compact
      end

      private

      # Returns true if this browser command is a snapshot (accessibility tree dump)
      def snapshot_command?(command)
        return false unless command.is_a?(String)
        cmd = command.strip.downcase
        cmd == "snapshot" || cmd.start_with?("snapshot ")
      end

      # Strip noise from snapshot output to reduce token usage.
      #
      # What we remove (safe, LLM doesn't need them to interact):
      #   - "- /url: ..." lines  — LLM uses [ref=eN] to click/fill, not URLs
      #   - "- /placeholder: ..." lines — already shown inline in textbox label
      #   - "- img" lines with no alt text — zero information
      #
      # What we keep intact:
      #   - All [ref=eN] anchors (essential for click/fill commands)
      #   - All visible text and headings
      #   - All interactive elements (button, textbox, link, select, etc.)
      #   - img lines that do have alt text
      def compress_snapshot(output)
        return output if output.empty?

        lines = output.lines
        original_size = lines.size

        compressed = lines.reject do |line|
          stripped = line.strip
          stripped.start_with?("- /url:", "/url:") ||
            stripped.start_with?("- /placeholder:", "/placeholder:") ||
            stripped == "- img" ||
            stripped.match?(/\A-\s+img\s*\z/)
        end

        # If we removed a meaningful number of lines, append a note
        removed = original_size - compressed.size
        if removed > 0
          compressed << "\n[snapshot compressed: #{removed} /url, /placeholder, empty-img lines removed]\n"
        end

        compressed.join
      end

      def build_command(command, session, auto_connect: false, session_name: nil, headed: false)
        parts = [AGENT_BROWSER_BIN]
        parts << "--auto-connect" << (auto_connect ? "true" : "false")
        parts << "--headed" << (headed ? "true" : "false")
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

      def connection_error?(result)
        output = "#{result[:stderr]}#{result[:stdout]}"
        output.include?("Could not connect") ||
          output.include?("No running Chrome instance") ||
          output.include?("remote debugging")
      end

      def session_closed_error?(result)
        output = "#{result[:stderr]}#{result[:stdout]}"
        output.include?("has been close") || output.include?("has been closed")
      end

      def timeout?(result)
        result[:state] == "TIMEOUT" ||
          result[:stderr].to_s.include?("timed out")
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

        spawn_chrome_with_debug_port(executable)
        return true
      end

      def spawn_chrome_with_debug_port(executable)
        pid = Process.spawn(
          executable,
          "--remote-debugging-port=#{CHROME_DEBUG_PORT}",
          "--no-first-run",
          "--no-default-browser-check",
          out: File::NULL,
          err: File::NULL
        )
        Process.detach(pid)
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

      def chrome_setup_instructions(timeout: false)
        base = {
          error: "Cannot connect to Chrome browser",
          message: "Opened Chrome with #{CHROME_DEBUG_PAGE}. Please enable the 'Allow remote debugging for this browser instance' toggle, then tell me when done. If the page shows 'Server running at: starting...' and connection fails, fully quit Chrome and reopen it, then retry.",
          instructions: "Follow this flow with the user: " \
            "Phase 1 — Chrome has been opened with the inspect page. If Chrome was closed, it should now be open. Ask the user to enable the 'Allow remote debugging for this browser instance' toggle if not already on, then tell you when done. " \
            "Phase 2 — Once the user confirms, retry the browser command. The Allow dialog appears once per Chrome session (each time the user reopens Chrome) — this is Chrome's security and cannot be skipped. Ask the user to click Allow when it appears. " \
            "Phase 3 — If connection still fails and the page shows 'Server running at: starting...', tell the user to fully quit Chrome and reopen it; the server may be stuck. Once it shows 'Server running at: 127.0.0.1:9222', retry.",
          note: "Do NOT retry immediately. Wait for the user to confirm. The toggle persists — if they enabled it before, reopening Chrome is enough. Allow dialog is once per session."
        }
        if timeout
          base[:error] = "Browser command timed out"
          base[:message] = "Command timed out. This usually means the Allow dialog is showing — please click Allow in the Chrome dialog, then tell me when done."
          base[:instructions] = "Timeout usually means the Allow dialog is waiting. Do NOT retry. Ask the user: 'Please click the Allow button in the Chrome dialog, then tell me when done.' Only retry after the user confirms they clicked Allow."
        end
        base
      end

      def agent_browser_installed?
        !!find_in_path(AGENT_BROWSER_BIN)
      end

      def agent_browser_outdated?
        version = `agent-browser --version 2>/dev/null`.strip.split.last
        return false if version.nil? || version.empty?
        Gem::Version.new(version) < Gem::Version.new(MIN_AGENT_BROWSER_VERSION)
      rescue StandardError
        false
      end

      def do_install_agent_browser
        script = File.expand_path("../../../../scripts/install_agent_browser.sh", __FILE__)
        result = Shell.new.execute(command: "bash #{Shellwords.escape(script)}", hard_timeout: 180)
        if result[:success]
          version = `agent-browser --version 2>/dev/null`.strip.split.last
          { success: true, message: "agent-browser #{version} installed successfully. You can now use browser commands." }
        else
          { error: "Failed to install agent-browser", message: result[:stdout].to_s.strip }
        end
      end

      def command_name_for_temp(command)
        first_word = (command || "").strip.split(/\s+/).first
        File.basename(first_word.to_s, ".*")
      end

      def truncate_and_save(output, max_chars, _label, command_name)
        return { content: "", temp_file: nil } if output.empty?

        return { content: output, temp_file: nil } if output.length <= max_chars

        lines = output.lines
        return { content: output, temp_file: nil } if lines.length <= 2

        safe_name = command_name.gsub(/[^\w\-.]/, "_")[0...50]
        temp_dir = Dir.mktmpdir
        temp_file = File.join(temp_dir, "browser_#{safe_name}_#{Time.now.strftime("%Y%m%d_%H%M%S")}.output")
        File.write(temp_file, output)

        notice_overhead = 200
        available_chars = max_chars - notice_overhead

        first_part = []
        accumulated = 0
        lines.each do |line|
          break if accumulated + line.length > available_chars
          first_part << line
          accumulated += line.length
        end

        notice = "\n\n... [Output truncated: showing #{first_part.size} of #{lines.size} lines, full: #{temp_file} (use grep to search)] ...\n"

        { content: first_part.join + notice, temp_file: temp_file }
      end

    end
  end
end
