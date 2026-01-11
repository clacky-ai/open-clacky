# frozen_string_literal: true

require "shellwords"
require "json"
require "fileutils"
require_relative "shell"
require_relative "../trash_directory"

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
          soft_timeout: {
            type: "integer",
            description: "Soft timeout in seconds (for interaction detection)"
          },
          hard_timeout: {
            type: "integer",
            description: "Hard timeout in seconds (force kill)"
          }
        },
        required: ["command"]
      }

      def execute(command:, soft_timeout: nil, hard_timeout: nil)
        # Get project root directory
        project_root = Dir.pwd

        begin
          # 1. Use safety replacer to process command
          safety_replacer = CommandSafetyReplacer.new(project_root)
          safe_command = safety_replacer.make_command_safe(command)

          # 2. Call parent class execution method
          result = super(command: safe_command, soft_timeout: soft_timeout, hard_timeout: hard_timeout)

          # 3. Enhance result information
          enhance_result(result, command, safe_command)

        rescue SecurityError => e
          # Security error, return friendly error message
          {
            command: command,
            stdout: "",
            stderr: "🔒 Security Protection: #{e.message}",
            exit_code: 126,
            success: false,
            security_blocked: true
          }
        end
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

      def enhance_result(result, original_command, safe_command)
        # If command was replaced, add security information
        if original_command != safe_command
          result[:security_enhanced] = true
          result[:original_command] = original_command
          result[:safe_command] = safe_command

          # Add security note to stdout
          security_note = "🔒 Command was automatically made safe\n"
          result[:stdout] = security_note + (result[:stdout] || "")
        end

        result
      end

      def format_call(args)
        cmd = args[:command] || args['command'] || ''
        return "safe_shell(<no command>)" if cmd.empty?

        # Truncate long commands intelligently
        if cmd.length > 50
          "safe_shell(\"#{cmd[0..47]}...\")"
        else
          "safe_shell(\"#{cmd}\")"
        end
      end

      def format_result(result)
        exit_code = result[:exit_code] || result['exit_code'] || 0
        stdout = result[:stdout] || result['stdout'] || ""
        stderr = result[:stderr] || result['stderr'] || ""

        if result[:security_blocked]
          "🔒 Blocked for security"
        elsif result[:security_enhanced]
          lines = stdout.lines.size
          "🔒✓ Safe execution#{lines > 0 ? " (#{lines} lines)" : ''}"
        elsif exit_code == 0
          lines = stdout.lines.size
          "✓ Completed#{lines > 0 ? " (#{lines} lines)" : ''}"
        else
          error_msg = stderr.lines.first&.strip || "Failed"
          "✗ Exit #{exit_code}: #{error_msg[0..50]}"
        end
      end
    end

    class CommandSafetyReplacer
      def initialize(project_root)
        @project_root = File.expand_path(project_root)
        
        # Use global trash directory organized by project
        trash_directory = Clacky::TrashDirectory.new(@project_root)
        @trash_dir = trash_directory.trash_dir
        @backup_dir = trash_directory.backup_dir
      end

      def make_command_safe(command)
        command = command.strip

        case command
        when /^rm\s+/
          replace_rm_command(command)
        when /^chmod\s+\+x/
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
          validate_general_command(command)
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
        parts = Shellwords.split(command)

        # Only allow chmod +x on files in project directory
        files = parts[2..-1] || []
        files.each { |file| validate_file_path(file) unless file.start_with?('-') }

        # Allow chmod +x as it's generally safe
        log_replacement("chmod", command, "chmod +x is allowed - file permissions will be modified")
        command
      rescue Shellwords::BadQuotedString
        raise SecurityError, "Invalid chmod command syntax: #{command}"
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
        parts = Shellwords.split(command)
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
      rescue Shellwords::BadQuotedString
        raise SecurityError, "Invalid command syntax: #{command}"
      end

      def validate_general_command(command)
        # Check general command security
        dangerous_patterns = [
          /eval\s*\(/,
          /exec\s*\(/,
          /system\s*\(/,
          /`.*`/,
          /\$\(.*\)/,
          /\|\s*sh\s*$/,
          /\|\s*bash\s*$/,
          />\s*\/etc\//,
          />\s*\/usr\//,
          />\s*\/bin\//
        ]

        dangerous_patterns.each do |pattern|
          if command.match?(pattern)
            raise SecurityError, "Dangerous command pattern detected: #{pattern.source}"
          end
        end

        command
      end

      def parse_rm_files(command)
        parts = Shellwords.split(command)
        # Skip rm command itself and option parameters
        parts.drop(1).reject { |part| part.start_with?('-') }
      rescue Shellwords::BadQuotedString
        raise SecurityError, "Invalid command syntax: #{command}"
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
        log_file = File.join(@project_root, '.ai_safety.log')
        File.open(log_file, 'a') do |f|
          f.puts JSON.generate(log_entry)
        end
      rescue StandardError
        # If log writing fails, silently ignore, don't affect main functionality
      end
    end
  end
end
