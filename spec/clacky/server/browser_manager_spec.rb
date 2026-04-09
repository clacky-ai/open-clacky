# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require "clacky/server/browser_manager"
require "clacky/tools/browser"

RSpec.describe Clacky::BrowserManager do
  # Each test gets a fresh instance — avoids singleton state leaking between examples.
  let(:manager) { described_class.new }

  # Temp dir to isolate browser.yml reads/writes from the real ~/.clacky/browser.yml
  let(:tmp_dir)     { Dir.mktmpdir }
  let(:config_path) { File.join(tmp_dir, "browser.yml") }

  before do
    stub_const("Clacky::BrowserManager::BROWSER_CONFIG_PATH", config_path)
    allow(Clacky::Logger).to receive(:info)
    allow(Clacky::Logger).to receive(:warn)
  end

  after { FileUtils.rm_rf(tmp_dir) }

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def write_config(hash)
    File.write(config_path, hash.to_yaml)
  end

  # Inject a fake live daemon into the manager's @process ivar.
  # Stubs process_alive? to return true so callers don't need to pre-fill
  # responses in fake_stdout.
  def inject_process(responses = [])
    all_output   = responses.map { |r| r + "\n" }.join
    fake_stdin   = StringIO.new
    fake_stdout  = StringIO.new(all_output)
    fake_wait    = double("wait_thr", alive?: true, pid: 99_888)
    allow(fake_wait).to receive(:join).and_return(fake_wait)
    manager.instance_variable_set(:@process, {
      stdin:    fake_stdin,
      stdout:   fake_stdout,
      pid:      99_888,
      wait_thr: fake_wait
    })
    allow(manager).to receive(:process_alive?).and_return(true)
    [fake_stdin, fake_stdout]
  end

  def json_rpc_response(id:, result: nil, error: nil)
    msg = { "jsonrpc" => "2.0", "id" => id }
    result ? msg["result"] = result : msg["error"] = error
    JSON.generate(msg)
  end

  # ---------------------------------------------------------------------------
  # .instance — singleton
  # ---------------------------------------------------------------------------
  describe ".instance" do
    it "returns the same object on repeated calls" do
      a = described_class.instance
      b = described_class.instance
      expect(a).to be(b)
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

    context "when configured: false" do
      before { write_config("configured" => false) }

      it "does not start a daemon thread" do
        expect(Thread).not_to receive(:new)
        manager.start
      end
    end

    context "when enabled: true" do
      before { write_config("enabled" => true, "chrome_version" => "148") }

      it "spawns a background thread to pre-warm the daemon" do
        thread_spawned = false
        allow(Thread).to receive(:new) { thread_spawned = true; Thread.current }
        manager.start
        expect(thread_spawned).to be true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #stop
  # ---------------------------------------------------------------------------
  describe "#stop" do
    it "is a no-op when no daemon is running" do
      expect { manager.stop }.not_to raise_error
    end

    it "kills the daemon and clears @process" do
      inject_process
      manager.stop
      expect(manager.instance_variable_get(:@process)).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # #reload
  # ---------------------------------------------------------------------------
  describe "#reload" do
    it "stops any existing daemon" do
      inject_process
      write_config("configured" => false)
      manager.reload
      expect(manager.instance_variable_get(:@process)).to be_nil
    end

    context "when yml is now enabled: true" do
      before { write_config("enabled" => true, "chrome_version" => "148") }

      it "spawns a restart thread" do
        thread_spawned = false
        allow(Thread).to receive(:new) { thread_spawned = true; Thread.current }
        manager.reload
        expect(thread_spawned).to be true
      end
    end

    context "when yml is configured: false" do
      before { write_config("configured" => false) }

      it "does not spawn a thread" do
        expect(Thread).not_to receive(:new)
        manager.reload
      end
    end

    context "when yml does not exist" do
      it "does not spawn a thread" do
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
        s = manager.status
        expect(s[:enabled]).to be false
        expect(s[:daemon_running]).to be false
        expect(s[:chrome_version]).to be_nil
      end
    end

    context "when enabled: true and chrome_version set" do
      before { write_config("enabled" => true, "chrome_version" => "148") }

      it "reports enabled: true" do
        expect(manager.status[:enabled]).to be true
      end

      it "returns the chrome_version" do
        expect(manager.status[:chrome_version]).to eq("148")
      end

      it "reports daemon_running: false when no process" do
        expect(manager.status[:daemon_running]).to be false
      end

      it "reports daemon_running: true when process is alive" do
        inject_process
        expect(manager.status[:daemon_running]).to be true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #process_alive?
  # ---------------------------------------------------------------------------
  describe "#process_alive? (private)" do
    it "returns false when @process is nil" do
      expect(manager.send(:process_alive?)).to be false
    end

    it "returns false when wait_thr reports the process has exited" do
      fake_wait = double("wait_thr", alive?: false)
      manager.instance_variable_set(:@process, {
        stdin: StringIO.new, stdout: StringIO.new, pid: 99_999, wait_thr: fake_wait
      })
      expect(manager.send(:process_alive?)).to be false
    end

    it "returns false when wait_thr is nil (process not tracked)" do
      manager.instance_variable_set(:@process, {
        stdin: StringIO.new, stdout: StringIO.new, pid: 99_999, wait_thr: nil
      })
      expect(manager.send(:process_alive?)).to be false
    end

    it "returns true when wait_thr is alive and IO handles are open" do
      fake_wait = double("wait_thr", alive?: true)
      manager.instance_variable_set(:@process, {
        stdin: StringIO.new, stdout: StringIO.new, pid: 99_888, wait_thr: fake_wait
      })
      expect(manager.send(:process_alive?)).to be true
    end


  end

  # ---------------------------------------------------------------------------
  # Private: #kill_process!
  # ---------------------------------------------------------------------------
  describe "#kill_process! (private)" do
    it "is a no-op when @process is nil" do
      expect { manager.send(:kill_process!) }.not_to raise_error
    end

    it "clears @process after killing" do
      inject_process
      manager.send(:kill_process!)
      expect(manager.instance_variable_get(:@process)).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #ensure_process!
  # ---------------------------------------------------------------------------
  describe "#ensure_process! (private)" do
    it "does nothing if process is already alive" do
      inject_process
      expect(Open3).not_to receive(:popen3)
      manager.send(:ensure_process!)
      expect(manager.instance_variable_get(:@process)[:pid]).to eq(99_888)
    end

    it "starts a new daemon and completes the MCP handshake" do
      # Mock browser detection to return success
      allow(Clacky::Utils::BrowserDetector).to receive(:detect).and_return({
        status: :ok,
        mode: :ws_endpoint,
        value: "ws://127.0.0.1:9222/devtools/browser/test"
      })

      init_resp   = json_rpc_response(id: 1, result: { "protocolVersion" => "2024-11-05", "capabilities" => {} })
      fake_stdin  = StringIO.new
      fake_stdout = StringIO.new(init_resp + "\n")
      fake_stderr = StringIO.new
      fake_wait   = double("wait_thr", pid: 12_345)

      allow(Open3).to receive(:popen3).and_return([fake_stdin, fake_stdout, fake_stderr, fake_wait])

      manager.send(:ensure_process!)

      ps = manager.instance_variable_get(:@process)
      expect(ps).not_to be_nil
      expect(ps[:pid]).to eq(12_345)
      expect(fake_stdin.string).to include('"initialize"')
      expect(fake_stdin.string).to include('"notifications/initialized"')
    end

    it "raises when the initialize handshake times out" do
      # Mock browser detection to return success
      allow(Clacky::Utils::BrowserDetector).to receive(:detect).and_return({
        status: :ok,
        mode: :ws_endpoint,
        value: "ws://127.0.0.1:9222/devtools/browser/test"
      })

      fake_stdin  = StringIO.new
      fake_stderr = StringIO.new
      fake_wait   = double("wait_thr", pid: 12_346)

      allow(Open3).to receive(:popen3).and_return([fake_stdin, StringIO.new, fake_stderr, fake_wait])
      allow(Process).to receive(:kill).and_return(nil)
      allow(manager).to receive(:read_response).and_return(nil)

      expect { manager.send(:ensure_process!) }.to raise_error(/initialize handshake timed out/)
    end

    it "raises BrowserNotReachableError when browser is not found" do
      allow(Clacky::Utils::BrowserDetector).to receive(:detect).and_return({ status: :not_found })

      expect { manager.send(:ensure_process!) }.to raise_error(
        Clacky::BrowserNotReachableError,
        /Chrome\/Edge is not running/
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #json_rpc
  # ---------------------------------------------------------------------------
  describe "#json_rpc (private)" do
    it "builds a valid JSON-RPC 2.0 message" do
      msg    = manager.send(:json_rpc, "tools/call", { name: "list_pages" }, id: 42)
      parsed = JSON.parse(msg)
      expect(parsed["jsonrpc"]).to eq("2.0")
      expect(parsed["id"]).to eq(42)
      expect(parsed["method"]).to eq("tools/call")
      expect(parsed["params"]["name"]).to eq("list_pages")
    end
  end

  # ---------------------------------------------------------------------------
  # Private: #read_response
  # ---------------------------------------------------------------------------
  describe "#read_response (private)" do
    it "reads and returns the matching JSON response" do
      resp = json_rpc_response(id: 2, result: { "ok" => true })
      io   = StringIO.new(resp + "\n")
      result = manager.send(:read_response, io, target_id: 2, timeout: 2)
      expect(result).to be_a(Hash)
      expect(result["id"]).to eq(2)
      expect(result["result"]["ok"]).to be true
    end

    it "skips responses with non-matching ids" do
      line1 = json_rpc_response(id: 1, result: {})
      line2 = json_rpc_response(id: 2, result: { "found" => true })
      io = StringIO.new("#{line1}\n#{line2}\n")
      result = manager.send(:read_response, io, target_id: 2, timeout: 2)
      expect(result["result"]["found"]).to be true
    end

    it "returns nil when IO closes without a match" do
      io = StringIO.new("")
      expect(manager.send(:read_response, io, target_id: 99, timeout: 1)).to be_nil
    end

    it "returns nil on timeout" do
      read_io, write_io = IO.pipe
      write_io.close
      result = manager.send(:read_response, read_io, target_id: 99, timeout: 1)
      expect(result).to be_nil
      read_io.close
    end

    it "skips malformed JSON lines and continues" do
      valid = json_rpc_response(id: 5, result: { "x" => 1 })
      io    = StringIO.new("not-json\n#{valid}\n")
      result = manager.send(:read_response, io, target_id: 5, timeout: 2)
      expect(result["id"]).to eq(5)
    end
  end

  # ---------------------------------------------------------------------------
  # #mcp_call
  # ---------------------------------------------------------------------------
  describe "#mcp_call" do
    it "sends a tools/call message and returns the result" do
      call_id  = manager.instance_variable_get(:@call_id)
      tool_resp = json_rpc_response(id: call_id, result: { "structuredContent" => { "pages" => [] } })
      fake_stdin, = inject_process([tool_resp])

      result = manager.mcp_call("list_pages", {})

      expect(result).to be_a(Hash)
      expect(fake_stdin.string).to include('"tools/call"')
      expect(fake_stdin.string).to include('"list_pages"')
    end

    it "increments @call_id on each invocation" do
      id1 = manager.instance_variable_get(:@call_id)

      resp1 = json_rpc_response(id: id1, result: {})
      resp2 = json_rpc_response(id: id1 + 1, result: {})
      inject_process([resp1, resp2])

      manager.mcp_call("list_pages", {})
      expect(manager.instance_variable_get(:@call_id)).to eq(id1 + 1)

      manager.mcp_call("list_pages", {})
      expect(manager.instance_variable_get(:@call_id)).to eq(id1 + 2)
    end

    it "raises on timeout but keeps the daemon alive" do
      inject_process([])  # empty stdout → no response
      allow(manager).to receive(:read_response).and_return(nil)

      expect { manager.mcp_call("list_pages", {}) }.to raise_error(/timed out/)
      # Process must NOT be killed — it may still be healthy
      expect(manager.instance_variable_get(:@process)).not_to be_nil
    end

    it "raises on JSON-RPC error response" do
      call_id  = manager.instance_variable_get(:@call_id)
      err_resp = json_rpc_response(id: call_id, error: { "message" => "some rpc error" })
      inject_process([err_resp])

      expect { manager.mcp_call("list_pages", {}) }.to raise_error(/some rpc error/)
    end

    it "raises when result has isError: true" do
      call_id  = manager.instance_variable_get(:@call_id)
      err_resp = json_rpc_response(id: call_id, result: {
        "isError" => true,
        "content" => [{ "type" => "text", "text" => "navigation failed" }]
      })
      inject_process([err_resp])

      expect { manager.mcp_call("navigate_page", { url: "bad" }) }.to raise_error(/navigation failed/)
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
      write_config("configured" => true, "chrome_version" => "148")
      cfg = manager.send(:load_config)
      expect(cfg["configured"]).to be true
      expect(cfg["chrome_version"]).to eq("148")
    end

    it "returns {} when file is malformed" do
      File.write(config_path, ":\tinvalid:\n  yaml: [unclosed")
      expect(manager.send(:load_config)).to eq({})
    end
  end
end
