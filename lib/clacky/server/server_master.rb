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
        # 0. Kill any existing master on this port before binding.
        kill_existing_master

        # 1. Try to bind the socket.
        # If port is 7070 (default), try fallback ports 7071-7075 if occupied.
        # If port is non-default (user-specified), only try that exact port.
        original_port = @port
        max_port = (@port == 7070) ? (@port + 5) : @port
        @socket = bind_with_fallback(@host, @port, max_port: max_port)
        
        if @socket.nil?
          if @port == 7070
            Clacky::Logger.error("[Master] No available ports in range 7070-7075")
          else
            Clacky::Logger.error("[Master] Port #{@port} is in use")
          end
          exit(1)
        end
        
        @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
        @port = @socket.local_address.ip_port  # Update to actual bound port

        # 2. Print banner after port is determined
        print_banner(port_changed: @port != original_port, original_port: original_port)

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
        #
        # NOTE on stdio: we deliberately let the worker inherit Master's fd 0/1/2
        # so users see startup banner / request logs in their terminal. Protection
        # against Errno::EPIPE on broken parent stdout is installed inside the
        # worker itself (see cli.rb worker entry — EPIPESafeIO wrapper).
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

      # Try to bind to preferred_port, fall back to next ports if occupied.
      # Returns the bound TCPServer, or nil if all ports in range are occupied.
      def bind_with_fallback(host, preferred_port, max_port:)
        (preferred_port..max_port).each do |port|
          begin
            server = TCPServer.new(host, port)
            Clacky::Logger.info("[Master] Bound to port #{port}") if port != preferred_port
            return server
          rescue Errno::EADDRINUSE
            next
          end
        end
        nil
      end

      def print_banner(port_changed: false, original_port: nil)
        banner = Clacky::Banner.new
        puts ""
        puts banner.colored_cli_logo
        puts banner.colored_tagline
        puts ""
        
        if port_changed
          puts "   [!] Port #{original_port} is in use, using #{@port} instead"
          puts ""
        end
        
        puts "   Web UI: #{banner.highlight("http://#{@host}:#{@port}")}"
        puts "   Version: #{Clacky::VERSION}"
        puts "   Press Ctrl-C to stop."
        puts ""
      end

      # Scan all fallback port PID files to prevent duplicate masters
      # when a previous instance bound to a non-default fallback port.
      def kill_existing_master
        max_port = (@port == 7070) ? (@port + 5) : @port
        (@port..max_port).each do |port|
          kill_master_on_port(port)
        end
      end

      private def kill_master_on_port(port)
        path = File.join(Dir.tmpdir, "clacky-master-#{port}.pid")
        return unless File.exist?(path)

        pid = File.read(path).strip.to_i
        if pid <= 0
          File.delete(path) rescue nil
          return
        end

        begin
          Process.kill("TERM", pid)
          Clacky::Logger.info("[Master] Sent TERM to existing master (PID=#{pid}, port=#{port}), waiting...")

          deadline = Time.now + 5
          until process_dead?(pid) || Time.now > deadline
            sleep 0.1
          end

          unless process_dead?(pid)
            Clacky::Logger.warn("[Master] PID=#{pid} still alive after 5s, sending KILL...")
            Process.kill("KILL", pid) rescue Errno::ESRCH
          end

          Clacky::Logger.info("[Master] Existing master PID=#{pid} (port=#{port}) stopped.")
        rescue Errno::ESRCH
          Clacky::Logger.info("[Master] Existing master PID=#{pid} already gone.")
        rescue Errno::EPERM
          Clacky::Logger.warn("[Master] Could not stop existing master (PID=#{pid}) — permission denied.")
        ensure
          File.delete(path) if File.exist?(path)
        end
      end

      private def process_dead?(pid)
        Process.kill(0, pid)
        false
      rescue Errno::ESRCH
        true
      rescue Errno::EPERM
        false
      end
    end
  end
end
