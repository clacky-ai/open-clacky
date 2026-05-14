# frozen_string_literal: true

require "yaml"
require "shellwords"
require "json"
require "socket"
require "timeout"
require "fileutils"

module Clacky
  # BrowserManager — owns access to chrome-devtools-mcp via a long-lived
  # **detached** Ruby daemon (lib/clacky/server/mcp_daemon.rb).
  #
  # The daemon process survives Clacky restarts and Chrome tab churn, so
  # Chrome's remote-debugging authorization is only required on the FIRST
  # connection; subsequent Clacky restarts and tab closures reuse the same
  # WebSocket session held by chrome-devtools-mcp.
  #
  # Public API (unchanged from previous chrome-devtools-mcp-direct version):
  #   start    - launch daemon if browser.yml says enabled
  #   stop     - close local socket connection (does NOT kill daemon)
  #   reload   - kill daemon + restart (called when browser.yml changes)
  #   status   - { enabled, daemon_running, chrome_version }
  #   configure(chrome_version:) - write browser.yml + reload
  #   toggle   - flip enabled in browser.yml + reload
  #   mcp_call(tool_name, args) - forward MCP tool call through socket
  class BrowserManager
    BROWSER_CONFIG_PATH = File.expand_path("~/.clacky/browser.yml").freeze
    SOCKET_PATH         = File.expand_path("~/.clacky/mcp-daemon.sock").freeze
    PID_PATH            = File.expand_path("~/.clacky/mcp-daemon.pid").freeze
    DAEMON_SCRIPT       = File.expand_path("mcp_daemon.rb", __dir__).freeze
    DAEMON_STARTUP_TIMEOUT = 15

    class << self
      def instance
        @instance ||= new
      end
    end

    def initialize
      @mutex   = Mutex.new
      @call_id = 2
      @config  = {}
    end

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start
      cfg = load_config
      unless cfg["enabled"] == true
        Clacky::Logger.info("[BrowserManager] Not enabled — skipping daemon start")
        return
      end

      @config = cfg
      Clacky::Logger.info("[BrowserManager] Browser enabled, ensuring MCP daemon is running...")
      Thread.new do
        Thread.current.name = "browser-manager-start"
        @mutex.synchronize { ensure_daemon! }
      rescue Clacky::BrowserNotReachableError
        Clacky::Logger.debug("[BrowserManager] Skipping pre-warm: Chrome not running")
      rescue StandardError => e
        msg = e.message.to_s.lines.first&.strip || e.message.to_s
        Clacky::Logger.warn("[BrowserManager] Pre-warm failed: #{msg}")
      end
    end

    # On Clacky shutdown we intentionally LEAVE the daemon running so that
    # the next Clacky startup can reuse the existing Chrome connection and
    # avoid re-authorization.
    def stop
      Clacky::Logger.info("[BrowserManager] Stop (daemon left running for restart reuse)")
    end

    # Explicit daemon kill — only used when chrome config changes or on
    # `reload`. NOT called on Clacky shutdown.
    def force_stop
      @mutex.synchronize { kill_daemon! }
      Clacky::Logger.info("[BrowserManager] Daemon force-stopped")
    end

    def reload
      Clacky::Logger.info("[BrowserManager] Reloading...")
      @mutex.synchronize { kill_daemon! }

      cfg = load_config
      @config = cfg

      if cfg["enabled"] == true
        Clacky::Logger.info("[BrowserManager] Browser enabled, restarting daemon")
        Thread.new do
          Thread.current.name = "browser-manager-reload"
          @mutex.synchronize { ensure_daemon! }
        rescue Clacky::BrowserNotReachableError
          Clacky::Logger.debug("[BrowserManager] Skipping reload start: Chrome not running")
        rescue StandardError => e
          msg = e.message.to_s.lines.first&.strip || e.message.to_s
          Clacky::Logger.warn("[BrowserManager] Reload start failed: #{msg}")
        end
      else
        Clacky::Logger.info("[BrowserManager] Browser disabled after reload — daemon not started")
      end
    end

    def status
      cfg     = load_config
      enabled = cfg["enabled"] == true
      {
        enabled:        enabled,
        daemon_running: daemon_responding?,
        chrome_version: cfg["chrome_version"]
      }
    end

    def configure(chrome_version:)
      cfg = {
        "enabled"        => true,
        "browser"        => "chrome",
        "chrome_version" => chrome_version.to_s,
        "configured_at"  => Date.today.to_s
      }
      FileUtils.mkdir_p(File.dirname(BROWSER_CONFIG_PATH))
      File.write(BROWSER_CONFIG_PATH, cfg.to_yaml)
      reload
    end

    def toggle
      raise "Browser not configured. Run /browser-setup first." unless File.exist?(BROWSER_CONFIG_PATH)

      cfg         = load_config
      new_enabled = !(cfg["enabled"] == true)
      cfg["enabled"] = new_enabled
      File.write(BROWSER_CONFIG_PATH, cfg.to_yaml)
      @config = cfg
      reload
      new_enabled
    end

    # ------------------------------------------------------------------
    # MCP call interface
    # ------------------------------------------------------------------

    def mcp_call(tool_name, arguments = {})
      attempts = 0
      begin
        @mutex.synchronize do
          ensure_daemon!

          call_id  = @call_id
          @call_id += 1

          req = {
            jsonrpc: "2.0",
            id:      call_id,
            method:  "tools/call",
            params:  { name: tool_name, arguments: arguments }
          }

          resp = send_to_daemon(req, timeout: Clacky::Tools::Browser::MCP_CALL_TIMEOUT)

          if resp["error"]
            err = resp["error"]
            raise "Chrome MCP error: #{err.is_a?(Hash) ? err["message"] : err}"
          end

          result = resp["result"] || {}

          if result["isError"]
            text = extract_text_content(result)
            raise text.empty? ? "Chrome MCP tool '#{tool_name}' failed" : text
          end

          result
        end
      rescue Errno::ECONNREFUSED, Errno::ENOENT, Errno::EPIPE, IOError => e
        attempts += 1
        if attempts <= 1
          Clacky::Logger.warn("[BrowserManager] Daemon connection lost (#{e.class}), respawning and retrying")
          File.unlink(SOCKET_PATH) if File.exist?(SOCKET_PATH)
          retry
        end
        raise
      end
    rescue Clacky::BrowserNotReachableError => e
      raise Clacky::AgentError, e.message
    end

    # ------------------------------------------------------------------
    # Private
    # ------------------------------------------------------------------

    private

    def load_config
      return {} unless File.exist?(BROWSER_CONFIG_PATH)
      YAMLCompat.safe_load(File.read(BROWSER_CONFIG_PATH), permitted_classes: [Date, Time, Symbol]) || {}
    rescue StandardError => e
      Clacky::Logger.warn("[BrowserManager] Failed to read browser.yml: #{e.message}")
      {}
    end

    # Called inside @mutex.
    # Ensures the mcp_daemon process exists and the Unix socket answers ping.
    # Also verifies the daemon's wsEndpoint matches the current Chrome instance —
    # if Chrome was restarted (new UUID), the daemon's WebSocket is dead and we
    # must respawn even though ping succeeds.
    def ensure_daemon!
      detected = Clacky::Utils::BrowserDetector.detect
      if detected[:status] == :not_found
        raise Clacky::BrowserNotReachableError, <<~MSG.strip
          Chrome/Edge is not running or remote debugging is not enabled.

          Please:
          1. Open Chrome or Edge
          2. Enable remote debugging: Visit chrome://inspect/#remote-debugging and click "Allow remote debugging"
          3. Retry this action

          The browser tool will automatically reconnect once Chrome is running.
        MSG
      end

      current_endpoint = detected[:mode] == :ws_endpoint ? detected[:value].to_s : ""

      if daemon_responding?
        if daemon_endpoint == current_endpoint
          return
        end
        Clacky::Logger.info("[BrowserManager] Daemon endpoint stale (Chrome restarted?); respawning")
        kill_daemon!
      end

      spawn_daemon!(detected)
      wait_for_daemon!
      Clacky::Logger.info("[BrowserManager] MCP daemon is responding")
    end

    # Health check: connect to socket and send daemon.ping.
    # Returns true only if the daemon answers within 2s.
    def daemon_responding?
      return false unless File.exist?(SOCKET_PATH)
      req = { jsonrpc: "2.0", id: 0, method: "daemon.ping" }
      resp = send_to_daemon(req, timeout: 2)
      resp.is_a?(Hash) && resp["result"].is_a?(Hash) && resp["result"]["ok"]
    rescue StandardError
      false
    end

    # Returns the wsEndpoint the daemon was started with, via daemon.ping.
    # Empty string means daemon doesn't know or isn't running.
    def daemon_endpoint
      return "" unless File.exist?(SOCKET_PATH)
      req = { jsonrpc: "2.0", id: 0, method: "daemon.ping" }
      resp = send_to_daemon(req, timeout: 2)
      resp.dig("result", "endpoint").to_s
    rescue StandardError
      ""
    end

    # Spawn the mcp_daemon.rb script as a detached process so it survives
    # the parent Clacky process exit. Uses Process.spawn with:
    #   - close_others: true (no inherited fds)
    #   - new_pgroup / setsid (detach from Clacky's process group/session)
    #   - stdin/stdout/stderr redirected to /dev/null and log file
    def spawn_daemon!(detected)
      lock_path = File.expand_path("~/.clacky/mcp-daemon.spawn.lock")
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        # Re-check under lock — another process may have started the daemon
        # while we were waiting.
        return if daemon_responding?

        File.unlink(SOCKET_PATH) if File.exist?(SOCKET_PATH) && !pid_alive?
        spawn_daemon_locked!(detected)
      end
    end

    def spawn_daemon_locked!(detected)
      chrome_cmd = build_chrome_mcp_command(detected)
      log_path   = File.expand_path("~/.clacky/mcp-daemon.spawn.log")
      FileUtils.mkdir_p(File.dirname(log_path))

      # Build the daemon argv. We use Bundler's ruby if available.
      ruby_bin = RbConfig.ruby
      daemon_argv = [ruby_bin, DAEMON_SCRIPT, "--", *chrome_cmd]

      # We need chrome-devtools-mcp on PATH. Use login_shell wrapper so mise/nvm
      # activate before exec.
      inner   = daemon_argv.map { |a| Shellwords.escape(a.to_s) }.join(" ")
      wrapped = Clacky::Utils::LoginShell.login_shell_command(inner)

      Clacky::Logger.info("[BrowserManager] Spawning MCP daemon: #{daemon_argv.join(' ')}")

      pid = Process.spawn(
        *wrapped,
        in: :close,
        out: [log_path, "a"],
        err: [log_path, "a"],
        close_others: true,
        pgroup: true
      )
      Process.detach(pid)
      Clacky::Logger.info("[BrowserManager] MCP daemon spawned (pid=#{pid})")
    end

    # Build the chrome-devtools-mcp command (identical to the previous direct-spawn version).
    def build_chrome_mcp_command(detected)
      args = %w[
        --experimentalStructuredContent
        --experimental-page-id-routing
        --experimentalVision
      ]
      case detected[:mode]
      when :ws_endpoint
        ["chrome-devtools-mcp", *args, "--wsEndpoint", detected[:value]]
      else
        raise "Unknown detection mode: #{detected[:mode]}"
      end
    end

    # Poll until the daemon socket starts responding, up to DAEMON_STARTUP_TIMEOUT.
    def wait_for_daemon!
      deadline = Time.now + DAEMON_STARTUP_TIMEOUT
      until Time.now >= deadline
        return if daemon_responding?
        sleep 0.2
      end
      raise "MCP daemon failed to start within #{DAEMON_STARTUP_TIMEOUT}s (check ~/.clacky/mcp-daemon.log)"
    end

    # Send one JSON-RPC request over the Unix socket, read one response line.
    def send_to_daemon(req, timeout:)
      Timeout.timeout(timeout) do
        sock = UNIXSocket.new(SOCKET_PATH)
        begin
          sock.puts(JSON.generate(req))
          line = sock.gets
          raise "MCP daemon closed connection" if line.nil?
          JSON.parse(line)
        ensure
          sock.close rescue nil
        end
      end
    rescue Timeout::Error
      raise "MCP daemon call timed out after #{timeout}s"
    end

    def pid_alive?
      return false unless File.exist?(PID_PATH)
      pid = File.read(PID_PATH).to_i
      return false if pid <= 0
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def kill_daemon!
      # Try graceful shutdown via socket first.
      if daemon_responding?
        begin
          req = { jsonrpc: "2.0", id: 0, method: "daemon.shutdown" }
          send_to_daemon(req, timeout: 3)
        rescue StandardError
        end
      end

      # If still running, send SIGTERM by pid.
      if File.exist?(PID_PATH)
        pid = File.read(PID_PATH).to_i
        if pid > 0
          begin
            Process.kill("TERM", pid)
            10.times { break unless pid_alive?; sleep 0.2 }
            Process.kill("KILL", pid) if pid_alive?
          rescue Errno::ESRCH
          end
        end
      end

      File.unlink(SOCKET_PATH) if File.exist?(SOCKET_PATH)
      File.unlink(PID_PATH) if File.exist?(PID_PATH)
    end

    def extract_text_content(result)
      Array(result["content"])
        .select { |b| b.is_a?(Hash) && b["type"] == "text" }
        .map { |b| b["text"].to_s }
        .join("\n")
    end
  end
end
