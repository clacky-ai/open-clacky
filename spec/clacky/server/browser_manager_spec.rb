# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "clacky/server/browser_manager"
require "clacky/tools/browser"

RSpec.describe Clacky::BrowserManager do
  let(:manager) { described_class.new }

  let(:tmp_dir)     { Dir.mktmpdir }
  let(:config_path) { File.join(tmp_dir, "browser.yml") }
  let(:socket_path) { File.join(tmp_dir, "mcp-daemon.sock") }
  let(:pid_path)    { File.join(tmp_dir, "mcp-daemon.pid") }
  let(:lock_path)   { File.join(tmp_dir, "mcp-daemon.spawn.lock") }

  before do
    stub_const("Clacky::BrowserManager::BROWSER_CONFIG_PATH", config_path)
    stub_const("Clacky::BrowserManager::SOCKET_PATH",         socket_path)
    stub_const("Clacky::BrowserManager::PID_PATH",            pid_path)
    allow(File).to receive(:expand_path).and_call_original
    allow(File).to receive(:expand_path).with("~/.clacky/mcp-daemon.spawn.lock").and_return(lock_path)
    allow(File).to receive(:expand_path).with("~/.clacky/mcp-daemon.spawn.log").and_return(File.join(tmp_dir, "mcp-daemon.spawn.log"))
    allow(Clacky::Logger).to receive(:info)
    allow(Clacky::Logger).to receive(:warn)
    allow(Clacky::Logger).to receive(:debug)
  end

  after { FileUtils.rm_rf(tmp_dir) }

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def write_config(hash)
    File.write(config_path, hash.to_yaml)
  end

  def stub_daemon_responsive(endpoint: "")
    ping_result = { "result" => { "ok" => true, "endpoint" => endpoint } }
    allow(manager).to receive(:send_to_daemon) do |req, **|
      case req[:method]
      when "daemon.ping"     then ping_result
      when "daemon.shutdown" then { "result" => { "ok" => true } }
      else
        raise "unexpected send_to_daemon call in stub: #{req[:method]}"
      end
    end
    FileUtils.touch(socket_path)
  end

  def stub_daemon_unresponsive
    allow(manager).to receive(:send_to_daemon).and_raise(Errno::ECONNREFUSED)
  end

  # ---------------------------------------------------------------------------
  # .instance — singleton
  # ---------------------------------------------------------------------------
  describe ".instance" do
    it "returns the same object on repeated calls" do
      expect(described_class.instance).to be(described_class.instance)
    end

    it "is a BrowserManager" do
      expect(described_class.instance).to be_a(described_class)
    end
  end

  # ---------------------------------------------------------------------------
  # #start
  # ---------------------------------------------------------------------------
  describe "#start" do
    context "when browser.yml is missing" do
      it "does not start a daemon thread" do
        expect(Thread).not_to receive(:new)
        manager.start
      end
    end

    context "when enabled is missing or false" do
      before { write_config("enabled" => false) }

      it "does not start a daemon thread" do
        expect(Thread).not_to receive(:new)
        manager.start
      end
    end

    context "when enabled: true" do
      before { write_config("enabled" => true, "chrome_version" => "148") }

      it "spawns a background thread to pre-warm the daemon" do
        spawned = false
        allow(Thread).to receive(:new) { spawned = true; Thread.current }
        manager.start
        expect(spawned).to be true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #stop
  # ---------------------------------------------------------------------------
  describe "#stop" do
    it "is a no-op even when a daemon is running (daemon survives Clacky shutdown)" do
      stub_daemon_responsive
      expect(manager).not_to receive(:kill_daemon!)
      expect { manager.stop }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # #force_stop
  # ---------------------------------------------------------------------------
  describe "#force_stop" do
    it "kills the daemon under the mutex" do
      expect(manager).to receive(:kill_daemon!)
      manager.force_stop
    end
  end

  # ---------------------------------------------------------------------------
  # #reload
  # ---------------------------------------------------------------------------
  describe "#reload" do
    it "always kills any existing daemon first" do
      expect(manager).to receive(:kill_daemon!)
      manager.reload
    end

    context "when yml says enabled: true" do
      before { write_config("enabled" => true, "chrome_version" => "148") }

      it "spawns a restart thread" do
        allow(manager).to receive(:kill_daemon!)
        spawned = false
        allow(Thread).to receive(:new) { spawned = true; Thread.current }
        manager.reload
        expect(spawned).to be true
      end
    end

    context "when yml says enabled: false" do
      before { write_config("enabled" => false) }

      it "does not spawn a restart thread" do
        allow(manager).to receive(:kill_daemon!)
        expect(Thread).not_to receive(:new)
        manager.reload
      end
    end

    context "when yml does not exist" do
      it "does not spawn a restart thread" do
        allow(manager).to receive(:kill_daemon!)
        expect(Thread).not_to receive(:new)
        manager.reload
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #status
  # ---------------------------------------------------------------------------
  describe "#status" do
    context "when browser.yml is missing" do
      it "returns not enabled and daemon not running" do
        stub_daemon_unresponsive
        s = manager.status
        expect(s[:enabled]).to be false
        expect(s[:daemon_running]).to be false
        expect(s[:chrome_version]).to be_nil
      end
    end

    context "when enabled: true and chrome_version is set" do
      before { write_config("enabled" => true, "chrome_version" => "148") }

      it "reports enabled: true" do
        stub_daemon_unresponsive
        expect(manager.status[:enabled]).to be true
      end

      it "returns the chrome_version" do
        stub_daemon_unresponsive
        expect(manager.status[:chrome_version]).to eq("148")
      end

      it "reports daemon_running: false when daemon is unreachable" do
        stub_daemon_unresponsive
        expect(manager.status[:daemon_running]).to be false
      end

      it "reports daemon_running: true when daemon answers daemon.ping" do
        stub_daemon_responsive
        expect(manager.status[:daemon_running]).to be true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #daemon_responding?
  # ---------------------------------------------------------------------------
  describe "#daemon_responding? (private)" do
    it "returns false when the socket file is missing" do
      expect(manager.send(:daemon_responding?)).to be false
    end

    it "returns true when daemon.ping result includes ok: true" do
      stub_daemon_responsive
      expect(manager.send(:daemon_responding?)).to be true
    end

    it "returns false when daemon.ping result is missing ok" do
      FileUtils.touch(socket_path)
      allow(manager).to receive(:send_to_daemon).and_return({ "result" => {} })
      expect(!!manager.send(:daemon_responding?)).to be false
    end

    it "returns false when send_to_daemon raises" do
      FileUtils.touch(socket_path)
      allow(manager).to receive(:send_to_daemon).and_raise(Errno::ECONNREFUSED)
      expect(manager.send(:daemon_responding?)).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #daemon_endpoint
  # ---------------------------------------------------------------------------
  describe "#daemon_endpoint (private)" do
    it "returns empty string when socket file is missing" do
      expect(manager.send(:daemon_endpoint)).to eq("")
    end

    it "returns the endpoint advertised by daemon.ping" do
      stub_daemon_responsive(endpoint: "ws://127.0.0.1:9222/devtools/browser/abc")
      expect(manager.send(:daemon_endpoint)).to eq("ws://127.0.0.1:9222/devtools/browser/abc")
    end

    it "returns empty string when send_to_daemon raises" do
      FileUtils.touch(socket_path)
      allow(manager).to receive(:send_to_daemon).and_raise(StandardError)
      expect(manager.send(:daemon_endpoint)).to eq("")
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #kill_daemon!
  # ---------------------------------------------------------------------------
  describe "#kill_daemon! (private)" do
    it "is a no-op when no socket and no pid file exist" do
      expect { manager.send(:kill_daemon!) }.not_to raise_error
    end

    it "attempts graceful shutdown via daemon.shutdown when daemon is responsive" do
      stub_daemon_responsive
      expect(manager).to receive(:send_to_daemon).with(
        hash_including(method: "daemon.shutdown"), timeout: 3
      ).and_return({ "result" => { "ok" => true } })
      # Allow ping calls too
      allow(manager).to receive(:send_to_daemon).with(
        hash_including(method: "daemon.ping"), any_args
      ).and_return({ "result" => { "ok" => true } })
      manager.send(:kill_daemon!)
    end

    it "sends SIGTERM to the pid in PID_PATH when present" do
      File.write(pid_path, "12345")
      allow(manager).to receive(:daemon_responding?).and_return(false)
      allow(manager).to receive(:pid_alive?).and_return(true, false)
      expect(Process).to receive(:kill).with("TERM", 12_345)
      manager.send(:kill_daemon!)
    end

    it "removes socket and pid files after killing" do
      FileUtils.touch(socket_path)
      File.write(pid_path, "99999")
      allow(manager).to receive(:daemon_responding?).and_return(false)
      allow(manager).to receive(:pid_alive?).and_return(false)
      manager.send(:kill_daemon!)
      expect(File.exist?(socket_path)).to be false
      expect(File.exist?(pid_path)).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #ensure_daemon!
  # ---------------------------------------------------------------------------
  describe "#ensure_daemon! (private)" do
    it "raises BrowserNotReachableError when Chrome is not running" do
      allow(Clacky::Utils::BrowserDetector).to receive(:detect).and_return({ status: :not_found })

      expect { manager.send(:ensure_daemon!) }.to raise_error(
        Clacky::BrowserNotReachableError,
        /Chrome\/Edge is not running/
      )
    end

    it "does nothing if daemon is responding with the matching endpoint" do
      endpoint = "ws://127.0.0.1:9222/devtools/browser/test"
      allow(Clacky::Utils::BrowserDetector).to receive(:detect).and_return({
        status: :ok, mode: :ws_endpoint, value: endpoint
      })
      stub_daemon_responsive(endpoint: endpoint)

      expect(manager).not_to receive(:spawn_daemon!)
      manager.send(:ensure_daemon!)
    end

    it "respawns the daemon when the endpoint is stale" do
      endpoint = "ws://127.0.0.1:9222/devtools/browser/new"
      allow(Clacky::Utils::BrowserDetector).to receive(:detect).and_return({
        status: :ok, mode: :ws_endpoint, value: endpoint
      })
      stub_daemon_responsive(endpoint: "ws://127.0.0.1:9222/devtools/browser/old")

      expect(manager).to receive(:kill_daemon!)
      expect(manager).to receive(:spawn_daemon!)
      expect(manager).to receive(:wait_for_daemon!)
      manager.send(:ensure_daemon!)
    end

    it "spawns and waits when no daemon is running" do
      endpoint = "ws://127.0.0.1:9222/devtools/browser/test"
      allow(Clacky::Utils::BrowserDetector).to receive(:detect).and_return({
        status: :ok, mode: :ws_endpoint, value: endpoint
      })
      # No socket file, no daemon
      expect(manager).to receive(:spawn_daemon!)
      expect(manager).to receive(:wait_for_daemon!)
      manager.send(:ensure_daemon!)
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #send_to_daemon
  # ---------------------------------------------------------------------------
  describe "#send_to_daemon (private)" do
    it "writes a JSON line to the socket and parses the response line" do
      server = UNIXServer.new(socket_path)
      server_thread = Thread.new do
        client = server.accept
        line   = client.gets
        parsed = JSON.parse(line)
        client.puts(JSON.generate("jsonrpc" => "2.0", "id" => parsed["id"], "result" => { "echoed" => true }))
        client.close
      end

      result = manager.send(:send_to_daemon, { jsonrpc: "2.0", id: 7, method: "daemon.ping" }, timeout: 2)
      server_thread.join
      server.close

      expect(result["id"]).to eq(7)
      expect(result["result"]["echoed"]).to be true
    end

    it "raises a timeout error when no response arrives" do
      server = UNIXServer.new(socket_path)
      hang_thread = Thread.new { server.accept; sleep 3 }

      expect {
        manager.send(:send_to_daemon, { jsonrpc: "2.0", id: 7, method: "daemon.ping" }, timeout: 1)
      }.to raise_error(/timed out after 1s/)

      hang_thread.kill
      server.close
    end
  end

  # ---------------------------------------------------------------------------
  # #mcp_call
  # ---------------------------------------------------------------------------
  describe "#mcp_call" do
    before do
      allow(manager).to receive(:ensure_daemon!)
    end

    it "sends a tools/call message and returns the result" do
      received_req = nil
      allow(manager).to receive(:send_to_daemon) do |req, **|
        received_req = req
        { "jsonrpc" => "2.0", "id" => req[:id], "result" => { "structuredContent" => { "pages" => [] } } }
      end

      result = manager.mcp_call("list_pages", {})

      expect(result).to be_a(Hash)
      expect(received_req[:method]).to eq("tools/call")
      expect(received_req[:params][:name]).to eq("list_pages")
    end

    it "increments @call_id on each invocation" do
      id1 = manager.instance_variable_get(:@call_id)
      allow(manager).to receive(:send_to_daemon) do |req, **|
        { "jsonrpc" => "2.0", "id" => req[:id], "result" => {} }
      end

      manager.mcp_call("list_pages", {})
      expect(manager.instance_variable_get(:@call_id)).to eq(id1 + 1)

      manager.mcp_call("list_pages", {})
      expect(manager.instance_variable_get(:@call_id)).to eq(id1 + 2)
    end

    it "raises on JSON-RPC error response" do
      allow(manager).to receive(:send_to_daemon) do |req, **|
        { "jsonrpc" => "2.0", "id" => req[:id], "error" => { "message" => "some rpc error" } }
      end

      expect { manager.mcp_call("list_pages", {}) }.to raise_error(/some rpc error/)
    end

    it "raises when result has isError: true" do
      allow(manager).to receive(:send_to_daemon) do |req, **|
        {
          "jsonrpc" => "2.0", "id" => req[:id],
          "result" => {
            "isError" => true,
            "content" => [{ "type" => "text", "text" => "navigation failed" }]
          }
        }
      end

      expect { manager.mcp_call("navigate_page", { url: "bad" }) }.to raise_error(/navigation failed/)
    end

    it "retries once when the socket connection is refused, then re-raises" do
      attempts = 0
      allow(manager).to receive(:send_to_daemon) do
        attempts += 1
        raise Errno::ECONNREFUSED
      end

      expect { manager.mcp_call("list_pages", {}) }.to raise_error(Errno::ECONNREFUSED)
      expect(attempts).to eq(2)
    end

    it "wraps BrowserNotReachableError into Clacky::AgentError" do
      allow(manager).to receive(:ensure_daemon!).and_raise(
        Clacky::BrowserNotReachableError, "Chrome not running"
      )

      expect { manager.mcp_call("list_pages", {}) }.to raise_error(
        Clacky::AgentError, /Chrome not running/
      )
    end
  end

  # ---------------------------------------------------------------------------
  # background_mode?
  # ---------------------------------------------------------------------------
  describe "#background_mode?" do
    it "returns true when browser.yml is missing (default)" do
      expect(manager.background_mode?).to be true
    end

    it "returns true when background_mode is explicitly true" do
      write_config("enabled" => true, "background_mode" => true)
      expect(manager.background_mode?).to be true
    end

    it "returns false when background_mode is explicitly false" do
      write_config("enabled" => true, "background_mode" => false)
      expect(manager.background_mode?).to be false
    end

    it "returns true when background_mode key is absent (default)" do
      write_config("enabled" => true)
      expect(manager.background_mode?).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #load_config
  # ---------------------------------------------------------------------------
  describe "#load_config (private)" do
    it "returns {} when file does not exist" do
      expect(manager.send(:load_config)).to eq({})
    end

    it "returns parsed YAML when file exists" do
      write_config("enabled" => true, "chrome_version" => "148")
      cfg = manager.send(:load_config)
      expect(cfg["enabled"]).to be true
      expect(cfg["chrome_version"]).to eq("148")
    end

    it "returns {} when file is malformed" do
      File.write(config_path, ":\tinvalid:\n  yaml: [unclosed")
      expect(manager.send(:load_config)).to eq({})
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #build_chrome_mcp_command
  # ---------------------------------------------------------------------------
  describe "#build_chrome_mcp_command (private)" do
    it "builds the chrome-devtools-mcp argv with --wsEndpoint for :ws_endpoint detection" do
      cmd = manager.send(:build_chrome_mcp_command, {
        mode: :ws_endpoint, value: "ws://127.0.0.1:9222/devtools/browser/abc"
      })
      expect(cmd.first).to eq("chrome-devtools-mcp")
      expect(cmd).to include("--wsEndpoint", "ws://127.0.0.1:9222/devtools/browser/abc")
      expect(cmd).to include("--experimentalStructuredContent")
      expect(cmd).to include("--experimental-page-id-routing")
    end

    it "raises for unknown detection modes" do
      expect {
        manager.send(:build_chrome_mcp_command, { mode: :unknown })
      }.to raise_error(/Unknown detection mode/)
    end
  end
end
