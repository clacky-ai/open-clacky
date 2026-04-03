# frozen_string_literal: true

require "tmpdir"
require_relative "base"
require_relative "../utils/encoding"

module Clacky
  module Tools
    # A StringIO wrapper that scrubs invalid/undefined bytes to UTF-8 on every
    # write.  Shell commands (via popen3) can emit bytes in any encoding
    # (GBK, Latin-1, binary, …).  By sanitizing at the earliest possible point
    # we guarantee that every downstream operation — regex matching, line
    # splitting, JSON serialization — never sees invalid byte sequences.
    class EncodingSafeBuffer
      def initialize
        @io = StringIO.new("".b)
      end

      def write(data)
        return unless data && !data.empty?

        # Shell output arrives as binary (ASCII-8BIT) bytes.  Use the shared
        # helper which re-labels encoding as UTF-8 and scrubs only genuinely
        # invalid sequences, preserving multibyte characters (e.g. CJK).
        @io.write(Clacky::Utils::Encoding.to_utf8(data))
      end

      def string
        @io.string
      end
    end

    class Shell < Base
      self.tool_name = "shell"
      self.tool_description = "Execute shell commands in the terminal"
      self.tool_category = "system"
      self.tool_parameters = {
        type: "object",
        properties: {
          command: {
            type: "string",
            description: "Shell command to execute"
          },
          soft_timeout: {
            type: "integer",
            description: "Soft timeout in seconds (for interaction detection)"
          },
          hard_timeout: {
            type: "integer",
            description: "Hard timeout in seconds (force kill)"
          },
          max_output_lines: {
            type: "integer",
            description: "Maximum number of output lines to return (default: 1000)",
            default: 1000
          }
        },
        required: ["command"]
      }

      INTERACTION_PATTERNS = [
        [/\[Y\/n\]|\[y\/N\]|\(yes\/no\)|\(Y\/n\)|\(y\/N\)/i, 'confirmation'],
        [/[Pp]assword\s*:\s*$|Enter password|enter password/, 'password'],
        [/^\s*>>>\s*$|^\s*>>?\s*$|^irb\(.*\):\d+:\d+[>*]\s*$|^\>\s*$/, 'repl'],
        [/^\s*:\s*$|\(END\)|--More--|Press .* to continue|lines \d+-\d+/, 'pager'],
        [/Are you sure|Continue\?|Proceed\?|Confirm|Overwrite/i, 'question'],
        [/Enter\s+\w+:|Input\s+\w+:|Please enter|please provide/i, 'input'],
        [/Select an option|Choose|Which one|select one/i, 'selection']
      ].freeze

      SLOW_COMMANDS = [
        'bundle install',
        'npm install',
        'yarn install',
        'pnpm install',
        'rspec',
        'rake test',
        'npm run build',
        'npm run test',
        'yarn build',
        'cargo build',
        'go build'
      ].freeze

      def execute(command:, soft_timeout: nil, hard_timeout: nil, max_output_lines: 1000, output_buffer: nil, working_dir: nil)
        require "open3"
        require "stringio"

        soft_timeout, hard_timeout = determine_timeouts(command, soft_timeout, hard_timeout)

        stdout_buffer = EncodingSafeBuffer.new
        stderr_buffer = EncodingSafeBuffer.new
        soft_timeout_triggered = false

        # Store output buffer reference for real-time access (use LimitStack for memory efficiency)
        @output_buffer = output_buffer
        if @output_buffer
          @output_buffer[:stdout_lines] = Utils::LimitStack.new(max_size: 1000)
          @output_buffer[:stderr_lines] = Utils::LimitStack.new(max_size: 200)
        end
        @stdout_buffer = stdout_buffer
        @stderr_buffer = stderr_buffer

        # pgroup: 0 puts the child in its own process group so that Ctrl-C
        # (SIGINT sent to the terminal's foreground group) does NOT propagate
        # into the child.  The parent catches SIGINT via its own trap and
        # explicitly kills the child process group.
        # We do NOT use -i (interactive) here — that flag causes zsh to try
        # acquiring /dev/tty as a controlling terminal, which triggers SIGTTIN
        # when the process is not in the terminal's foreground group.
        # Instead, wrap_with_shell sources the user's rc file explicitly.
        popen3_opts = { pgroup: 0 }
        popen3_opts[:chdir] = working_dir if working_dir && Dir.exist?(working_dir)

        begin
          Open3.popen3(wrap_with_shell(command), **popen3_opts) do |stdin, stdout, stderr, wait_thr|
            start_time = Time.now

            stdout.sync = true
            stderr.sync = true

            begin
              loop do
                elapsed = Time.now - start_time

                # --- Hard timeout: kill process group and return ---
                if elapsed > hard_timeout
                  Process.kill('TERM', -wait_thr.pid) rescue nil
                  sleep 0.05
                  Process.kill('KILL', -wait_thr.pid) rescue nil
                  stdout.close rescue nil
                  stderr.close rescue nil

                  return format_timeout_result(
                    command,
                    stdout_buffer.string,
                    stderr_buffer.string,
                    elapsed,
                    :hard_timeout,
                    hard_timeout,
                    max_output_lines
                  )
                end

                # --- Soft timeout: check for interactive prompts ---
                if elapsed > soft_timeout && !soft_timeout_triggered
                  soft_timeout_triggered = true

                  interaction = detect_interaction(stdout_buffer.string) ||
                                detect_interaction(stderr_buffer.string) ||
                                detect_sudo_waiting(command, wait_thr)
                  if interaction
                    Process.kill('TERM', -wait_thr.pid) rescue nil
                    stdout.close rescue nil
                    stderr.close rescue nil
                    return format_waiting_input_result(
                      command,
                      stdout_buffer.string,
                      stderr_buffer.string,
                      interaction,
                      max_output_lines
                    )
                  end
                end

                break unless wait_thr.alive?

                begin
                  ready = IO.select([stdout, stderr], nil, nil, 0.1)
                  if ready
                    ready[0].each do |io|
                      begin
                        data = io.read_nonblock(4096)
                        if io == stdout
                          stdout_buffer.write(data)
                        else
                          stderr_buffer.write(data)
                        end
                        update_output_buffer
                      rescue IO::WaitReadable, EOFError
                      end
                    end
                  end
                rescue StandardError
                end

                sleep 0.1
              end

              # Drain any remaining output from pipes non-blockingly.
              # We must NOT use a plain blocking read here because background
              # processes launched with & inherit the pipe's write-end fd and
              # keep it open, causing read to block forever after the shell exits.
              # Select both stdout+stderr together so we wait at most drain_deadline
              # total (not per-IO), and break as soon as both pipes signal EOF.
              drain_deadline = Time.now + 2
              open_ios = [stdout, stderr].reject { |io| io.closed? }
              begin
                loop do
                  remaining = drain_deadline - Time.now
                  break if remaining <= 0 || open_ios.empty?
                  ready = IO.select(open_ios, nil, nil, [remaining, 0.1].min)
                  next unless ready
                  ready[0].each do |io|
                    buf = io == stdout ? stdout_buffer : stderr_buffer
                    begin
                      buf.write(io.read_nonblock(4096))
                    rescue IO::WaitReadable
                      # not ready yet, keep waiting
                    rescue EOFError
                      open_ios.delete(io)
                    end
                  end
                end
              rescue StandardError
              end

              stdout_output = stdout_buffer.string
              stderr_output = stderr_buffer.string

              {
                command: command,
                stdout: truncate_output(stdout_output, max_output_lines),
                stderr: truncate_output(stderr_output, max_output_lines),
                exit_code: wait_thr.value.exitstatus,
                success: wait_thr.value.success?,
                elapsed: Time.now - start_time,
                output_truncated: output_truncated?(stdout_output, stderr_output, max_output_lines)
              }
            ensure
              # Ensure child process group is killed when block exits
              if wait_thr&.alive?
                Process.kill('TERM', -wait_thr.pid) rescue nil
                sleep 0.1
                Process.kill('KILL', -wait_thr.pid) rescue nil
              end
            end
          end
        rescue StandardError => e
          stdout_output = stdout_buffer.string
          stderr_output = "Error executing command: #{e.message}\n#{e.backtrace.first(3).join("\n")}"

          {
            command: command,
            stdout: truncate_output(stdout_output, max_output_lines),
            stderr: truncate_output(stderr_output, max_output_lines),
            exit_code: -1,
            success: false,
            output_truncated: output_truncated?(stdout_output, stderr_output, max_output_lines)
          }
        end
      end

      # Wrap command in a login shell and explicitly source the user's interactive
      # rc file so that PATH customisations from nvm, rbenv, brew, etc. are available.
      #
      # We use -l (login) instead of -i (interactive) to avoid SIGTTIN: when the
      # process runs in a new process group (pgroup: 0) it is not the terminal's
      # foreground group, so an interactive shell trying to acquire /dev/tty gets
      # stopped by the kernel immediately.
      #
      # -l loads ~/.zprofile / ~/.bash_profile which is enough for most PATH setup.
      # We additionally source the interactive rc file (~/.zshrc or ~/.bashrc) so
      # aliases, functions, and tool shims (rbenv init, nvm, etc.) are also present.
      def wrap_with_shell(command)
        # shell = ENV['SHELL'].to_s
        # shell = '/bin/bash' if shell.empty?

        # rc_source = rc_source_snippet(shell)
        # full_command = rc_source ? "#{rc_source} #{command}" : command

        # "#{shell} -l -c #{Shellwords.escape(full_command)}"
        return command
      end

      # Returns a shell snippet that sources the user's interactive rc file,
      # suppressing all errors so missing files never break command execution.
      private def rc_source_snippet(shell)
        shell_name = File.basename(shell)
        home = ENV['HOME'].to_s

        rc_file = case shell_name
        when 'zsh'  then File.join(home, '.zshrc')
        when 'bash' then File.join(home, '.bashrc')
        when 'fish' then File.join(home, '.config', 'fish', 'config.fish')
        end

        return nil unless rc_file

        # Source silently: suppress stderr and ignore exit code so that
        # errors in the user's rc file don't prevent the command from running.
        "source #{Shellwords.escape(rc_file)} 2>/dev/null;"
      end

      def determine_timeouts(command, soft_timeout, hard_timeout)
        is_slow = SLOW_COMMANDS.any? { |slow_cmd| command.include?(slow_cmd) }

        if is_slow
          soft_timeout ||= 30
          hard_timeout ||= 180
        else
          soft_timeout ||= 7
          hard_timeout ||= 60
        end

        [soft_timeout, hard_timeout]
      end

      # Rule-based interaction detection: scan the last few lines of output
      # for patterns that indicate the command is waiting for user input.
      def detect_interaction(output)
        return nil if output.empty?

        lines = output.split("\n").last(10)

        lines.reverse.each do |line|
          line_stripped = line.strip
          next if line_stripped.empty?

          INTERACTION_PATTERNS.each do |pattern, type|
            # Force encoding to UTF-8 to avoid ASCII-8BIT / UTF-8 incompatibility
            # when the line comes from raw terminal byte streams.
            safe_line = line_stripped.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
            return { type: type, line: safe_line } if line.match?(pattern)
          end
        end

        nil
      end

      # Heuristic: sudo writes its password prompt to /dev/tty, bypassing
      # stdout/stderr pipes.  If the command contains sudo and the process is
      # still alive after soft_timeout, it is almost certainly waiting for a
      # password.
      def detect_sudo_waiting(command, wait_thr)
        return nil unless wait_thr.alive?
        return nil unless command.match?(/\bsudo\b/)

        { type: "password", line: "[sudo] password:" }
      end

      def format_waiting_input_result(command, stdout, stderr, interaction, max_output_lines)
        {
          command: command,
          stdout: truncate_output(stdout, max_output_lines),
          stderr: truncate_output(stderr, max_output_lines),
          exit_code: -2,
          success: false,
          state: 'WAITING_INPUT',
          interaction_type: interaction[:type],
          message: format_waiting_message(truncate_output(stdout, max_output_lines), interaction),
          output_truncated: output_truncated?(stdout, stderr, max_output_lines)
        }
      end

      def format_waiting_message(output, interaction)
        # Ensure strings from raw byte streams are valid UTF-8 before interpolation
        output = output.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")

        password_hint = if interaction[:type] == "password"
          <<~HINT

            Password prompt detected.
            sudo reads the password from /dev/tty, not stdin, so it cannot be piped in directly.
            Action required:
            1. Ask the user: "Please enter your sudo password:"
            2. Once provided, retry the command using: echo 'PASSWORD' | sudo -S original_command
               (replace PASSWORD with what the user provides)
          HINT
        end

        <<~MSG
          #{output}

          #{'=' * 60}
          [Terminal State: WAITING_INPUT]
          #{'=' * 60}

          The terminal is waiting for your input.

          Detected pattern: #{interaction[:type]}
          Last line: #{interaction[:line]}
          #{password_hint}
          Suggested actions:
          • Provide answer: run shell with your response
          • Cancel: send Ctrl+C (\x03)
        MSG
      end

      def format_timeout_result(command, stdout, stderr, elapsed, type, timeout, max_output_lines)
        {
          command: command,
          stdout: truncate_output(stdout, max_output_lines),
          stderr: truncate_output(
            stderr.empty? ? "Command timed out after #{elapsed.round(1)} seconds (#{type}=#{timeout}s)" : stderr,
            max_output_lines
          ),
          exit_code: -1,
          success: false,
          state: 'TIMEOUT',
          timeout_type: type,
          output_truncated: output_truncated?(stdout, stderr, max_output_lines)
        }
      end

      # Truncate output to max_lines and max line length, adding a truncation notice if needed
      def truncate_output(output, max_lines)
        return output if output.nil? || output.empty?

        output = truncate_long_lines(output, MAX_LINE_CHARS)
        lines = output.lines
        return output if lines.length <= max_lines

        truncated_lines = lines.first(max_lines)
        truncation_notice = "\n\n... [Output truncated: showing #{max_lines} of #{lines.length} lines] ...\n"
        truncated_lines.join + truncation_notice
      end

      # Check if output was truncated
      def output_truncated?(stdout, stderr, max_lines)
        stdout_lines = stdout&.lines&.length || 0
        stderr_lines = stderr&.lines&.length || 0
        stdout_lines > max_lines || stderr_lines > max_lines
      end

      def format_call(args)
        cmd = args[:command] || args['command'] || ''
        cmd_parts = cmd.split
        cmd_short = cmd_parts.first(3).join(' ')
        cmd_short += '...' if cmd_parts.size > 3
        "Shell(#{cmd_short})"
      end

      def format_result(result)
        exit_code = result[:exit_code] || result['exit_code'] || 0
        stdout = result[:stdout] || result['stdout'] || ""
        stderr = result[:stderr] || result['stderr'] || ""

        if exit_code == 0
          lines = stdout.lines.size
          "[OK] Completed#{lines > 0 ? " (#{lines} lines)" : ''}"
        else
          error_msg = stderr.lines.first&.strip || "Failed"
          "[Exit #{exit_code}] #{error_msg[0..50]}"
        end
      end

      # Format result for LLM consumption - limit output size to save tokens
      # Maximum characters to include in LLM output
      MAX_LLM_OUTPUT_CHARS = 4000
      # Maximum characters per line before truncating (handles minified CSS/JS files)
      MAX_LINE_CHARS = 500

      def format_result_for_llm(result)
        return result if result[:error] || result[:state] == 'TIMEOUT' || result[:state] == 'WAITING_INPUT'

        enc = Clacky::Utils::Encoding
        stdout = enc.to_utf8(result[:stdout] || "")
        stderr = enc.to_utf8(result[:stderr] || "")
        exit_code = result[:exit_code] || 0

        compact = {
          command: enc.to_utf8(result[:command].to_s),
          exit_code: exit_code,
          success: result[:success]
        }

        compact[:elapsed] = result[:elapsed] if result[:elapsed]

        command_name = extract_command_name(compact[:command])

        stdout_info = truncate_and_save(stdout, MAX_LLM_OUTPUT_CHARS, "stdout", command_name)
        compact[:stdout] = stdout_info[:content]
        compact[:stdout_full] = stdout_info[:temp_file] if stdout_info[:temp_file]

        stderr_info = truncate_and_save(stderr, MAX_LLM_OUTPUT_CHARS, "stderr", command_name)
        compact[:stderr] = stderr_info[:content]
        compact[:stderr_full] = stderr_info[:temp_file] if stderr_info[:temp_file]

        compact[:output_truncated] = true if result[:output_truncated]

        compact
      end

      # Extract command name from full command for temp file naming
      def extract_command_name(command)
        first_word = command.strip.split(/\s+/).first
        File.basename(first_word, ".*")
      end

      # Truncate output for LLM and optionally save full content to temp file
      def truncate_and_save(output, max_chars, label, command_name)
        return { content: "", temp_file: nil } if output.empty?

        output = truncate_long_lines(output, MAX_LINE_CHARS)
        return { content: output, temp_file: nil } if output.length <= max_chars

        safe_name = command_name.gsub(/[^\w\-.]/, "_")[0...50]
        temp_dir = Dir.mktmpdir
        temp_file = File.join(temp_dir, "#{safe_name}_#{Time.now.strftime("%Y%m%d_%H%M%S")}.output")
        File.write(temp_file, output)

        lines = output.lines
        return { content: output, temp_file: nil } if lines.length <= 2

        notice_overhead = 200
        available_chars = max_chars - notice_overhead

        first_part = []
        accumulated = 0
        lines.each do |line|
          break if accumulated + line.length > available_chars
          first_part << line
          accumulated += line.length
        end

        total_lines = lines.length
        shown_lines = first_part.length

        notice = if label == "stderr"
          "\n... [Error output truncated for LLM: showing #{shown_lines} of #{total_lines} lines, full content: #{temp_file} (use grep to search)] ...\n"
        else
          "\n... [Output truncated for LLM: showing #{shown_lines} of #{total_lines} lines, full content: #{temp_file} (use grep to search)] ...\n"
        end

        { content: first_part.join + notice, temp_file: temp_file }
      end

      # Truncate individual lines that exceed max_line_chars
      # Useful for minified CSS/JS files where a single line can be megabytes
      def truncate_long_lines(output, max_line_chars)
        lines = output.lines
        return output if lines.none? { |l| l.chomp.length > max_line_chars }

        lines.map do |line|
          chopped = line.chomp
          if chopped.length > max_line_chars
            "#{chopped[0...max_line_chars]}... [line truncated: #{chopped.length} chars total]\n"
          else
            line
          end
        end.join
      end

      # Update shared output buffer for real-time access
      # Uses LimitStack to automatically manage memory and keep only recent output
      private def update_output_buffer
        return unless @output_buffer

        stdout_lines = @stdout_buffer.string.lines
        stderr_lines = @stderr_buffer.string.lines

        @output_buffer[:stdout_lines].clear
        @output_buffer[:stdout_lines].push_lines(stdout_lines)

        @output_buffer[:stderr_lines].clear
        @output_buffer[:stderr_lines].push_lines(stderr_lines)

        @output_buffer[:timestamp] = Time.now
      end
    end
  end
end
