# frozen_string_literal: true

require "socket"
require "tmpdir"
require_relative "../banner"
require_relative "../version"

module Clacky
  module Server
    # Master process — owns the listen socket, spawns/monitors worker processes.
    #
    # Lifecycle:
    #   clacky server
    #     └─ Master.run  (this file)
    #           ├─ creates TCPServer, holds it forever
    #           ├─ spawns Worker via spawn() — full new Ruby process, loads fresh gem
    #           ├─ traps USR1 → hot_restart (spawn new worker, gracefully stop old)
    #           └─ traps TERM/INT → shutdown (stop worker, exit cleanly)
    #
    # Worker receives:
    #   CLACKY_WORKER=1          — "I am a worker, start HttpServer directly"
    #   CLACKY_INHERIT_FD=<n>   — file descriptor number of the inherited TCPServer socket
    #   CLACKY_MASTER_PID=<n>   — master PID so worker can send USR1 back on upgrade
    class Master
      # Worker exits with this code to request a hot restart (e.g. after gem upgrade).
      RESTART_EXIT_CODE        = 75
      MAX_CONSECUTIVE_FAILURES = 5

      # How long (seconds) to wait for a new worker to become ready before killing the old one.
      NEW_WORKER_BOOT_WAIT = 3

      def initialize(host:, port:, argv: nil, extra_flags: [])
        @host   = host
        @port   = port
        @argv   = argv          # kept for backward compat but no longer used
        @extra_flags = extra_flags  # e.g. ["--brand-test"]

        @socket     = nil
        @worker_pid = nil
        @restart_requested = false
        @shutdown_requested = false
      end

      def run
        # 0. Print banner first — before any log output
        print_banner

        # 1. Kill any existing master on this port before binding.
        kill_existing_master

        # 2. Bind the socket once — master holds it for the entire lifetime.
        @socket = TCPServer.new(@host, @port)
        @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)

        write_pid_file

        # 3. Signal handlers
        Signal.trap("USR1") { @restart_requested  = true }
        Signal.trap("TERM") { @shutdown_requested = true }
        Signal.trap("INT")  { @shutdown_requested = true }
        Signal.trap("HUP")  { @shutdown_requested = true }

        # 4. Spawn first worker
        @worker_pid = spawn_worker
        @consecutive_failures = 0

        # 4. Monitor loop
        loop do
          if @shutdown_requested
            shutdown
            break
          end

          if @restart_requested
            @restart_requested = false
            hot_restart
            @consecutive_failures = 0
          end

          # Non-blocking wait: check if worker has exited
          pid, status = Process.waitpid2(@worker_pid, Process::WNOHANG)
          if pid
            exit_code = status.exitstatus
            if exit_code == RESTART_EXIT_CODE
              Clacky::Logger.info("[Master] Worker requested restart (exit #{RESTART_EXIT_CODE}).")
              @worker_pid = spawn_worker
              @consecutive_failures = 0
            elsif @shutdown_requested
              break
            else
              @consecutive_failures += 1
              if @consecutive_failures >= MAX_CONSECUTIVE_FAILURES
                Clacky::Logger.error("[Master] Worker failed #{MAX_CONSECUTIVE_FAILURES} times in a row, giving up.")
                shutdown
                break
              end
              delay = [0.5 * (2 ** (@consecutive_failures - 1)), 30].min  # exponential backoff, max 30s
              Clacky::Logger.warn("[Master] Worker exited unexpectedly (exit #{exit_code}), failure #{@consecutive_failures}/#{MAX_CONSECUTIVE_FAILURES}, restarting in #{delay}s...")
              sleep delay
              @worker_pid = spawn_worker
            end
          end

          sleep 0.1
        end
      ensure
        remove_pid_file
      end


      # Spawn a fresh Ruby process that loads the (possibly updated) gem from disk.
      # The listen socket is inherited via its file descriptor number.
      def spawn_worker
        env = {
          "CLACKY_WORKER"      => "1",
          "CLACKY_INHERIT_FD"  => @socket.fileno.to_s,
          "CLACKY_MASTER_PID"  => Process.pid.to_s
        }
        # Keep the socket fd open across exec — mark it as non-CLOEXEC.
        @socket.close_on_exec = false

        # Reconstruct the worker command explicitly.
        # We cannot rely on ARGV (Thor has already consumed it), so we rebuild
        # the minimal args: `clacky server --host HOST --port PORT [extra_flags]`
        ruby   = RbConfig.ruby
        script = File.expand_path($0)
        worker_argv = ["server", "--host", @host.to_s, "--port", @port.to_s] + @extra_flags

        Clacky::Logger.info("[Master PID=#{Process.pid}] spawn: #{ruby} #{script} #{worker_argv.join(' ')}")
        Clacky::Logger.info("[Master PID=#{Process.pid}] env: #{env.inspect}")
        # pgroup: 0 puts worker in its own process group.
        # This lets Master send TERM/KILL to the entire group (-pid) on shutdown,
        # ensuring grandchildren (e.g. chrome-devtools-mcp node process) are also
        # cleaned up even if the worker is force-killed before its shutdown_proc runs.
        pid = spawn(env, ruby, script, *worker_argv, pgroup: 0)
        Clacky::Logger.info("[Master PID=#{Process.pid}] Spawned worker PID=#{pid} pgroup=#{pid}")
        pid
      end

      # Spawn a new worker, wait for it to boot, then gracefully stop the old one.
      def hot_restart
        old_pid = @worker_pid
        Clacky::Logger.info("[Master] Hot restart: spawning new worker (old PID=#{old_pid})...")

        new_pid = spawn_worker
        @worker_pid = new_pid

        # Give the new worker time to bind and start serving
        sleep NEW_WORKER_BOOT_WAIT

        # Gracefully stop old worker — TERM the whole process group first so
        # grandchildren (node MCP, etc.) also get a chance to shut down cleanly.
        begin
          Process.kill("TERM", -old_pid)
          # Reap it (non-blocking loop so we don't block the monitor)
          deadline = Time.now + 5
          loop do
            pid, = Process.waitpid2(old_pid, Process::WNOHANG)
            break if pid
            break if Time.now > deadline
            sleep 0.1
          end
          Process.kill("KILL", -old_pid) rescue nil  # force-kill entire group if still alive
        rescue Errno::ESRCH
          # already gone — fine
        end

        Clacky::Logger.info("[Master] Hot restart complete. New worker PID=#{new_pid}")
      end

      def shutdown
        Clacky::Logger.info("[Master] Shutting down (worker PID=#{@worker_pid})...")
        if @worker_pid
          begin
            # TERM the entire worker process group so grandchildren (node MCP, etc.)
            # are also signalled and can clean up before we force-kill.
            Process.kill("TERM", -@worker_pid)
            # Wait up to 2s for worker graceful exit, then KILL the whole group
            deadline = Time.now + 3
            loop do
              pid, = Process.waitpid2(@worker_pid, Process::WNOHANG)
              break if pid
              if Time.now > deadline
                Clacky::Logger.warn("[Master] Worker did not exit in time, sending KILL...")
                Process.kill("KILL", -@worker_pid) rescue nil
                break
              end
              sleep 0.1
            end
          rescue Errno::ESRCH, Errno::ECHILD
            # already gone
          end
        end
        @socket.close rescue nil
        Clacky::Logger.info("[Master] Exited.")
        exit(0)
      end

      def pid_file_path
        File.join(Dir.tmpdir, "clacky-master-#{@port}.pid")
      end

      def write_pid_file
        File.write(pid_file_path, Process.pid.to_s)
      end

      def remove_pid_file
        File.delete(pid_file_path) if File.exist?(pid_file_path)
      end

      def port_free_within?(seconds)
        deadline = Time.now + seconds
        loop do
          begin
            TCPServer.new(@host, @port).close
            return true
          rescue Errno::EADDRINUSE
            return false if Time.now > deadline
            sleep 0.1
          end
        end
      end

      def print_banner
        banner = Clacky::Banner.new
        puts ""
        puts banner.colored_cli_logo
        puts banner.colored_tagline
        puts ""
        puts "   Web UI: #{banner.highlight("http://#{@host}:#{@port}")}"
        puts "   Version: #{Clacky::VERSION}"
        puts "   Press Ctrl-C to stop."
        puts ""
      end

      def kill_existing_master
        return unless File.exist?(pid_file_path)

        pid = File.read(pid_file_path).strip.to_i
        return if pid <= 0

        begin
          Process.kill("TERM", pid)
          Clacky::Logger.info("[Master] Sent TERM to existing master (PID=#{pid}), waiting up to 3s...")

          unless port_free_within?(5)
            Clacky::Logger.warn("[Master] Port #{@port} still in use after 5s, sending KILL to PID=#{pid}...")
            Process.kill("KILL", pid) rescue Errno::ESRCH
            unless port_free_within?(2)
              Clacky::Logger.error("[Master] Port #{@port} still in use after KILL, giving up.")
              exit(1)
            end
          end

          Clacky::Logger.info("[Master] Port #{@port} is now free.")
        rescue Errno::ESRCH
          Clacky::Logger.info("[Master] Existing master PID=#{pid} already gone.")
        rescue Errno::EPERM
          Clacky::Logger.warn("[Master] Could not stop existing master (PID=#{pid}) — permission denied.")
          exit(1)
        ensure
          File.delete(pid_file_path) if File.exist?(pid_file_path)
        end
      end
    end
  end
end
