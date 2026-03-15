# frozen_string_literal: true

require "tmpdir"
require_relative "base"

module Clacky
  module Tools
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

        stdout_buffer = StringIO.new
        stderr_buffer = StringIO.new
        soft_timeout_triggered = false
        process_pid = nil
        
        # Store output buffer reference for real-time access (use LimitStack for memory efficiency)
        @output_buffer = output_buffer
        if @output_buffer
          @output_buffer[:stdout_lines] = Utils::LimitStack.new(max_size: 1000)
          @output_buffer[:stderr_lines] = Utils::LimitStack.new(max_size: 200)
        end
        @stdout_buffer = stdout_buffer
        @stderr_buffer = stderr_buffer

        # Use chdir option for thread-safe working directory (no global Dir.chdir needed)
        popen3_opts = {}
        popen3_opts[:chdir] = working_dir if working_dir && Dir.exist?(working_dir)

        begin
          Open3.popen3(wrap_with_shell(command), **popen3_opts) do |stdin, stdout, stderr, wait_thr|
            process_pid = wait_thr.pid
            start_time = Time.now

            stdout.sync = true
            stderr.sync = true

            begin
              loop do
                elapsed = Time.now - start_time

                if elapsed > hard_timeout
                  Process.kill('TERM', wait_thr.pid) rescue nil
                  sleep 0.5
                  Process.kill('KILL', wait_thr.pid) if wait_thr.alive? rescue nil

                  # Force-close stdout/stderr pipes so that any orphaned child
                  # processes (e.g. backgrounded with &) that still hold the pipe
                  # open don't keep popen3's block alive forever.
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

                if elapsed > soft_timeout && !soft_timeout_triggered
                  soft_timeout_triggered = true

                  # L1: Check for interaction patterns
                  interaction = detect_interaction(stdout_buffer.string)
                  if interaction
                    Process.kill('TERM', wait_thr.pid) rescue nil
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
                        # Update shared output buffer for real-time access
                        update_output_buffer
                      rescue IO::WaitReadable, EOFError
                      end
                    end
                  end
                rescue StandardError => e
                end

                sleep 0.1
              end

              # Drain any remaining output from pipes.
              # We must NOT use a plain blocking stdout.read here because
              # background processes launched with & inherit the pipe's write-end
              # fd and keep it open, causing read to block forever even after the
              # shell process itself has exited.
              # Use a short non-blocking drain loop instead so we flush any
              # buffered data without hanging indefinitely.
              drain_deadline = Time.now + 2
              [stdout, stderr].each do |io|
                buf = io == stdout ? stdout_buffer : stderr_buffer
                begin
                  loop do
                    remaining = drain_deadline - Time.now
                    break if remaining <= 0
                    ready = IO.select([io], nil, nil, [remaining, 0.1].min)
                    break unless ready
                    begin
                      buf.write(io.read_nonblock(4096))
                    rescue IO::WaitReadable
                      # no data right now, keep looping until deadline
                    rescue EOFError
                      break # pipe closed cleanly
                    end
                  end
                rescue StandardError
                end
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
              # Ensure child process is killed when block exits (for any reason: exception, return, etc.)
              if wait_thr&.alive?
                Process.kill('TERM', wait_thr.pid) rescue nil
                sleep 0.1
                Process.kill('KILL', wait_thr.pid) if wait_thr.alive? rescue nil
              end
            end
          end
        rescue StandardError => e
          # Handle other errors
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

      # Wrap command in an interactive shell so it loads user's rc files
      # (e.g. ~/.bashrc, ~/.zshrc) and picks up PATH changes from tools
      # like nvm, rbenv, brew, etc. Falls back to bash if $SHELL is unset.
      def wrap_with_shell(command)
        shell = ENV['SHELL'].to_s
        shell = '/bin/bash' if shell.empty?
        "#{shell} -l -c #{Shellwords.escape(command)}"
      end

      def determine_timeouts(command, soft_timeout, hard_timeout)
        # 检查是否是慢命令
        is_slow = SLOW_COMMANDS.any? { |slow_cmd| command.include?(slow_cmd) }

        if is_slow
          soft_timeout ||= 30
          hard_timeout ||= 180 # 3分钟
        else
          soft_timeout ||= 7
          hard_timeout ||= 60
        end

        [soft_timeout, hard_timeout]
      end

      # L1: 规则检测
      def detect_interaction(output)
        return nil if output.empty?

        lines = output.split("\n").last(10)

        lines.reverse.each do |line|
          line_stripped = line.strip
          next if line_stripped.empty?

          INTERACTION_PATTERNS.each do |pattern, type|
            if line.match?(pattern)
              return { type: type, line: line_stripped }
            end
          end
        end

        nil
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
        <<~MSG
          #{output}

          #{'=' * 60}
          [Terminal State: WAITING_INPUT]
          #{'=' * 60}

          The terminal is waiting for your input.

          Detected pattern: #{interaction[:type]}
          Last line: #{interaction[:line]}

          Suggested actions:
          • Provide answer: run shell with your response
          • Cancel: send Ctrl+C (\\x03)
        MSG
      end

      def format_timeout_result(command, stdout, stderr, elapsed, type, timeout, max_output_lines)
        {
          command: command,
          stdout: truncate_output(stdout, max_output_lines),
          stderr: truncate_output(stderr.empty? ? "Command timed out after #{elapsed.round(1)} seconds (#{type}=#{timeout}s)" : stderr, max_output_lines),
          exit_code: -1,
          success: false,
          state: 'TIMEOUT',
          timeout_type: type,
          output_truncated: output_truncated?(stdout, stderr, max_output_lines)
        }
      end

      # Truncate output to max_lines, adding a truncation notice if needed
      def truncate_output(output, max_lines)
        return output if output.nil? || output.empty?

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
        # Return error info as-is if command failed or timed out
        return result if result[:error] || result[:state] == 'TIMEOUT' || result[:state] == 'WAITING_INPUT'

        stdout = result[:stdout] || ""
        stderr = result[:stderr] || ""
        exit_code = result[:exit_code] || 0

        # Build compact result with truncated output
        compact = {
          command: result[:command],
          exit_code: exit_code,
          success: result[:success]
        }

        # Add elapsed time if available (keep original precision)
        compact[:elapsed] = result[:elapsed] if result[:elapsed]

        # Extract command name for temp file naming
        command_name = extract_command_name(result[:command])

        # Process stdout: truncate and optionally save to temp file
        stdout_info = truncate_and_save(stdout, MAX_LLM_OUTPUT_CHARS, "stdout", command_name)
        compact[:stdout] = stdout_info[:content]
        compact[:stdout_full] = stdout_info[:temp_file] if stdout_info[:temp_file]

        # Process stderr: truncate and optionally save to temp file
        stderr_info = truncate_and_save(stderr, MAX_LLM_OUTPUT_CHARS, "stderr", command_name)
        compact[:stderr] = stderr_info[:content]
        compact[:stderr_full] = stderr_info[:temp_file] if stderr_info[:temp_file]

        # Add output_truncated flag if present
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

        # Truncate individual long lines first (e.g., minified CSS/JS files)
        # This prevents a single huge line from consuming all token budget
        output = truncate_long_lines(output, MAX_LINE_CHARS)

        return { content: output, temp_file: nil } if output.length <= max_chars

        # Sanitize command name for file name
        safe_name = command_name.gsub(/[^\w\-.]/, "_")[0...50]

        # Use Ruby tmpdir for safe temp file creation
        temp_dir = Dir.mktmpdir
        temp_file = File.join(temp_dir, "#{safe_name}_#{Time.now.strftime("%Y%m%d_%H%M%S")}.output")

        # Write full output to temp file
        File.write(temp_file, output)

        # For LLM display: show first N lines to preserve most useful information
        lines = output.lines
        return { content: output, temp_file: nil } if lines.length <= 2

        # Reserve space for truncation notice (including temp file path)
        notice_overhead = 200
        available_chars = max_chars - notice_overhead

        # Prioritize first lines as they usually contain the most important information
        first_part = []
        accumulated = 0
        lines.each do |line|
          break if accumulated + line.length > available_chars
          first_part << line
          accumulated += line.length
        end

        total_lines = lines.length
        shown_lines = first_part.length

        # Create prominent notice message with temp file path
        if label == "stderr"
          notice = <<~NOTICE

            ... [Error output truncated for LLM: showing #{shown_lines} of #{total_lines} lines, full content: #{temp_file} (use grep to search)] ...
          NOTICE
        else
          notice = <<~NOTICE

            ... [Output truncated for LLM: showing #{shown_lines} of #{total_lines} lines, full content: #{temp_file} (use grep to search)] ...
          NOTICE
        end

        # Combine with compact notice
        content = first_part.join + notice

        { content: content, temp_file: temp_file }
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

        # Push new lines to LimitStack (automatically handles size limit)
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
