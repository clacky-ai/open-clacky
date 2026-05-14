#!/usr/bin/env ruby
# frozen_string_literal: true

# MCP Daemon — long-lived Ruby process that owns chrome-devtools-mcp stdio and
# exposes it via a Unix socket so multiple Clacky processes (including across
# restarts) can share the same daemon and avoid Chrome re-authorization.
#
# Lifecycle:
#   - Clacky's BrowserManager spawns this script as a detached process.
#   - This daemon spawns chrome-devtools-mcp as a subprocess and holds its stdin/stdout.
#   - It listens on ~/.clacky/mcp-daemon.sock.
#   - Each client sends one or more JSON-RPC requests (one per line); daemon
#     forwards to chrome-devtools-mcp and writes the matching response back.
#   - The chrome-devtools-mcp stdio protocol is single-client; daemon serializes
#     concurrent client requests with a mutex.
#   - Daemon auto-exits after IDLE_TIMEOUT seconds with no client activity.
#
# Wire protocol (between Clacky and daemon):
#   Client → daemon: one JSON-RPC line (utf-8) followed by '\n'
#   Daemon → client: matching JSON-RPC response line (utf-8) followed by '\n'
#   Special methods (handled by daemon, not forwarded):
#     "daemon.ping"     → { "id": N, "result": { "ok": true } }
#     "daemon.shutdown" → daemon exits after responding

require "json"
require "socket"
require "fileutils"
require "open3"
require "timeout"
require "logger"

module Clacky
  class McpDaemon
    SOCKET_PATH    = File.expand_path("~/.clacky/mcp-daemon.sock").freeze
    PID_PATH       = File.expand_path("~/.clacky/mcp-daemon.pid").freeze
    ENDPOINT_PATH  = File.expand_path("~/.clacky/mcp-daemon.endpoint").freeze
    LOG_PATH       = File.expand_path("~/.clacky/mcp-daemon.log").freeze
    IDLE_TIMEOUT   = 3600 # exit after 1h of no traffic
    READ_TIMEOUT   = 90   # max wait for chrome-devtools-mcp to answer a single call
    HANDSHAKE_TIMEOUT = 15

    def self.run(argv)
      cmd = argv.dup
      raise ArgumentError, "usage: mcp_daemon.rb -- chrome-devtools-mcp [args...]" if cmd.empty?
      new(cmd).run
    end

    def initialize(chrome_mcp_cmd)
      @chrome_mcp_cmd = chrome_mcp_cmd
      @logger = Logger.new(LOG_PATH, 1, 1_000_000)
      @logger.level = Logger::INFO
      @logger.formatter = proc { |sev, time, _prog, msg| "[#{time.strftime('%H:%M:%S')}] #{sev} #{msg}\n" }

      @stdin = nil
      @stdout = nil
      @wait_thr = nil
      @write_mutex = Mutex.new
      @last_activity = Time.now
    end

    def run
      write_pid
      write_endpoint
      install_signal_handlers
      start_chrome_mcp!
      start_idle_watcher
      serve!
    rescue => e
      @logger.error("fatal: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
      cleanup
      exit 1
    end

    private

    def write_pid
      FileUtils.mkdir_p(File.dirname(PID_PATH))
      File.write(PID_PATH, Process.pid.to_s)
    end

    def write_endpoint
      idx = @chrome_mcp_cmd.index("--wsEndpoint")
      endpoint = idx ? @chrome_mcp_cmd[idx + 1].to_s : ""
      File.write(ENDPOINT_PATH, endpoint)
    end

    def install_signal_handlers
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          @logger.info("received SIG#{sig}, shutting down")
          cleanup
          exit 0
        end
      end
    end

    def start_chrome_mcp!
      @logger.info("starting chrome-devtools-mcp: #{@chrome_mcp_cmd.inspect}")
      @stdin, @stdout, err_io, @wait_thr = Open3.popen3(*@chrome_mcp_cmd, close_others: true)
      @stdin.sync = true

      Thread.new do
        Thread.current.name = "chrome-mcp-stderr"
        err_io.each_line { |l| @logger.warn("chrome-mcp stderr: #{l.chomp}") }
      rescue
      end

      # Exit the daemon if chrome-devtools-mcp dies so the next BrowserManager
      # call spawns a fresh one (Chrome may have closed, Chrome version changed,
      # etc.). Without this the daemon would keep responding to ping but every
      # tool call would EPIPE.
      Thread.new do
        Thread.current.name = "chrome-mcp-watchdog"
        @wait_thr.value
        @logger.warn("chrome-devtools-mcp exited (status=#{@wait_thr.value.exitstatus}); shutting down daemon")
        cleanup
        exit 0
      end

      perform_mcp_handshake!
      @logger.info("chrome-devtools-mcp ready (pid=#{@wait_thr.pid})")
    end

    def perform_mcp_handshake!
      init_msg = JSON.generate(
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "clacky-mcp-daemon", version: "1.0" }
        }
      )
      @stdin.puts(init_msg)

      resp = read_response_blocking(target_id: 1, timeout: HANDSHAKE_TIMEOUT)
      raise "MCP initialize handshake timed out" unless resp
      raise "MCP initialize error: #{resp['error']}" if resp["error"]

      notify_msg = JSON.generate(jsonrpc: "2.0", method: "notifications/initialized", params: {})
      @stdin.puts(notify_msg)
    end

    def read_response_blocking(target_id:, timeout:)
      Timeout.timeout(timeout) do
        loop do
          line = @stdout.gets
          return nil if line.nil?
          line = line.strip
          next if line.empty?
          begin
            msg = JSON.parse(line)
            return msg if msg.is_a?(Hash) && msg["id"] == target_id
          rescue JSON::ParserError
            next
          end
        end
      end
    rescue Timeout::Error
      nil
    end

    def start_idle_watcher
      Thread.new do
        Thread.current.name = "idle-watcher"
        loop do
          sleep 60
          idle = Time.now - @last_activity
          if idle > IDLE_TIMEOUT
            @logger.info("idle for #{idle.to_i}s, exiting")
            cleanup
            exit 0
          end
        end
      end
    end

    def serve!
      FileUtils.mkdir_p(File.dirname(SOCKET_PATH))
      File.unlink(SOCKET_PATH) if File.exist?(SOCKET_PATH)
      server = UNIXServer.new(SOCKET_PATH)
      File.chmod(0o600, SOCKET_PATH)
      @logger.info("listening on #{SOCKET_PATH}")

      loop do
        client = server.accept
        Thread.new(client) { |c| handle_client(c) }
      end
    end

    def handle_client(client)
      Thread.current.name = "client-#{client.object_id}"
      client.each_line do |line|
        line = line.strip
        next if line.empty?
        @last_activity = Time.now

        req =
          begin
            JSON.parse(line)
          rescue JSON::ParserError => e
            client.puts(JSON.generate(error: "invalid JSON: #{e.message}"))
            next
          end

        method = req["method"]
        if method == "daemon.ping"
          endpoint = File.exist?(ENDPOINT_PATH) ? File.read(ENDPOINT_PATH) : ""
          client.puts(JSON.generate(id: req["id"], result: { ok: true, pid: Process.pid, endpoint: endpoint }))
          next
        end
        if method == "daemon.shutdown"
          client.puts(JSON.generate(id: req["id"], result: { ok: true }))
          client.flush
          @logger.info("client requested shutdown")
          cleanup
          exit 0
        end

        resp = forward_to_chrome_mcp(req)
        client.puts(JSON.generate(resp))
      end
    rescue Errno::EPIPE, IOError
    ensure
      client.close rescue nil
    end

    def forward_to_chrome_mcp(req)
      id = req["id"]
      raise "request missing id" unless id

      @write_mutex.synchronize do
        @stdin.puts(JSON.generate(req))
        resp = read_response_blocking(target_id: id, timeout: READ_TIMEOUT)
        return { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32000, "message" => "chrome-devtools-mcp timed out after #{READ_TIMEOUT}s" } } unless resp
        resp
      end
    rescue => e
      @logger.error("forward error: #{e.class}: #{e.message}")
      { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32001, "message" => "#{e.class}: #{e.message}" } }
    end

    def cleanup
      File.unlink(SOCKET_PATH) if File.exist?(SOCKET_PATH)
      File.unlink(PID_PATH) if File.exist?(PID_PATH)
      File.unlink(ENDPOINT_PATH) if File.exist?(ENDPOINT_PATH)
      if @wait_thr && @wait_thr.alive?
        Process.kill("TERM", @wait_thr.pid) rescue nil
        Thread.new { @wait_thr.join(2) || Process.kill("KILL", @wait_thr.pid) rescue nil }
      end
    rescue
    end
  end
end

if $PROGRAM_NAME == __FILE__
  argv = ARGV.dup
  argv.shift if argv.first == "--"
  Clacky::McpDaemon.run(argv)
end
