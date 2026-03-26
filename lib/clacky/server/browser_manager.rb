# frozen_string_literal: true

require "yaml"

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
      rescue StandardError => e
        Clacky::Logger.warn("[BrowserManager] Pre-warm failed: #{e.message}")
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
        rescue StandardError => e
          Clacky::Logger.warn("[BrowserManager] Reload start failed: #{e.message}")
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

    # ---------------------------------------------------------------------------
    # MCP call interface — used by Browser tool
    # ---------------------------------------------------------------------------

    # Execute a chrome-devtools-mcp tool call. Ensures daemon is running first.
    # Thread-safe via @mutex.
    # @param tool_name  [String]
    # @param arguments  [Hash]
    # @return [Hash] parsed MCP result
    # @raise [RuntimeError] on timeout or protocol error
    def mcp_call(tool_name, arguments = {})
      call_resp = nil

      @mutex.synchronize do
        ensure_process!

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
    end

    # ---------------------------------------------------------------------------
    # Private
    # ---------------------------------------------------------------------------
    private

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

      cmd = Clacky::Tools::Browser.build_mcp_command
      stdin, stdout, stderr_io, wait_thr = Open3.popen3(*cmd)
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

      stdin.write(init_msg + "\n")
      stdin.flush

      init_resp = read_response(stdout, target_id: 1,
                                timeout: Clacky::Tools::Browser::MCP_HANDSHAKE_TIMEOUT)
      unless init_resp
        Process.kill("TERM", wait_thr.pid) rescue nil
        raise "Chrome MCP initialize handshake timed out"
      end

      stdin.write(notify_msg + "\n")
      stdin.flush

      @process = { stdin: stdin, stdout: stdout, pid: wait_thr.pid, wait_thr: wait_thr }
      @call_id = 2
      Clacky::Logger.info("[BrowserManager] MCP daemon started (pid=#{wait_thr.pid})")
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
  end
end
