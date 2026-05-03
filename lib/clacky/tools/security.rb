# frozen_string_literal: true

require "shellwords"
require "json"
require "fileutils"
require_relative "../utils/trash_directory"
require_relative "../utils/encoding"

module Clacky
  module Tools
    # Pre-execution safety layer for shell-style commands.
    #
    # Design principle: protect against the handful of commands that are
    # irreversibly destructive or can compromise the host. Everything else
    # is the user's (or agent's) business. Over-protection burns tool-call
    # rounds and forces awkward work-arounds (e.g. the infamous "cp ~/.clacky
    # /xxx ./ ... Blocked: outside project directory" dance).
    #
    # Responsibilities (applied to the `command` string BEFORE it is handed
    # to a shell / PTY for execution):
    #
    #   1. Block hard-dangerous commands:       sudo, pkill clacky, eval, exec,
    #                                           `...`, $(...), | sh, | bash,
    #                                           redirect to /etc /usr /bin.
    #   2. Rewrite `curl ... | bash` → save     script to a file for manual
    #                                           review instead of exec.
    #   3. Protect credential/secret files:     .env, .ssh/, .aws/ — block
    #                                           writes to these only. Other
    #                                           "project" files (Gemfile,
    #                                           README.md, package.json, …)
    #                                           are NOT protected — editing
    #                                           them is a normal dev task.
    #
    # Note on `rm`:
    #   `rm` is NOT rewritten here — it's intercepted at runtime by a shell
    #   function installed in each PTY session (see Terminal::SAFE_RM_BASH
    #   and Terminal#install_marker). This lets the shell's own parser
    #   handle heredocs / multi-line / globs / variables correctly. A
    #   static Ruby-side rewrite cannot — it would mis-parse heredoc
    #   bodies and destroy legitimate commands.
    #
    # Notes:
    #   - `cp`, `mv`, `mkdir`, `touch`, `echo` are allowed to touch ANY path
    #     (including outside the project root). The source of a `cp` is
    #     read-only to the FS, and writing to arbitrary dirs is a legitimate
    #     need (copying from ~/.clacky/skills/..., writing to /tmp, etc.).
    #
    # Raises SecurityError on block. Returns a (possibly rewritten) command
    # string on success.
    #
    # This module was extracted from the former `SafeShell` tool. It is now
    # shared by any tool that executes shell-style commands (currently:
    # `terminal`).
    module Security
      # Raised when a command cannot be made safe.
      class Blocked < StandardError; end

      # Read-only commands that are considered safe for auto-execution
      # (permission mode :confirm_safes).
      SAFE_READONLY_COMMANDS = %w[
        ls pwd cat less more head tail
        grep find which whereis whoami
        ps top htop df du
        git echo printf wc
        date file stat
        env printenv
        curl wget
      ].freeze

      class << self
        # Process `command` and return a (possibly rewritten) safe version.
        # Raises SecurityError when the command cannot be made safe.
        #
        # @param command [String] command to check
        # @param project_root [String] path treated as the allowed root for writes
        # @return [String] safe command to execute
        def make_safe(command, project_root: Dir.pwd)
          Replacer.new(project_root).make_command_safe(command)
        end

        # True iff the command is safe to auto-execute in :confirm_safes mode.
        # (Either a known read-only command, or one that Security.make_safe
        # returns unchanged.)
        def command_safe_for_auto_execution?(command)
          return false unless command

          cmd_name = command.strip.split.first
          return true if SAFE_READONLY_COMMANDS.include?(cmd_name)

          begin
            safe = make_safe(command, project_root: Dir.pwd)
            command.strip == safe.strip
          rescue SecurityError
            false
          end
        end
      end

      # Internal class that owns per-project state (trash dir, log dir, ...).
      # Extracted almost verbatim from the old SafeShell::CommandSafetyReplacer.
      class Replacer
        def initialize(project_root)
          @project_root = File.expand_path(project_root)

          trash_directory = Clacky::TrashDirectory.new(@project_root)
          @backup_dir = trash_directory.backup_dir

          @project_hash = trash_directory.generate_project_hash(@project_root)
          @safety_log_dir = File.join(Dir.home, ".clacky", "safety_logs", @project_hash)
          FileUtils.mkdir_p(@safety_log_dir) unless Dir.exist?(@safety_log_dir)
          @safety_log_file = File.join(@safety_log_dir, "safety.log")
        end

        def make_command_safe(command)
          command = command.strip

          # Use a UTF-8-scrubbed copy ONLY for regex checks.  The original
          # bytes are returned unchanged so the shell receives exact paths
          # (e.g. GBK-encoded Chinese filenames in zip archives).
          @safe_check_command = Clacky::Utils::Encoding.safe_check(command)

          case @safe_check_command
          # Block attempts to terminate the clacky server process.
          # IMPORTANT: each verb is anchored with \b so substrings like
          # "Skill" (contains "kill") or "Bill Killalina" don't trigger
          # false positives. We also require `clacky` to appear as a whole
          # word AND within a reasonable distance (same logical command,
          # not hundreds of chars later in an unrelated echo string).
          when /\bpkill\b[^\n;|&]{0,80}\bclacky\b|\bkillall\b[^\n;|&]{0,80}\bclacky\b|\bkill\s+(?:-\S+\s+)*[^\n;|&]{0,40}\bclacky\b/i
            raise SecurityError, "Killing the clacky server process is not allowed. To restart, use: #{restart_hint}"
          when /\bclacky\s+server\b/
            raise SecurityError, "Managing the clacky server from within a session is not allowed. To restart, use: #{restart_hint}"
          when /^chmod\s+x/
            replace_chmod_command(command)
          when /^curl.*\|\s*(sh|bash)/
            replace_curl_pipe_command(command)
          when /^sudo\s+/
            block_sudo_command(command)
          when />\s*\/dev\/null\s*$/
            allow_dev_null_redirect(command)
          when /^(mv|cp|mkdir|touch|echo)\s+/
            validate_and_allow(command)
          else
            validate_general_command(@safe_check_command)
            command
          end
        end

        def replace_chmod_command(command)
          begin
            parts = Shellwords.split(command)
          rescue ArgumentError
            parts = command.split(/\s+/)
          end

          files = parts[2..-1] || []
          files.each { |file| validate_file_path(file) unless file.start_with?('-') }

          log_replacement("chmod", command, "chmod +x is allowed - file permissions will be modified")
          command
        end

        def replace_curl_pipe_command(command)
          if command.match(/curl\s+(.*?)\s*\|\s*(sh|bash)/)
            url = $1
            shell_type = $2
            timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
            safe_file = File.join(@backup_dir, "downloaded_script_#{timestamp}.sh")

            result = "curl #{url} -o #{Shellwords.escape(safe_file)} && echo '🔒 Script downloaded to #{safe_file} for manual review. Run: cat #{safe_file}'"
            log_replacement("curl | #{shell_type}", result, "Script saved for manual review instead of automatic execution")
            result
          else
            command
          end
        end

        def block_sudo_command(_command)
          raise SecurityError, "sudo commands are not allowed for security reasons"
        end

        def allow_dev_null_redirect(command)
          command
        end

        # Build a copy-pasteable "how to restart clacky server" hint.
        # When running inside a clacky server worker, `CLACKY_MASTER_PID` is
        # injected by ServerMaster (see server_master.rb). We keep the
        # variable name in the hint (so the AI / user learns the standard
        # convention) AND append the resolved PID in parentheses so it's
        # immediately actionable. When the variable isn't set (e.g. one-shot
        # CLI invocation), we just show the variable name.
        def restart_hint
          pid = ENV["CLACKY_MASTER_PID"].to_s
          if pid =~ /\A\d+\z/
            "kill -USR1 $CLACKY_MASTER_PID  (current master PID: #{pid})"
          else
            "kill -USR1 $CLACKY_MASTER_PID"
          end
        end

        # Relaxed validator for mv / cp / mkdir / touch / echo.
        #
        # Historical behavior was to forbid any path outside @project_root,
        # which broke legitimate workflows like copying skill templates from
        # ~/.clacky/skills/... into the project. We now only block writes to
        # true credential directories (.ssh, .aws) and .env files. Everything
        # else is allowed.
        def validate_and_allow(command)
          begin
            parts = Shellwords.split(command)
          rescue ArgumentError
            parts = command.split(/\s+/)
          end

          cmd  = parts.first
          args = parts[1..-1] || []

          case cmd
          when 'mv', 'cp'
            # For mv/cp only the DESTINATION (last non-flag arg) is a write
            # target; earlier args are sources and are read-only to the FS.
            write_targets = args.reject { |a| a.start_with?('-') }
            dest = write_targets.last
            validate_secret_write(dest) if dest
          when 'mkdir', 'touch'
            args.each { |path| validate_secret_write(path) unless path.start_with?('-') }
          when 'echo'
            # `echo foo > path` — best-effort: block only if redirecting to a
            # secret path. The redirect target will also be caught by
            # validate_general_command for /etc /usr /bin; here we add .env,
            # .ssh/, .aws/.
            if command =~ />\s*([^\s|&;]+)/
              validate_secret_write(Regexp.last_match(1))
            end
          end

          command
        end

        def validate_general_command(command)
          cmd_without_quotes = command.gsub(/'[^']*'|"[^"]*"/, '')

          dangerous_patterns = [
            /eval\s*\(/,
            /exec\s*\(/,
            /system\s*\(/,
            /`[^`]+`/,
            /\$\([^)]+\)/,
            /\|\s*sh\s*$/,
            /\|\s*bash\s*$/,
            />\s*\/etc\//,
            />\s*\/usr\//,
            />\s*\/bin\//
          ]

          dangerous_patterns.each do |pattern|
            if cmd_without_quotes.match?(pattern)
              raise SecurityError, "Dangerous command pattern detected: #{pattern.source}"
            end
          end

          command
        end

        # Block writes that would clobber credentials / secrets.
        # These are the only paths truly dangerous to write to by accident:
        #   - ~/.ssh/*          (SSH private keys)
        #   - ~/.aws/*          (AWS credentials)
        #   - any *.env file    (API keys, DB URLs, etc.)
        #
        # Paths in / outside the project root, Gemfile, README, package.json,
        # etc. are all allowed — the agent is expected to edit them normally.
        SECRET_WRITE_PATTERNS = [
          %r{(?:\A|/)\.ssh/},
          %r{(?:\A|/)\.aws/},
          /(?:\A|\/)\.env(?:\.|\z)/,
          /\.env\z/
        ].freeze

        def validate_secret_write(path)
          return if path.nil? || path.empty? || path.start_with?('-')

          expanded_path = File.expand_path(path)

          SECRET_WRITE_PATTERNS.each do |pattern|
            if expanded_path.match?(pattern)
              raise SecurityError,
                    "Write to credential/secret path blocked: #{path} " \
                    "(matched protected pattern). If intentional, edit the " \
                    "file manually outside the agent."
            end
          end
        end

        # Alias retained for readability — chmod handler validates that
        # the target is not a credential/secret file.
        def validate_file_path(path)
          validate_secret_write(path)
        end

        def log_replacement(original, replacement, reason)
          write_log(
            action: 'command_replacement',
            original_command: original,
            safe_replacement: replacement,
            reason: reason
          )
        end

        def log_warning(message)
          write_log(action: 'warning', message: message)
        end

        def write_log(**fields)
          log_entry = { timestamp: Time.now.iso8601 }.merge(fields)
          File.open(@safety_log_file, 'a') { |f| f.puts JSON.generate(log_entry) }
        rescue StandardError
          # Logging must never break main functionality.
        end

        private :replace_chmod_command,
                :replace_curl_pipe_command, :block_sudo_command,
                :allow_dev_null_redirect, :validate_and_allow,
                :validate_general_command,
                :validate_file_path, :validate_secret_write,
                :restart_hint,
                :log_replacement,
                :log_warning, :write_log
      end
    end
  end
end
