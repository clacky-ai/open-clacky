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
    # While Clacky is running we send `daemon.keepalive` every 30 min so the
    # daemon's 24h idle timer never expires. This way the chrome-devtools-mcp
    # WebSocket session — and Chrome's remote-debugging authorization — sticks
    # around as long as any Clacky-server is alive (matters for IM-driven
    # agents where the user can't re-authorize Chrome from outside).
    KEEPALIVE_INTERVAL = 1_800

    class << self
      def instance
        @instance ||= new
      end
    end

    def initialize
      # @daemon_setup_mutex protects ensure_daemon!/kill_daemon!. Only contended
      # on cold start, respawn, or shutdown — the per-call hot path doesn't
      # serialize through it.
      # @call_id_mutex protects the @call_id counter. The actual RPC roundtrip
      # (send_to_daemon) runs lock-free; the daemon serializes via its own
      # @write_mutex when forwarding to chrome-devtools-mcp.
      # @keepalive_mutex protects @keepalive_thread (which we replace on reload).
      @daemon_setup_mutex = Mutex.new
      @call_id_mutex      = Mutex.new
      @keepalive_mutex    = Mutex.new
      @keepalive_thread   = nil
      @call_id            = 2
      @config             = {}
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
        @daemon_setup_mutex.synchronize { ensure_daemon! }
      rescue Clacky::BrowserNotReachableError
        Clacky::Logger.debug("[BrowserManager] Skipping pre-warm: Chrome not running")
      rescue StandardError => e
        msg = e.message.to_s.lines.first&.strip || e.message.to_s
        Clacky::Logger.warn("[BrowserManager] Pre-warm failed: #{msg}")
      end

      start_keepalive_thread!
    end

    # Detach from the daemon — no-op by design. Each mcp_call uses a one-shot
    # UNIX socket, so this process holds no connection state to release.
    # The daemon survives Clacky shutdown so the next startup can reuse the
    # existing Chrome remote-debugging authorization.
    def disconnect
      Clacky::Logger.info("[BrowserManager] Disconnect (daemon left running for restart reuse)")
    end

    public

    # Hard daemon teardown — only used when chrome config changes or on
    # `reload`. NOT called on Clacky shutdown.
    def terminate_daemon!
      stop_keepalive_thread!
      @daemon_setup_mutex.synchronize { kill_daemon! }
      Clacky::Logger.info("[BrowserManager] Daemon terminated")
    end

    def reload
      Clacky::Logger.info("[BrowserManager] Reloading...")
      stop_keepalive_thread!
      @daemon_setup_mutex.synchronize { kill_daemon! }

      cfg = load_config
      @config = cfg

      if cfg["enabled"] == true
        Clacky::Logger.info("[BrowserManager] Browser enabled, restarting daemon")
        Thread.new do
          Thread.current.name = "browser-manager-reload"
          @daemon_setup_mutex.synchronize { ensure_daemon! }
        rescue Clacky::BrowserNotReachableError
          Clacky::Logger.debug("[BrowserManager] Skipping reload start: Chrome not running")
        rescue StandardError => e
          msg = e.message.to_s.lines.first&.strip || e.message.to_s
          Clacky::Logger.warn("[BrowserManager] Reload start failed: #{msg}")
        end
        start_keepalive_thread!
      else
        Clacky::Logger.info("[BrowserManager] Browser disabled after reload — daemon not started")
      end
    end

    def status
      cfg     = load_config
      enabled = cfg["enabled"] == true
      {
        enabled:         enabled,
        daemon_running:  daemon_responding?,
        chrome_version:  cfg["chrome_version"],
        background_mode: background_mode?(cfg)
      }
    end

    # Whether the agent should operate the browser silently in the background
    # — i.e. NOT bring tabs to the front when selecting/opening pages.
    # Default: true (agent never steals focus from the user).
    # Override per-config via `background_mode: false` in browser.yml.
    def background_mode?(cfg = nil)
      cfg ||= load_config
      val = cfg["background_mode"]
      return true if val.nil?  # default ON
      val == true
    end

    def configure(chrome_version:)
      cfg = {
        "enabled"         => true,
        "browser"         => "chrome",
        "chrome_version"  => chrome_version.to_s,
        "background_mode" => true,
        "configured_at"   => Date.today.to_s
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
        @daemon_setup_mutex.synchronize { ensure_daemon! }

        call_id = @call_id_mutex.synchronize do
          id = @call_id
          @call_id += 1
          id
        end

        req = {
          jsonrpc: "2.0",
          id:      call_id,
          method:  "tools/call",
          params:  { name: tool_name, arguments: arguments }
        }

        # send_to_daemon runs lock-free; the daemon's @write_mutex serializes
        # the actual chrome-devtools-mcp forwarding.
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

    # Spawn (or replace) the per-Clacky-process keepalive thread. Fires
    # `daemon.keepalive` every KEEPALIVE_INTERVAL so the daemon's 24h idle
    # timer never trips while this Clacky is alive. Errors are swallowed —
    # if the daemon is briefly unreachable, the next tick will retry.
    private def start_keepalive_thread!
      @keepalive_mutex.synchronize do
        stop_keepalive_thread_locked!
        @keepalive_thread = Thread.new do
          Thread.current.name = "browser-manager-keepalive"
          loop do
            sleep KEEPALIVE_INTERVAL
            send_daemon_keepalive
          end
        end
      end
    end

    private def stop_keepalive_thread!
      @keepalive_mutex.synchronize { stop_keepalive_thread_locked! }
    end

    private def stop_keepalive_thread_locked!
      thr = @keepalive_thread
      return unless thr
      thr.kill if thr.alive?
      @keepalive_thread = nil
    end

    private def send_daemon_keepalive
      return unless File.exist?(SOCKET_PATH)
      req = { jsonrpc: "2.0", id: 0, method: "daemon.keepalive" }
      send_to_daemon(req, timeout: 2)
    rescue StandardError
      # Daemon may be down transiently; we'll try again next tick.
      nil
    end

    private def load_config
      return {} unless File.exist?(BROWSER_CONFIG_PATH)
      YAMLCompat.safe_load(File.read(BROWSER_CONFIG_PATH), permitted_classes: [Date, Time, Symbol]) || {}
    rescue StandardError => e
      Clacky::Logger.warn("[BrowserManager] Failed to read browser.yml: #{e.message}")
      {}
    end

    # Called inside @daemon_setup_mutex.
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

    SPAWN_LOG_MAX_BYTES = 1_000_000

    def spawn_daemon_locked!(detected)
      chrome_cmd = build_chrome_mcp_command(detected)
      log_path   = File.expand_path("~/.clacky/mcp-daemon.spawn.log")
      FileUtils.mkdir_p(File.dirname(log_path))
      rotate_log_if_oversized(log_path)

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

    # Roll spawn.log → spawn.log.1 when it grows past SPAWN_LOG_MAX_BYTES.
    # Only one historical copy is kept. spawn.log is append-only (spawn-time
    # rc-shell output, MCP startup banner, mise warnings) so a single rollover
    # is enough to bound disk use without losing recent debug context.
    def rotate_log_if_oversized(log_path)
      return unless File.exist?(log_path)
      return if File.size(log_path) < SPAWN_LOG_MAX_BYTES
      FileUtils.mv(log_path, "#{log_path}.1", force: true)
    rescue StandardError => e
      Clacky::Logger.warn("[BrowserManager] Failed to rotate spawn log: #{e.message}")
    end
  end
end
