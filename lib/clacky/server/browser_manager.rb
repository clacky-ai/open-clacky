# frozen_string_literal: true

require "yaml"
require "shellwords"
require "open3"
require "tmpdir"
require "fileutils"
require "net/http"
require "json"

module Clacky
  # BrowserManager owns the chrome-devtools-mcp daemon lifecycle.
  #
  # It mirrors the ChannelManager pattern:
  #   - start   → read browser.yml; if enabled, pre-warm the MCP daemon
  #   - stop    → kill the daemon
  #   - reload  → stop + re-read yml + start (called after browser-setup writes yml)
  #   - status  → { enabled: bool, daemon_running: bool, chrome_version: String|nil }
  #   - toggle  → flip enabled in browser.yml and reload
  #
  # browser.yml schema:
  #   enabled: true/false   — whether the browser tool is active
  #   chrome_version: "146" — detected Chrome version (set by browser-setup skill)
  #   configured_at: date   — when setup was last run
  #
  # Liveness check strategy:
  #   process_alive? sends an MCP `ping` (standard in MCP spec 2024-11-05) and
  #   waits up to 3s for a response.  If the ping succeeds the daemon is healthy.
  #   If it times out or raises an IO error the daemon is truly dead — kill it so
  #   ensure_process! will spawn a fresh one on the next call.
  #
  #   Chrome connection problems (e.g. Chrome closed) surface only during the
  #   actual mcp_call and are reported back to the caller; they do NOT trigger a
  #   daemon restart.
  #
  # Browser tool (browser.rb) delegates daemon access here instead of using
  # class-level @@mcp_process variables directly.  BrowserManager holds the
  # single mutable state; the mutex lives here too.
  class BrowserManager
    BROWSER_CONFIG_PATH = File.expand_path("~/.clacky/browser.yml").freeze

    class << self
      def instance
        @instance ||= new
      end
    end

    def initialize
      @process = nil   # { stdin:, stdout:, pid:, wait_thr: }
      @mutex   = Mutex.new
      @call_id = 2     # 1 reserved for MCP initialize handshake
      @config  = {}    # last successfully read browser.yml content
    end

    # ---------------------------------------------------------------------------
    # Lifecycle
    # ---------------------------------------------------------------------------

    # Start the daemon if browser.yml marks the browser as enabled.
    # Non-blocking — returns immediately (daemon spawn takes ~200ms in background).
    def start
      cfg = load_config
      unless cfg["enabled"] == true
        Clacky::Logger.info("[BrowserManager] Not enabled — skipping daemon start")
        return
      end

      @config = cfg
      Clacky::Logger.info("[BrowserManager] Browser enabled, pre-warming MCP daemon...")
      Thread.new do
        Thread.current.name = "browser-manager-start"
        @mutex.synchronize { ensure_process! }
      rescue Clacky::BrowserNotReachableError => e
        # Expected: Chrome not running yet — will start lazily on first use
        Clacky::Logger.debug("[BrowserManager] Skipping pre-warm: Chrome not running")
      rescue StandardError => e
        # Unexpected error (handshake failure, port conflict, etc.)
        msg = e.message.to_s.lines.first&.strip || e.message.to_s
        Clacky::Logger.warn("[BrowserManager] Pre-warm failed: #{msg}")
      end
    end

    # Stop and clean up the daemon.
    def stop
      @mutex.synchronize { kill_process! }
      Clacky::Logger.info("[BrowserManager] Daemon stopped")
    end

    # Hot-reload: stop existing daemon, re-read yml, restart if enabled.
    # Called by HttpServer after browser-setup writes a new browser.yml.
    def reload
      Clacky::Logger.info("[BrowserManager] Reloading...")
      @mutex.synchronize { kill_process! }

      cfg = load_config
      @config = cfg

      if cfg["enabled"] == true
        Clacky::Logger.info("[BrowserManager] Browser enabled, restarting daemon")
        Thread.new do
          Thread.current.name = "browser-manager-reload"
          @mutex.synchronize { ensure_process! }
        rescue Clacky::BrowserNotReachableError => e
          # Expected: Chrome not running yet — will start lazily on first use
          Clacky::Logger.debug("[BrowserManager] Skipping reload start: Chrome not running")
        rescue StandardError => e
          # Unexpected error (handshake failure, port conflict, etc.)
          msg = e.message.to_s.lines.first&.strip || e.message.to_s
          Clacky::Logger.warn("[BrowserManager] Reload start failed: #{msg}")
        end
      else
        Clacky::Logger.info("[BrowserManager] Browser disabled after reload — daemon not started")
      end
    end

    # Returns a status hash with real daemon liveness.
    # Uses wait_thr.alive? for a lightweight check — no ping, no mutex needed.
    # @return [Hash] { enabled: bool, daemon_running: bool, chrome_version: String|nil }
    def status
      cfg     = load_config
      enabled = cfg["enabled"] == true
      running = @process && @process[:wait_thr]&.alive?
      {
        enabled:        enabled,
        daemon_running: !!running,
        chrome_version: cfg["chrome_version"]
      }
    end

    # Write browser.yml with the given config and reload the daemon.
    # Called by HttpServer POST /api/browser/configure.
    # @param chrome_version [String] detected Chrome major version
    # @param wsl_browser_mode [String, nil] "windows" or "linux" (WSL only)
    # @param chrome_port [Integer, nil] specific port for Chrome remote debugging
    # @param auto_launch [Boolean, nil] whether to auto-launch headless Chrome
    def configure(chrome_version:, wsl_browser_mode: nil, chrome_port: nil, auto_launch: nil)
      cfg = {
        "enabled"        => true,
        "browser"        => "chrome",
        "chrome_version" => chrome_version.to_s,
        "configured_at"  => Date.today.to_s
      }
      cfg["wsl_browser_mode"] = wsl_browser_mode if wsl_browser_mode && !wsl_browser_mode.empty?
      cfg["chrome_port"] = chrome_port.to_i if chrome_port && chrome_port.to_i > 0
      cfg["auto_launch"] = auto_launch if [true, false].include?(auto_launch)
      FileUtils.mkdir_p(File.dirname(BROWSER_CONFIG_PATH))
      File.write(BROWSER_CONFIG_PATH, cfg.to_yaml)
      reload
    end

    # Toggle the browser tool on/off by flipping `enabled` in browser.yml.
    # Raises if browser.yml doesn't exist (not yet set up).
    # @return [Boolean] new enabled state
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

    # Returns the configured WSL browser mode from browser.yml.
    # @return [String] "windows" (default) or "linux"
    def wsl_browser_mode
      cfg = load_config
      mode = cfg["wsl_browser_mode"].to_s.strip
      mode.empty? ? "windows" : mode
    end

    # Public config reader for BrowserDetector (avoids circular deps).
    # Returns the raw config hash from browser.yml.
    # @return [Hash]
    def load_config_for_detector
      load_config
    end

    # ---------------------------------------------------------------------------
    # MCP call interface — used by Browser tool
    # ---------------------------------------------------------------------------

    # Execute a chrome-devtools-mcp tool call. Ensures daemon is running first.
    # Thread-safe via @mutex.
    # @param tool_name  [String]
    # @param arguments  [Hash]
    # @return [Hash] parsed MCP result
    # @raise [RuntimeError] on timeout or protocol error
    # @raise [BrowserNotReachableError] when Chrome is not running
    def mcp_call(tool_name, arguments = {})
      call_resp = nil

      @mutex.synchronize do
        ensure_process!  # May raise BrowserNotReachableError

        call_id  = @call_id
        @call_id += 1

        msg = json_rpc("tools/call", { name: tool_name, arguments: arguments }, id: call_id)
        @process[:stdin].write(msg + "\n")
        @process[:stdin].flush

        call_resp = read_response(@process[:stdout], target_id: call_id,
                                  timeout: Clacky::Tools::Browser::MCP_CALL_TIMEOUT)

        unless call_resp
          raise "Chrome MCP tools/call '#{tool_name}' timed out after #{Clacky::Tools::Browser::MCP_CALL_TIMEOUT}s"
        end

        if call_resp["error"]
          err = call_resp["error"]
          raise "Chrome MCP error: #{err.is_a?(Hash) ? err["message"] : err}"
        end

        result = call_resp["result"] || {}

        if result["isError"]
          text = extract_text_content(result)
          raise text.empty? ? "Chrome MCP tool '#{tool_name}' failed" : text
        end

        result
      end
    rescue RuntimeError => e
      # If Chrome disconnected but MCP daemon is still alive, kill the daemon
      # and auto-launch Chrome so the NEXT browser call can recover seamlessly.
      if chrome_connection_error?(e.message)
        Clacky::Logger.info("[BrowserManager] Chrome connection lost, cleaning up...")
        @mutex.synchronize do
          kill_process!
          if auto_launch_enabled?
            Clacky::Logger.info("[BrowserManager] Auto-launching Chrome for recovery...")
            auto_launch_chrome
          end
        end
      end
      raise
    rescue Clacky::BrowserNotReachableError => e
      # Return friendly error for AI to guide user
      raise Clacky::AgentError, e.message
    end

    # ---------------------------------------------------------------------------
    # Private
    # ---------------------------------------------------------------------------

    def load_config
      return {} unless File.exist?(BROWSER_CONFIG_PATH)
      YAMLCompat.safe_load(File.read(BROWSER_CONFIG_PATH), permitted_classes: [Date, Time, Symbol]) || {}
    rescue StandardError => e
      Clacky::Logger.warn("[BrowserManager] Failed to read browser.yml: #{e.message}")
      {}
    end

    # Must be called inside @mutex
    def ensure_process!
      return if process_alive?

      # ⭐️ Critical: Verify Chrome is reachable BEFORE starting MCP daemon
      detected = Clacky::Utils::BrowserDetector.detect

      if detected[:status] == :not_found
        # Try auto-launching Chrome before giving up
        if auto_launch_enabled?
          Clacky::Logger.info("[BrowserManager] Chrome not found, attempting auto-launch...")
          launched = auto_launch_chrome
          if launched.is_a?(Hash)
            Clacky::Logger.info("[BrowserManager] Auto-launch succeeded, using endpoint directly")
            detected = launched.merge(status: :ok)
          end
        end
      end

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

      # Build command with verified detection result
      cmd = build_mcp_command(detected)
      Clacky::Logger.info("[BrowserManager] Starting MCP daemon: #{cmd.join(' ')}")

      # Wrap in a shell that manually sources rc files (.zshrc/.bashrc) so
      # mise / rbenv / asdf activate and `chrome-devtools-mcp` (a node
      # binary installed under mise) is on PATH — otherwise the server,
      # when launched by launchd / a desktop icon with a minimal PATH,
      # cannot find node.
      #
      # LoginShell.login_shell_command builds argv like:
      #   /bin/zsh -c "{ . ~/.zshrc; ... } 1>&2; exec chrome-devtools-mcp ..."
      #
      # The `1>&2` sends rc-time output (banners, mise warnings) to stderr,
      # keeping the child's stdout 100% clean for JSON-RPC. `exec` then
      # replaces the shell process with the MCP daemon itself, so the pid
      # / signals / waitpid we hold point at the real target.
      inner   = cmd.map { |a| shell_escape(a) }.join(" ")
      wrapped = Clacky::Utils::LoginShell.login_shell_command(inner)

      # close_others: true prevents inheriting the server's listening socket (port 7070).
      # The MCP daemon is an independent external process and should not hold server fds.
      stdin, stdout, stderr_io, wait_thr = Open3.popen3(*wrapped, close_others: true)
      Thread.new { stderr_io.read rescue nil }

      # MCP handshake
      init_msg = json_rpc("initialize", {
        protocolVersion: "2024-11-05",
        capabilities:    {},
        clientInfo:      { name: "clacky", version: "1.0" }
      }, id: 1)

      notify_msg = JSON.generate({
        jsonrpc: "2.0",
        method:  "notifications/initialized",
        params:  {}
      })

      Clacky::Logger.debug("[BrowserManager] Sending MCP initialize...")
      stdin.write(init_msg + "\n")
      stdin.flush

      init_resp = read_response(stdout, target_id: 1,
                                timeout: Clacky::Tools::Browser::MCP_HANDSHAKE_TIMEOUT)
      unless init_resp
        Clacky::Logger.error("[BrowserManager] MCP initialize handshake timed out after #{Clacky::Tools::Browser::MCP_HANDSHAKE_TIMEOUT}s")
        Process.kill("TERM", wait_thr.pid) rescue nil
        raise "Chrome MCP initialize handshake timed out"
      end

      Clacky::Logger.debug("[BrowserManager] MCP initialize successful, sending initialized notification...")
      stdin.write(notify_msg + "\n")
      stdin.flush

      @process = { stdin: stdin, stdout: stdout, pid: wait_thr.pid, wait_thr: wait_thr }
      @call_id = 2
      Clacky::Logger.info("[BrowserManager] MCP daemon started successfully (pid=#{wait_thr.pid})")
    end

    # ---------------------------------------------------------------------------
    # Auto-launch Chrome (headless)
    # ---------------------------------------------------------------------------

    # Check if auto-launch is enabled in browser.yml.
    # Defaults to true on Linux/WSL-linux mode (where headless Chrome is available).
    # @return [Boolean]
    def auto_launch_enabled?
      cfg = load_config
      return cfg["auto_launch"] == true if cfg.key?("auto_launch")

      # Default: enable auto-launch on Linux-based environments
      os = Clacky::Utils::EnvironmentDetector.os_type
      os == :linux || os == :wsl
    end

    # Attempt to auto-launch headless Chrome for remote debugging.
    # Checks for existing Chrome instances first to avoid duplicates.
    # Finds Chrome binary, picks a free port, launches, and waits for readiness.
    # @return [Hash, false] detector-compatible hash on success, false on failure
    def auto_launch_chrome
      # First: check if Chrome is already running with remote debugging
      existing = find_existing_chrome
      if existing
        Clacky::Logger.info("[BrowserManager] Found existing Chrome on port #{existing[:port]}, reusing")
        return { mode: :ws_endpoint, value: existing[:ws] }
      end

      chrome_bin = find_chrome_binary
      unless chrome_bin
        Clacky::Logger.warn("[BrowserManager] Cannot auto-launch: no Chrome binary found")
        return false
      end

      port = resolve_chrome_port
      Clacky::Logger.info("[BrowserManager] Auto-launching Chrome: #{chrome_bin} on port #{port}")

      # Kill any previously spawned Chrome before launching new one
      kill_spawned_chrome!

      pid = spawn_chrome(chrome_bin, port)
      unless pid
        Clacky::Logger.warn("[BrowserManager] Failed to spawn Chrome")
        return false
      end

      @chrome_pid = pid
      Clacky::Logger.info("[BrowserManager] Chrome spawned (pid=#{pid}), waiting for readiness...")
      ready = wait_for_chrome(port, timeout: 10)
      unless ready
        Clacky::Logger.warn("[BrowserManager] Chrome did not become ready within timeout")
        kill_spawned_chrome!
        return false
      end

      Clacky::Logger.info("[BrowserManager] Chrome is ready on port #{port}")

      # Fetch WebSocket endpoint directly from the known port
      ws = Clacky::Utils::BrowserDetector.fetch_ws_endpoint(port)
      unless ws
        Clacky::Logger.warn("[BrowserManager] Chrome is running but could not fetch WebSocket URL")
        kill_spawned_chrome!
        return false
      end

      Clacky::Logger.info("[BrowserManager] Auto-launch complete: #{ws}")

      # Persist the auto-launched port so BrowserDetector can find it on subsequent calls.
      persist_auto_launch_port(port)

      { mode: :ws_endpoint, value: ws }
    rescue StandardError => e
      Clacky::Logger.warn("[BrowserManager] Auto-launch failed: #{e.message}")
      false
    end

    # Scan configured ports for an existing Chrome instance with remote debugging.
    # @return [Hash, nil] { port: Integer, ws: String } or nil
    def find_existing_chrome
      require "net/http"
      require "json"

      ports = Clacky::Utils::BrowserDetector.load_scan_ports
      ports.each do |port|
        begin
          uri  = URI("http://127.0.0.1:#{port}/json/version")
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 0.5
          http.read_timeout = 0.5
          resp = http.get(uri.request_uri)
          next unless resp.code.to_i == 200

          data = JSON.parse(resp.body)
          ws = data["webSocketDebuggerUrl"]
          next unless ws && !ws.empty?

          Clacky::Logger.debug("[BrowserManager] Existing Chrome found on port #{port}: #{ws}")
          return { port: port, ws: ws }
        rescue StandardError
          next
        end
      end
      nil
    end

    # Persist the auto-launched Chrome port to browser.yml so BrowserDetector
    # can find it on subsequent ensure_process! calls, preventing duplicate spawns.
    def persist_auto_launch_port(port)
      cfg = load_config
      cfg["chrome_port"] = port.to_i
      FileUtils.mkdir_p(File.dirname(BROWSER_CONFIG_PATH))
      File.write(BROWSER_CONFIG_PATH, cfg.to_yaml)
      Clacky::Logger.debug("[BrowserManager] Persisted auto-launch port #{port} to browser.yml")
    rescue StandardError => e
      Clacky::Logger.warn("[BrowserManager] Failed to persist auto-launch port: #{e.message}")
    end

    # Kill the Chrome process that we spawned (if any).
    def kill_spawned_chrome!
      if @chrome_pid
        Clacky::Logger.info("[BrowserManager] Killing spawned Chrome (pid=#{@chrome_pid})")
        Process.kill("TERM", @chrome_pid) rescue nil
        Process.wait(@chrome_pid, Process::WNOHANG) rescue nil
        @chrome_pid = nil
      end
      # Also clean up temp user-data-dir
      if @chrome_user_data_dir && Dir.exist?(@chrome_user_data_dir)
        FileUtils.rm_rf(@chrome_user_data_dir) rescue nil
        @chrome_user_data_dir = nil
      end
    end

    # Find the Chrome/Chromium binary on the system.
    # @return [String, nil] path to binary
    def find_chrome_binary
      candidates = %w[
        google-chrome-stable
        google-chrome
        chromium-browser
        chromium
        /opt/google/chrome/chrome
        /usr/bin/google-chrome-stable
        /usr/bin/google-chrome
      ]

      candidates.each do |bin|
        path = which_cmd?(bin)
        return path if path
      end

      nil
    end

    # Resolve which port Chrome should use.
    # Uses chrome_port from browser.yml if configured, otherwise finds a free port.
    # @return [Integer]
    def resolve_chrome_port
      cfg = load_config
      configured = cfg["chrome_port"]
      if configured && configured.to_i > 0
        port = configured.to_i
        unless port_free?(port)
          Clacky::Logger.warn("[BrowserManager] Configured port #{port} is in use, falling back to auto-select")
          return find_free_port
        end
        return port
      end
      find_free_port
    end

    # Find a free TCP port for Chrome remote debugging.
    # @return [Integer]
    def find_free_port
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      port
    rescue StandardError
      9223  # fallback
    end

    # Check if a port is free on localhost.
    # @param port [Integer]
    # @return [Boolean]
    def port_free?(port)
      TCPServer.new("127.0.0.1", port).close
      true
    rescue Errno::EADDRINUSE
      false
    end

    # Spawn headless Chrome with remote debugging enabled.
    # @param chrome_bin [String]
    # @param port [Integer]
    # @return [Integer, nil] pid
    def spawn_chrome(chrome_bin, port)
      user_data_dir = Dir.mktmpdir("clacky-chrome-")
      args = [
        chrome_bin,
        "--headless=new",
        "--remote-debugging-port=#{port}",
        "--no-sandbox",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-background-networking",
        "--disable-sync",
        "--user-data-dir=#{user_data_dir}",
      ]

      Clacky::Logger.debug("[BrowserManager] Spawning: #{args.join(' ')}")
      pid = Process.spawn(*args, pgroup: true, [:out, :err] => "/dev/null")
      # Store user_data_dir so it can be cleaned up later
      @chrome_user_data_dir = user_data_dir
      pid
    rescue StandardError => e
      Clacky::Logger.warn("[BrowserManager] spawn_chrome error: #{e.message}")
      nil
    end

    # Wait for Chrome's devtools HTTP endpoint to become available.
    # @param port [Integer]
    # @param timeout [Integer] seconds
    # @return [Boolean]
    def wait_for_chrome(port, timeout: 10)
      require "net/http"
      require "json"

      uri = URI("http://127.0.0.1:#{port}/json/version")
      deadline = Time.now + timeout

      while Time.now < deadline
        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 1
          http.read_timeout = 1
          response = http.get(uri.request_uri)
          return true if response.code.to_i == 200
        rescue StandardError
          # Chrome not ready yet
        end
        sleep 0.5
      end

      false
    end

    # Check if a command is available on PATH.
    # @param cmd [String]
    # @return [String, nil] full path or nil
    def which_cmd?(cmd)
      # If it's already an absolute path and executable
      return cmd if cmd.start_with?("/") && File.executable?(cmd)

      ENV["PATH"].split(File::PATH_SEPARATOR).each do |dir|
        full = File.join(dir, cmd)
        return full if File.executable?(full)
      end
      nil
    end

    # ---------------------------------------------------------------------------
    # Build MCP command
    # ---------------------------------------------------------------------------
    # Always uses the detected browser endpoint (no --autoConnect fallback).
    # @param detected [Hash] { mode: :ws_endpoint, value: String } from BrowserDetector
    # @return [Array<String>] command array
    def build_mcp_command(detected)
      args = chrome_mcp_feature_flags
      
      case detected[:mode]
      when :ws_endpoint
        Clacky::Logger.info("[BrowserManager] Using ws_endpoint mode: #{detected[:value]}")
        ["chrome-devtools-mcp", *args, "--wsEndpoint", detected[:value]]
      else
        raise "Unknown detection mode: #{detected[:mode]}"
      end
    end

    # Shell-escape a single argv token for safe interpolation into a `-c` string.
    def shell_escape(token)
      Shellwords.escape(token.to_s)
    end

    # Feature flags for chrome-devtools-mcp
    def chrome_mcp_feature_flags
      %w[
        --experimentalStructuredContent
        --experimental-page-id-routing
        --experimentalVision
      ]
    end

    # Must be called inside @mutex.
    # Uses wait_thr.alive? as the primary liveness check — fast and reliable.
    # Only falls back to an MCP ping if the thread is alive but we want to
    # verify the protocol layer is responsive (currently skipped for simplicity).
    # Kills the process only when the OS thread confirms it has actually exited.
    def process_alive?
      return false if @process.nil?

      @process[:wait_thr]&.alive? == true
    end

    # Must be called inside @mutex.
    # Clears @process immediately so other threads see it as gone, then
    # closes IO handles and sends TERM. Uses wait_thr.join(2) in a background
    # thread to reap the child and avoid zombie processes; escalates to KILL
    # if the process doesn't exit within the grace period.
    def kill_process!
      ps = @process
      return unless ps

      @process = nil  # Clear first — prevents other threads from re-entering

      ps[:stdin].close  rescue nil
      ps[:stdout].close rescue nil
      Process.kill("TERM", ps[:pid]) rescue nil

      # Reap the child process asynchronously to avoid zombies
      Thread.new do
        Thread.current.name = "browser-manager-reap"
        unless ps[:wait_thr].join(1)
          Process.kill("KILL", ps[:pid]) rescue nil
        end
      rescue StandardError
        nil
      end

      # Kill the Chrome process we spawned (if any) to prevent orphans
      kill_spawned_chrome!

      Clacky::Logger.info("[BrowserManager] MCP daemon killed (pid=#{ps[:pid]})")
    end

    def json_rpc(method, params, id:)
      JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params })
    end

    def read_response(io, target_id:, timeout: 10)
      Timeout.timeout(timeout) do
        loop do
          line = io.gets
          break if line.nil?
          line = line.strip
          next if line.empty?
          begin
            msg = JSON.parse(line)
            return msg if msg.is_a?(Hash) && msg["id"] == target_id
          rescue JSON::ParserError
            next
          end
        end
        nil
      end
    rescue Timeout::Error
      nil
    end

    def extract_text_content(result)
      Array(result["content"])
        .select { |b| b.is_a?(Hash) && b["type"] == "text" }
        .map { |b| b["text"].to_s }
        .join("\n")
    end

    # Detect Chrome connectivity errors from MCP error messages.
    # Returns true when the error indicates Chrome is unreachable
    # (e.g. Chrome process died, port closed, connection refused).
    def chrome_connection_error?(msg)
      return false if msg.nil? || msg.empty?

      msg.include?("Could not connect to Chrome") ||
        msg.include?("ECONNREFUSED") ||
        msg.include?("connect ECONNREFUSED") ||
        msg.include?("Chrome is not reachable") ||
        msg.include?("not running")
    end
  end
end
