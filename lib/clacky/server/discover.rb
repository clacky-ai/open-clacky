# frozen_string_literal: true

require "tmpdir"
require "socket"

module Clacky
  module Server
    # Discover locally-running Clacky server(s) by scanning PID files
    # written by Master at /tmp/clacky-master-<port>.pid.
    #
    # Used by the CLI (bare `clacky agent` mode) to auto-detect a sibling
    # server process, so skills that call back into the server (channels,
    # browser, scheduler, etc.) can work without the user manually setting
    # CLACKY_SERVER_HOST / CLACKY_SERVER_PORT.
    #
    # Fast and side-effect free: only reads files and sends signal 0.
    # Does NOT probe the TCP port (avoids false positives from stale files
    # but also avoids noisy connection attempts).
    module Discover
      PID_FILE_GLOB = File.join(Dir.tmpdir, "clacky-master-*.pid").freeze
      PID_FILE_REGEX = /clacky-master-(\d+)\.pid\z/.freeze

      module_function

      # Find the first live Clacky server on this machine.
      #
      # @return [Hash, nil] { host: "127.0.0.1", port: Integer, pid: Integer } or nil
      def find_local
        find_all_local.first
      end

      # Find all live Clacky servers on this machine.
      #
      # A PID file is considered "live" when:
      #   1. The filename matches clacky-master-<port>.pid
      #   2. Its contents parse as a positive integer
      #   3. Process.kill(0, pid) confirms the PID is alive
      #
      # Stale PID files (process gone) are silently ignored. We do NOT
      # delete them here — that's the owning server's responsibility.
      #
      # @return [Array<Hash>] sorted by port ascending
      def find_all_local
        Dir.glob(PID_FILE_GLOB).filter_map do |path|
          m = path.match(PID_FILE_REGEX)
          next nil unless m

          port = m[1].to_i
          next nil if port <= 0

          pid_str = File.read(path).strip rescue nil
          next nil if pid_str.nil? || pid_str.empty?

          pid = pid_str.to_i
          next nil if pid <= 0

          next nil unless process_alive?(pid)

          { host: "127.0.0.1", port: port, pid: pid }
        end.sort_by { |e| e[:port] }
      end

      # @param pid [Integer]
      # @return [Boolean]
      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        # ESRCH — no such process; EPERM — process exists but owned by someone else
        # (still technically alive, but we can't safely assume it's "our" server)
        false
      rescue StandardError
        false
      end
    end
  end
end
