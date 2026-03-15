# frozen_string_literal: true

require "shellwords"
require "yaml"
require "tmpdir"
require_relative "base"
require_relative "shell"

module Clacky
  module Tools
    class Browser < Base
      self.tool_name = "browser"
      self.tool_description = <<~DESC
        Browser automation for login-related operations (sign-in, OAuth, form submission requiring session). For simple page fetch or search, prefer web_fetch or web_search instead.

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
          }
        },
        required: ["command"]
      }

      AGENT_BROWSER_BIN = "agent-browser"
      BROWSER_COMMAND_TIMEOUT = 30
      MIN_AGENT_BROWSER_VERSION = "0.20.0"

      # Inline config — reads ~/.clacky/browser.yml, falls back to built-in defaults.
      #
      # Example ~/.clacky/browser.yml:
      #   headed: true          # show browser window (default: true)
      #   session_name: clacky  # persistent session name (default: clacky)
      #   auto_connect: false   # false = built-in browser (default), true = user's Chrome
      class BrowserConfig
        USER_CONFIG_FILE = File.join(Dir.home, ".clacky", "browser.yml")

        DEFAULTS = {
          "headed"       => true,
          "session_name" => "clacky",
          "auto_connect" => false
        }.freeze

        attr_reader :headed, :session_name, :auto_connect

        def initialize(attrs = {})
          merged = DEFAULTS.merge(attrs)
          @headed       = merged["headed"]
          @session_name = merged["session_name"]
          @auto_connect = merged["auto_connect"]
        end

        def self.load
          data = File.exist?(USER_CONFIG_FILE) ? YAML.safe_load(File.read(USER_CONFIG_FILE)) || {} : {}
          new(data)
        rescue StandardError
          new
        end
      end

      def execute(command:, working_dir: nil)
        unless agent_browser_ready?
          return not_ready_response
        end

        cfg = BrowserConfig.load

        # In auto_connect mode, open commands become new tabs in user's Chrome
        effective_command = command
        if cfg.auto_connect && (m = command.strip.match(/\A(open|goto|navigate)\s+(.+)\z/i))
          effective_command = "tab new #{m[2].strip}"
        end

        full_command = build_command(effective_command,
                                     auto_connect: cfg.auto_connect,
                                     session_name: cfg.auto_connect ? nil : cfg.session_name,
                                     headed: cfg.headed)

        result = Shell.new.execute(command: full_command,
                                   hard_timeout: BROWSER_COMMAND_TIMEOUT,
                                   working_dir: working_dir)

        # Session may have been closed — retry without session name
        if !result[:success] && session_closed_error?(result) && cfg.session_name
          full_command = build_command(effective_command,
                                       auto_connect: cfg.auto_connect,
                                       session_name: nil,
                                       headed: cfg.headed)
          result = Shell.new.execute(command: full_command,
                                     hard_timeout: BROWSER_COMMAND_TIMEOUT,
                                     working_dir: working_dir)
        end

        result[:command] = command
        result
      rescue StandardError => e
        { error: "Failed to run agent-browser: #{e.message}" }
      end

      def format_call(args)
        cmd = args[:command] || args["command"] || ""
        "browser(#{cmd})"
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error][0..80]}"
        elsif result[:success]
          stdout = result[:stdout] || ""
          lines  = stdout.lines.size
          "[OK] #{lines > 0 ? "#{lines} lines" : "Done"}"
        else
          stderr = result[:stderr] || "Failed"
          "[Failed] #{stderr[0..80]}"
        end
      end

      MAX_LLM_OUTPUT_CHARS = 6000
      MAX_SNAPSHOT_CHARS   = 4000

      def format_result_for_llm(result)
        return result if result[:error]

        stdout       = result[:stdout] || ""
        stderr       = result[:stderr] || ""
        command_name = command_name_for_temp(result[:command])

        compact = {
          command:   result[:command],
          success:   result[:success],
          exit_code: result[:exit_code]
        }

        if snapshot_command?(result[:command])
          stdout    = compress_snapshot(stdout)
          max_chars = MAX_SNAPSHOT_CHARS
        else
          max_chars = MAX_LLM_OUTPUT_CHARS
        end

        stdout_info = truncate_and_save(stdout, max_chars, "stdout", command_name)
        compact[:stdout]      = stdout_info[:content]
        compact[:stdout_full] = stdout_info[:temp_file] if stdout_info[:temp_file]

        stderr_info = truncate_and_save(stderr, 500, "stderr", command_name)
        compact[:stderr]      = stderr_info[:content] unless stderr.empty?
        compact[:stderr_full] = stderr_info[:temp_file] if stderr_info[:temp_file]

        compact
      end

      private

      def agent_browser_ready?
        agent_browser_installed? && !agent_browser_outdated?
      end

      def not_ready_response
        {
          error: "agent-browser not ready",
          instructions: "Tell the user that browser automation is not set up yet, and ask them to run `/onboard browser` to complete the setup."
        }
      end

      def agent_browser_installed?
        result = Shell.new.execute(command: "which #{AGENT_BROWSER_BIN}")
        result[:success] && !result[:stdout].to_s.strip.empty?
      end

      def agent_browser_outdated?
        result  = Shell.new.execute(command: "#{AGENT_BROWSER_BIN} --version")
        version = result[:stdout].to_s.strip.split.last
        return false if version.nil? || version.empty?
        Gem::Version.new(version) < Gem::Version.new(MIN_AGENT_BROWSER_VERSION)
      rescue StandardError
        false
      end

      def build_command(command, auto_connect: false, session_name: nil, headed: true)
        parts = [AGENT_BROWSER_BIN]
        parts << "--auto-connect" if auto_connect
        parts << "--headed"       if headed
        parts += ["--session-name", Shellwords.escape(session_name)] if session_name
        parts << command
        parts.join(" ")
      end

      def session_closed_error?(result)
        output = "#{result[:stderr]}#{result[:stdout]}"
        output.include?("has been close") || output.include?("has been closed")
      end

      def snapshot_command?(command)
        return false unless command.is_a?(String)
        cmd = command.strip.downcase
        cmd == "snapshot" || cmd.start_with?("snapshot ")
      end

      # Strip noise from snapshot output to reduce token usage.
      #
      # Removes:
      #   - "- /url: ..." lines         — LLM uses [ref=eN], not URLs
      #   - "- /placeholder: ..." lines  — already shown inline in textbox label
      #   - bare "- img" lines with no alt text — zero information
      def compress_snapshot(output)
        return output if output.empty?

        lines    = output.lines
        orig     = lines.size
        filtered = lines.reject do |line|
          s = line.strip
          s.start_with?("- /url:", "/url:", "- /placeholder:", "/placeholder:") ||
            s == "- img" || s.match?(/\A-\s+img\s*\z/)
        end

        removed = orig - filtered.size
        filtered << "\n[snapshot compressed: #{removed} /url, /placeholder, empty-img lines removed]\n" if removed > 0
        filtered.join
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
        temp_dir  = Dir.mktmpdir
        temp_file = File.join(temp_dir, "browser_#{safe_name}_#{Time.now.strftime("%Y%m%d_%H%M%S")}.output")
        File.write(temp_file, output)

        available  = max_chars - 200
        first_part = []
        accumulated = 0
        lines.each do |line|
          break if accumulated + line.length > available
          first_part << line
          accumulated += line.length
        end

        notice = "\n\n... [Output truncated: showing #{first_part.size} of #{lines.size} lines, full: #{temp_file} (use grep to search)] ...\n"
        { content: first_part.join + notice, temp_file: temp_file }
      end
    end
  end
end
