# frozen_string_literal: true

require_relative "base"
require_relative "../utils/limit_stack"
require_relative "../utils/encoding"
require "yaml"
require "open3"

module Clacky
  module Tools
    class RunProject < Base
      self.tool_name = "run_project"
      self.tool_description = "Start, stop, or get status of the project dev server from .1024 config"
      self.tool_category = "system"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ["start", "stop", "status", "output"],
            description: "Action to perform: start (launch dev server), stop (kill dev server), status (check if running), output (get recent logs)"
          },
          max_lines: {
            type: "integer",
            description: "For 'output' action: max lines of logs to return (default: 100)"
          }
        },
        required: ["action"]
      }

      CONFIG_PATHS = ['.1024', '.clackyai/.environments.yaml'].freeze

      @@process_state = nil
      @@reader_thread = nil

      def initialize
        super
      end

      def execute(action:, max_lines: 100, working_dir: nil)
        @working_dir = working_dir if working_dir
        case action
        when "start"
          start_project
        when "stop"
          stop_project
        when "status"
          get_status
        when "output"
          get_output(max_lines)
        else
          { error: "Unknown action: #{action}" }
        end
      end

      def format_call(args)
        action = args[:action] || args['action']

        case action
        when 'start'
          config = load_project_config
          if config && (cmd = config['run_command'] || config['run_commands'])
            cmd = cmd.join(' && ') if cmd.is_a?(Array)
            cmd_preview = cmd.length > 40 ? "#{cmd[0..40]}..." : cmd
            "RunProject(start: #{cmd_preview})"
          else
            "RunProject(start)"
          end
        when 'output'
          max_lines = args[:max_lines] || args['max_lines'] || 100
          "RunProject(output: #{max_lines} lines)"
        else
          "RunProject(#{action})"
        end
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error]}"
        elsif result[:status]
          case result[:status]
          when 'started'
            cmd_preview = result[:command] ? result[:command][0..50] : ''
            output_preview = result[:output]&.lines&.first(2)&.join&.strip
            msg = "[OK] Started (PID: #{result[:pid]}, cmd: #{cmd_preview})"
            msg += "\n  #{output_preview}" if output_preview && !output_preview.empty?
            msg
          when 'stopped'
            "[OK] Stopped"
          when 'running'
            uptime = result[:uptime] ? "#{result[:uptime].round(1)}s" : "unknown"
            "[Running] #{uptime}, PID: #{result[:pid]}"
          when 'not_running'
            "[Not Running]"
          else
            result[:status].to_s
          end
        else
          "Done"
        end
      end


      def start_project
        config = load_project_config
        return { error: "No .1024 config file found. Create .1024 with 'run_command: your_command'" } unless config

        command = config['run_command'] || config['run_commands']
        return { error: "No 'run_command' defined in .1024" } unless command

        command = command.join(' && ') if command.is_a?(Array)

        stop_existing_process if @@process_state

        begin
          stdin, stdout, stderr, wait_thr = Open3.popen3(command)

          @@process_state = {
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            thread: wait_thr,
            start_time: Time.now,
            command: command,
            stdout_buffer: Utils::LimitStack.new(max_size: 5000),
            stderr_buffer: Utils::LimitStack.new(max_size: 5000)
          }

          start_output_reader_thread

          sleep 2

          output = read_buffered_output(max_lines: 50)

          {
            status: 'started',
            pid: wait_thr.pid,
            command: command,
            output: output,
            message: "Project started in background. Use run_project(action: 'output') to check logs."
          }
        rescue StandardError => e
          @@process_state = nil
          {
            error: "Failed to start project: #{e.message}",
            command: command
          }
        end
      end

      def stop_project
        return { status: 'not_running', message: 'No running process to stop' } unless @@process_state

        thread = @@process_state[:thread]
        pid = thread.pid

        begin
          if thread.alive?
            Process.kill('INT', pid)
            sleep 1

            if thread.alive?
              Process.kill('KILL', pid) rescue nil
            end
          end

          @@reader_thread&.kill

          @@process_state = nil
          @@reader_thread = nil

          {
            status: 'stopped',
            message: "Process #{pid} stopped successfully"
          }
        rescue StandardError => e
          {
            error: "Failed to stop process: #{e.message}"
          }
        end
      end

      def get_status
        if @@process_state && @@process_state[:thread].alive?
          {
            status: 'running',
            pid: @@process_state[:thread].pid,
            uptime: Time.now - @@process_state[:start_time],
            command: @@process_state[:command]
          }
        else
          { status: 'not_running' }
        end
      end

      def get_output(max_lines)
        return { error: 'No running process' } unless @@process_state

        output = read_buffered_output(max_lines: max_lines)

        {
          status: 'running',
          pid: @@process_state[:thread].pid,
          uptime: Time.now - @@process_state[:start_time],
          output: output
        }
      end

      def stop_existing_process
        return unless @@process_state

        thread = @@process_state[:thread]
        if thread.alive?
          Process.kill('INT', thread.pid) rescue nil
          sleep 1

          if thread.alive?
            Process.kill('KILL', thread.pid) rescue nil
          end
        end

        @@reader_thread&.kill
        @@process_state = nil
        @@reader_thread = nil
      end

      def load_project_config
        base = @working_dir || Dir.pwd
        CONFIG_PATHS.each do |path|
          full_path = File.join(base, path)
          next unless File.exist?(full_path)

          begin
            content = File.read(full_path)
            return YAML.safe_load(content)
          rescue StandardError => e
            next
          end
        end

        nil
      end

      def start_output_reader_thread
        @@reader_thread = Thread.new do
          loop do
            break unless @@process_state

            stdout = @@process_state[:stdout]
            stderr = @@process_state[:stderr]
            stdout_buf = @@process_state[:stdout_buffer]
            stderr_buf = @@process_state[:stderr_buffer]

            begin
              ready = IO.select([stdout, stderr], nil, nil, 0.5)
              if ready
                ready[0].each do |io|
                  begin
                    data = io.read_nonblock(4096)
                    # Convert binary shell output to valid UTF-8, preserving multibyte chars
                    data = Clacky::Utils::Encoding.to_utf8(data)
                    
                    if io == stdout
                      stdout_buf.push_lines(data)
                    else
                      stderr_buf.push_lines(data)
                    end
                  rescue IO::WaitReadable, EOFError
                  end
                end
              end
            rescue StandardError => e
            end

            sleep 0.1
          end
        end
      end

      def read_buffered_output(max_lines:)
        return "" unless @@process_state

        stdout_lines = @@process_state[:stdout_buffer].to_a
        stderr_lines = @@process_state[:stderr_buffer].to_a

        # Combine and get last N lines
        all_lines = (stdout_lines + stderr_lines).last(max_lines)
        all_lines.join
      end
    end
  end
end
