# frozen_string_literal: true

require "fileutils"
require "time"

module Clacky
  # Thread-safe daily-rotating file logger.
  #
  # Log files are written to ~/.clacky/logger/clacky-YYYY-MM-DD.log.
  # At most 7 daily log files are kept; older ones are pruned automatically.
  #
  # Usage (anywhere in the codebase):
  #   Clacky::Logger.info("server started")
  #   Clacky::Logger.debug("tool result", tool: "shell", exit_code: 0)
  #   Clacky::Logger.warn("retry attempt", n: 3)
  #   Clacky::Logger.error("unhandled exception", error: e)
  module Logger
    LOG_DIR        = File.join(Dir.home, ".clacky", "logger").freeze
    MAX_LOG_FILES  = 7
    MUTEX          = Mutex.new

    # Level constants (numeric, for future filtering)
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze

    # Minimum level to echo to $stderr when console output is enabled.
    # :debug → all; :info → info/warn/error; :warn → warn/error only
    CONSOLE_MIN_LEVEL = :info

    class << self
      # Enable/disable echoing log lines to $stderr (in addition to the file).
      # Call Clacky::Logger.console = true from server startup to activate.
      attr_writer :console

      private def console?
        @console ||= false
      end

      # Log at DEBUG level.
      def debug(message, **context)
        write_log(:debug, message, context)
      end

      # Log at INFO level.
      def info(message, **context)
        write_log(:info, message, context)
      end

      # Log at WARN level.
      def warn(message, **context)
        write_log(:warn, message, context)
      end

      # Log at ERROR level.  Accepts an optional :error key that may be an
      # Exception; its backtrace is appended automatically.
      def error(message, **context)
        write_log(:error, message, context)
      end

      private def write_log(level, message, context = {})
        now  = Time.now
        line = format_line(now, level, message, context)

        MUTEX.synchronize do
          ensure_log_dir
          File.open(log_file_path(now), "a") { |f| f.puts(line) }
          prune_old_logs
          echo_to_console(level, line) if console?
        end
      rescue StandardError
        # Never let logger errors crash the main process.
        nil
      end

      private def echo_to_console(level, line)
        return if LEVELS[level] < LEVELS[CONSOLE_MIN_LEVEL]
        $stderr.puts(line)
      rescue StandardError
        nil
      end

      private def format_line(time, level, message, context)
        timestamp = time.strftime("%Y-%m-%dT%H:%M:%S.%3N%z")
        tag       = level.to_s.upcase.ljust(5)
        base      = "[#{timestamp}] #{tag} #{message}"

        if context.empty?
          base
        else
          # Expand exception objects for :error key
          if (err = context[:error]).is_a?(Exception)
            context = context.merge(
              error:     "#{err.class}: #{err.message}",
              backtrace: (err.backtrace || []).first(10).join(" | ")
            )
          end
          pairs = context.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
          "#{base} | #{pairs}"
        end
      end

      private def log_file_path(time)
        File.join(LOG_DIR, "clacky-#{time.strftime('%Y-%m-%d')}.log")
      end

      private def ensure_log_dir
        FileUtils.mkdir_p(LOG_DIR) unless Dir.exist?(LOG_DIR)
      end

      # Remove log files older than MAX_LOG_FILES days.
      private def prune_old_logs
        logs = Dir.glob(File.join(LOG_DIR, "clacky-*.log")).sort
        excess = logs.length - MAX_LOG_FILES
        logs.first(excess).each { |f| File.delete(f) } if excess > 0
      end
    end
  end
end
