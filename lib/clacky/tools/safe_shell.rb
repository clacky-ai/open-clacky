# frozen_string_literal: true

require "shellwords"
require "json"
require "fileutils"
require_relative "shell"
require_relative "../utils/trash_directory"
require_relative "../utils/encoding"

module Clacky
  module Tools
    class SafeShell < Shell
      self.tool_name = "safe_shell"
      self.tool_description = "Execute shell commands with enhanced security - dangerous commands are automatically made safe"
      self.tool_category = "system"
      self.tool_parameters = {
        type: "object",
        properties: {
          command: {
            type: "string",
            description: "Shell command to execute"
          },
          timeout: {
            type: "integer",
            description: "Command timeout in seconds (auto-detected if not specified: 60s for normal commands, 180s for build/install commands)"
          },
          max_output_lines: {
            type: "integer",
            description: "Maximum number of output lines to return (default: 1000)",
            default: 1000
          }
        },
        required: ["command"]
      }

      def execute(command:, timeout: nil, max_output_lines: 1000, skip_safety_check: false, output_buffer: nil, working_dir: nil)
        # Use provided working_dir or fall back to current process directory
        project_root = working_dir || Dir.pwd

        begin
          # 1. Extract timeout from command if it starts with "timeout N"
          command, extracted_timeout = extract_timeout_from_command(command)

          # Use extracted timeout if not explicitly provided
          timeout ||= extracted_timeout

          # 2. Use safety replacer to process command (skip if user already confirmed)
          if skip_safety_check
            # User has confirmed, execute command as-is (no safety modifications)
            safe_command = command
            safety_replacer = nil
          else
            safety_replacer = CommandSafetyReplacer.new(project_root)
            safe_command = safety_replacer.make_command_safe(command)
          end

          # 3. Calculate timeouts: soft_timeout is fixed at 5s, hard_timeout from timeout parameter
          soft_timeout = 5
          hard_timeout = calculate_hard_timeout(command, timeout)

          # 4. Call parent class execution method
          result = super(command: safe_command, soft_timeout: soft_timeout, hard_timeout: hard_timeout, max_output_lines: max_output_lines, output_buffer: output_buffer, working_dir: working_dir)

          # 5. Enhance result information
          enhance_result(result, command, safe_command, safety_replacer)

        rescue SecurityError => e
          # Security error, return friendly error message
          {
            command: command,
            stdout: "",
            stderr: "[Security Protection] #{e.message}",
            exit_code: 126,
            success: false,
            security_blocked: true
          }
        end
      end

      private def extract_timeout_from_command(command)
        # Match patterns: "timeout 30 ...", "timeout 30s ...", etc.
        # Also supports: "cd xxx && timeout 30 command", "export X=Y && timeout 30 command"
        # Supports: timeout N command, timeout Ns command, timeout -s SIGNAL N command

        # Use a UTF-8–safe copy for regex matching only; the original command
        # bytes are preserved in `command` and returned unchanged.
        safe_cmd = Clacky::Utils::Encoding.safe_check(command)
        
        # Try to match timeout at the beginning of command
        match = safe_cmd.match(/^timeout\s+(?:-s\s+\w+\s+)?(\d+)s?\s+(.+)$/i)
        
        if match
          timeout_value = match[1].to_i
          actual_command = match[2]
          return [actual_command, timeout_value]
        end
        
        # Try to match timeout after && or ;
        # Pattern: "prefix && timeout 30 command" or "prefix; timeout 30 command"
        match = safe_cmd.match(/^(.+?)\s*(&&|;)\s*timeout\s+(?:-s\s+\w+\s+)?(\d+)s?\s+(.+)$/i)
        
        if match
          prefix = match[1]          # e.g., "cd /tmp"
          separator = match[2]        # && or ;
          timeout_value = match[3].to_i
          main_command = match[4]     # e.g., "bundle exec rspec"
          
          # Reconstruct command without timeout prefix
          actual_command = "#{prefix} #{separator} #{main_command}"
          return [actual_command, timeout_value]
        end
        
        # No timeout found, return original command
        [command, nil]
      end

      private def calculate_hard_timeout(command, timeout)
        # If timeout is provided, use it directly
        return timeout if timeout

        # Otherwise, auto-detect based on command type
        is_slow = SLOW_COMMANDS.any? { |slow_cmd| command.include?(slow_cmd) }
        is_slow ? 180 : 60
      end

      # Safe read-only commands that don't modify system state
      SAFE_READONLY_COMMANDS = %w[
        ls pwd cat less more head tail
        grep find which whereis whoami
        ps top htop df du
        git echo printf wc
        date file stat
        env printenv
        curl wget
      ].freeze

      # Class method to check if a command is safe to execute automatically
      def self.command_safe_for_auto_execution?(command)
        return false unless command

        # Check if it's a known safe read-only command
        cmd_name = command.strip.split.first
        return true if SAFE_READONLY_COMMANDS.include?(cmd_name)

        begin
          project_root = Dir.pwd
          safety_replacer = CommandSafetyReplacer.new(project_root)
          safe_command = safety_replacer.make_command_safe(command)

          # If the command wasn't changed by the safety replacer, it's considered safe
          # This means it doesn't need any modifications to be secure
          command.strip == safe_command.strip
        rescue SecurityError
          # If SecurityError is raised, the command is definitely not safe
          false
        end
      end

      def enhance_result(result, original_command, safe_command, safety_replacer = nil)
        # If command was replaced, add security information
        if safety_replacer && original_command != safe_command
          result[:security_enhanced] = true
          result[:original_command] = original_command
          result[:safe_command] = safe_command

          # Add security note to stdout
          security_note = "[Safe] Command was automatically made safe\n"
          result[:stdout] = security_note + (result[:stdout] || "")
        end

        result
      end

      def format_call(args)
        cmd = args[:command] || args['command'] || ''
        return "safe_shell(<no command>)" if cmd.empty?

        # Truncate long commands intelligently
        if cmd.length > 150
          "safe_shell(\"#{cmd[0..147]}...\")"
        else
          "safe_shell(\"#{cmd}\")"
        end
      end

      def format_result(result)
        exit_code = result[:exit_code] || result['exit_code'] || 0
        stdout = result[:stdout] || result['stdout'] || ""
        stderr = result[:stderr] || result['stderr'] || ""

        if result[:security_blocked]
          "[Blocked] Security protection"
        elsif result[:security_enhanced]
          lines = stdout.lines.size
          "[Safe] Completed#{lines > 0 ? " (#{lines} lines)" : ''}"
        elsif exit_code == 0
          lines = stdout.lines.size
          "[OK] Completed#{lines > 0 ? " (#{lines} lines)" : ''}"
        else
          format_non_zero_exit(exit_code, stdout, stderr)
        end
      end

      # Override format_result_for_llm to preserve security fields
      def format_result_for_llm(result)
        # If security blocked, return as-is (small and important)
        return result if result[:security_blocked]
        
        # Call parent's format_result_for_llm to truncate output
        compact = super(result)
        
        # Add security enhancement fields if present (they're small and important for LLM to understand)
        if result[:security_enhanced]
          compact[:security_enhanced] = true
          compact[:original_command] = result[:original_command]
          compact[:safe_command] = result[:safe_command]
        end
        
        compact
      end

      private def format_non_zero_exit(exit_code, stdout, stderr)
        stdout_lines = stdout.lines.size
        has_output = stdout_lines > 0
        has_error = !stderr.empty?
        
        if has_error
          # Real error: show error summary
          error_summary = extract_error_summary(stderr)
          "[Exit #{exit_code}] #{error_summary}"
        elsif has_output
          # Command produced output but exited with non-zero code
          # This is common in commands like "ls; exit 1" or grep with no matches
          "[Exit #{exit_code}] #{stdout_lines} lines output"
        else
          # No output, no error message - just show exit code
          "[Exit #{exit_code}] No output"
        end
      end

      private def extract_error_summary(stderr)
        return "No error message" if stderr.empty?
        
        # Try to extract the most meaningful error line
        lines = stderr.lines.map(&:strip).reject(&:empty?)
        
        # Common error patterns with priority
        patterns = [
          # Ruby/Python exceptions with error type
          { regex: /(\w+(?:Error|Exception)):\s*(.+)$/, format: ->(m) { "#{m[1]}: #{m[2]}" } },
          # File not found patterns
          { regex: /cannot load such file.*--\s*(.+)$/, format: ->(m) { "Cannot load file: #{m[1]}" } },
          { regex: /No such file or directory.*[@\-]\s*(.+)$/, format: ->(m) { "File not found: #{m[1]}" } },
          # Undefined method/variable
          { regex: /undefined (?:local variable or )?method [`'](\w+)'/, format: ->(m) { "Undefined method: #{m[1]}" } },
          # Syntax errors
          { regex: /syntax error,?\s*(.+)$/i, format: ->(m) { "Syntax error: #{m[1]}" } }
        ]
        
        # Try each pattern on each line
        patterns.each do |pattern|
          lines.each do |line|
            match = line.match(pattern[:regex])
            if match
              result = pattern[:format].call(match)
              return truncate_error(clean_path(result), 80)
            end
          end
        end
        
        # Fallback: find the most informative line
        informative_line = lines.find do |line|
          !line.start_with?('from', 'Did you mean?', '#', 'Showing full backtrace') &&
          line.length > 10 &&
          (line.include?(':') || line.match?(/error|failed|cannot|invalid/i))
        end
        
        if informative_line
          return truncate_error(clean_path(informative_line), 80)
        end
        
        # Last resort: use first meaningful line
        first_line = lines.first || "Unknown error"
        truncate_error(clean_path(first_line), 80)
      end

      private def clean_path(text)
        # Remove long absolute paths, keep only filename
        text.gsub(/\/(?:Users|home)\/[^\/]+\/[\w\/\.\-]+\/([^:\/\s]+)/, '')
            .gsub(/\/[\w\/\.\-]{30,}\/([^:\/\s]+)/, '...')
      end

      private def truncate_error(text, max_length)
        return text if text.length <= max_length
        "#{text[0...max_length-3]}..."
      end
    end

    class CommandSafetyReplacer
      def initialize(project_root)
        @project_root = File.expand_path(project_root)
        
        # Use global trash directory organized by project
        trash_directory = Clacky::TrashDirectory.new(@project_root)
        @trash_dir = trash_directory.trash_dir
        @backup_dir = trash_directory.backup_dir
        
        # Setup safety log directory under ~/.clacky/safety_logs/
        @project_hash = trash_directory.generate_project_hash(@project_root)
        @safety_log_dir = File.join(Dir.home, ".clacky", "safety_logs", @project_hash)
        FileUtils.mkdir_p(@safety_log_dir) unless Dir.exist?(@safety_log_dir)
        @safety_log_file = File.join(@safety_log_dir, "safety.log")
      end

      def make_command_safe(command)
        command = command.strip

        # Safety checks use a UTF-8–scrubbed copy of the command so that
        # non-UTF-8 bytes in filenames (e.g. GBK-encoded Chinese paths from
        # zip archives) don't cause Encoding::InvalidByteSequenceError when
        # Ruby's regex / String#gsub tries to process them.
        # The original `command` (with original bytes) is returned unchanged
        # so the shell receives the exact bytes needed to locate the file.
        @safe_check_command = Clacky::Utils::Encoding.safe_check(command)

        case @safe_check_command
        when /^rm\s+/
          replace_rm_command(command)
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
          command  # validation passed, return original command with original bytes
        end
      end

      def replace_rm_command(command)
        files = parse_rm_files(command)

        if files.empty?
          raise SecurityError, "No files specified for deletion"
        end

        commands = files.map do |file|
          validate_file_path(file)

          timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%N")
          safe_name = "#{File.basename(file)}_deleted_#{timestamp}"
          trash_path = File.join(@trash_dir, safe_name)

          # Create deletion metadata
          create_delete_metadata(file, trash_path) if File.exist?(file)

          "mv #{Shellwords.escape(file)} #{Shellwords.escape(trash_path)}"
        end

        result = commands.join(' && ')
        log_replacement("rm", result, "Files moved to trash instead of permanent deletion")
        result
      end

      def replace_chmod_command(command)
        # Parse chmod command to ensure it's safe
        begin
          parts = Shellwords.split(command)
        rescue ArgumentError => e
          # If Shellwords.split fails, use simple split as fallback
          parts = command.split(/\s+/)
        end

        # Only allow chmod +x on files in project directory
        files = parts[2..-1] || []
        files.each { |file| validate_file_path(file) unless file.start_with?('-') }

        # Allow chmod +x as it's generally safe
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

      def block_sudo_command(command)
        raise SecurityError, "sudo commands are not allowed for security reasons"
      end

      def allow_dev_null_redirect(command)
        # Allow output redirection to /dev/null, this is usually safe
        command
      end

      def validate_and_allow(command)
        # Check basic file operation commands
        begin
          parts = Shellwords.split(command)
        rescue ArgumentError => e
          # If Shellwords.split fails due to quote issues, try simple split as fallback
          # This handles cases where paths don't actually need shell escaping
          parts = command.split(/\s+/)
        end
        
        cmd = parts.first
        args = parts[1..-1]

        case cmd
        when 'mv', 'cp'
          # Ensure target paths are within project
          args.each { |path| validate_file_path(path) unless path.start_with?('-') }
        when 'mkdir'
          # Check directory creation permissions
          args.each { |path| validate_directory_creation(path) unless path.start_with?('-') }
        end

        command
      end

      def validate_general_command(command)
        # Check general command security.
        # NOTE: `command` here is always a valid UTF-8 string (scrubbed before
        # calling this method), so gsub / match will not raise encoding errors.
        # Note: We need to be careful not to match patterns inside quoted strings
        
        # First, remove quoted strings to avoid false positives
        # This is a simplified approach - removes both single and double quoted content
        cmd_without_quotes = command.gsub(/'[^']*'|"[^"]*"/, '')
        
        dangerous_patterns = [
          /eval\s*\(/,
          /exec\s*\(/,
          /system\s*\(/,
          /`[^`]+`/,  # Command substitution with backticks (but only if not in quotes)
          /\$\([^)]+\)/,  # Command substitution with $() (but only if not in quotes)
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

      def parse_rm_files(command)
        begin
          parts = Shellwords.split(command)
        rescue ArgumentError => e
          # If Shellwords.split fails, use simple split as fallback
          parts = command.split(/\s+/)
        end
        
        # Skip rm command itself and option parameters
        parts.drop(1).reject { |part| part.start_with?('-') }
      end

      def validate_file_path(path)
        return if path.start_with?('-')  # Skip option parameters

        expanded_path = File.expand_path(path)

        # Ensure file is within project directory
        unless expanded_path.start_with?(@project_root)
          raise SecurityError, "File access outside project directory blocked: #{path}"
        end

        # Protect important files
        protected_patterns = [
          /Gemfile$/,
          /Gemfile\.lock$/,
          /README\.md$/,
          /LICENSE/,
          /\.gitignore$/,
          /package\.json$/,
          /yarn\.lock$/,
          /\.env$/,
          /\.ssh\//,
          /\.aws\//
        ]

        protected_patterns.each do |pattern|
          if expanded_path.match?(pattern)
            raise SecurityError, "Access to protected file blocked: #{File.basename(path)}"
          end
        end
      end

      def validate_directory_creation(path)
        expanded_path = File.expand_path(path)

        unless expanded_path.start_with?(@project_root)
          raise SecurityError, "Directory creation outside project blocked: #{path}"
        end
      end

      def create_delete_metadata(original_path, trash_path)
        metadata = {
          original_path: File.expand_path(original_path),
          project_root: @project_root,
          trash_directory: File.dirname(trash_path),
          deleted_at: Time.now.iso8601,
          deleted_by: 'AI_SafeShell',
          file_size: File.size(original_path),
          file_type: File.extname(original_path),
          file_mode: File.stat(original_path).mode.to_s(8)
        }

        metadata_file = "#{trash_path}.metadata.json"
        File.write(metadata_file, JSON.pretty_generate(metadata))
      rescue StandardError => e
        # If metadata creation fails, log warning but don't block operation
        log_warning("Failed to create metadata for #{original_path}: #{e.message}")
      end

      # setup_safety_dirs is now handled by TrashDirectory class
      # Keep this method for backward compatibility but it does nothing
      def setup_safety_dirs
        # Directories are now setup by TrashDirectory class
      end

      def log_replacement(original, replacement, reason)
        log_entry = {
          timestamp: Time.now.iso8601,
          action: 'command_replacement',
          original_command: original,
          safe_replacement: replacement,
          reason: reason
        }

        write_log(log_entry)
      end

      def log_blocked_operation(operation, reason)
        log_entry = {
          timestamp: Time.now.iso8601,
          action: 'operation_blocked',
          blocked_operation: operation,
          reason: reason
        }

        write_log(log_entry)
      end

      def log_warning(message)
        log_entry = {
          timestamp: Time.now.iso8601,
          action: 'warning',
          message: message
        }

        write_log(log_entry)
      end

      def write_log(log_entry)
        File.open(@safety_log_file, 'a') do |f|
          f.puts JSON.generate(log_entry)
        end
      rescue StandardError
        # If log writing fails, silently ignore, don't affect main functionality
      end
    end
  end
end
