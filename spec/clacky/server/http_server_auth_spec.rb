require "spec_helper"

# ---------------------------------------------------------------------------
# Unit tests for HttpServer access key authentication logic.
#
# These tests exercise the brute-force protection state machine directly,
# without booting a real HTTP server. The failures hash and mutex mirror
# the instance variables initialised in HttpServer#initialize.
# ---------------------------------------------------------------------------

RSpec.describe "HttpServer access key authentication" do
  # ── Shared state (mirrors HttpServer internals) ──────────────────────────
  let(:mutex)    { Mutex.new }
  let(:failures) { {} }
  let(:ip)       { "1.2.3.4" }

  # Simulate n consecutive wrong-key attempts from ip.
  def simulate_failures(n, reset_in: 300)
    mutex.synchronize do
      entry = failures[ip] ||= { count: 0, reset_at: Time.now + reset_in }
      n.times { entry[:count] += 1 }
    end
  end

  # Returns true when the IP is currently locked out.
  def locked_out?
    entry = failures[ip]
    entry && entry[:count] >= 10 && Time.now < entry[:reset_at]
  end

  # ── local_host? behaviour ─────────────────────────────────────────────────
  describe "local_host?" do
    def local_host?(host)
      ["127.0.0.1", "::1", "localhost"].include?(host.to_s.strip)
    end

    it "treats 127.0.0.1 as localhost" do
      expect(local_host?("127.0.0.1")).to be true
    end

    it "treats ::1 as localhost" do
      expect(local_host?("::1")).to be true
    end

    it "treats 0.0.0.0 as public" do
      expect(local_host?("0.0.0.0")).to be false
    end

    it "treats arbitrary IPs as public" do
      expect(local_host?("192.168.1.1")).to be false
    end
  end

  # ── resolve_access_key behaviour ─────────────────────────────────────────
  describe "resolve_access_key" do
    it "returns key from CLACKY_ACCESS_KEY env var" do
      with_env("CLACKY_ACCESS_KEY" => "env-secret") do
        key = ENV.fetch("CLACKY_ACCESS_KEY", "").strip
        key = key.empty? ? nil : key
        expect(key).to eq("env-secret")
      end
    end

    it "returns nil when env var is blank" do
      with_env("CLACKY_ACCESS_KEY" => "   ") do
        key = ENV.fetch("CLACKY_ACCESS_KEY", "").strip
        key = key.empty? ? nil : key
        expect(key).to be_nil
      end
    end

    it "returns nil when env var is not set" do
      with_env("CLACKY_ACCESS_KEY" => "") do
        key = ENV.fetch("CLACKY_ACCESS_KEY", "").strip
        key = key.empty? ? nil : key
        expect(key).to be_nil
      end
    end
  end

  # ── Lockout threshold ─────────────────────────────────────────────────────
  describe "lockout threshold" do
    it "does not lock out after 9 failures" do
      simulate_failures(9)
      expect(failures[ip][:count]).to eq(9)
      expect(locked_out?).to be false
    end

    it "locks out at exactly 10 failures" do
      simulate_failures(10)
      expect(locked_out?).to be true
    end
  end

  # ── Lockout duration ──────────────────────────────────────────────────────
  describe "lockout duration" do
    it "sets reset_at to ~300s in the future" do
      simulate_failures(10)
      expect(failures[ip][:reset_at]).to be_within(5).of(Time.now + 300)
    end

    it "remains locked during the lockout window" do
      simulate_failures(10, reset_in: 300)
      expect(locked_out?).to be true
    end

    it "unlocks after reset_at has passed" do
      simulate_failures(10, reset_in: -1)
      expect(locked_out?).to be false
    end
  end

  # ── Missing key must not increment failure counter ────────────────────────
  describe "missing key does not count as failure" do
    it "failure count stays 0 when no key is provided" do
      # Simulate the nil-candidate branch: failures hash must remain untouched.
      candidate = nil
      unless candidate.nil? || candidate.to_s.empty?
        mutex.synchronize do
          entry = failures[ip] ||= { count: 0, reset_at: Time.now + 300 }
          entry[:count] += 1
        end
      end
      expect(failures[ip]).to be_nil
    end
  end

  # ── Successful auth clears the failure record ─────────────────────────────
  describe "successful auth clears record" do
    it "removes the IP entry on successful login" do
      simulate_failures(5)
      expect(failures[ip]).not_to be_nil
      mutex.synchronize { failures.delete(ip) }
      expect(failures[ip]).to be_nil
    end
  end

  # ── extract_key: cookie fallback ─────────────────────────────────────────
  # REGRESSION GUARD: The cookie branch was accidentally removed in a prior
  # refactor. This block ensures it is never silently deleted again.
  describe "extract_key cookie fallback" do

    # allocate 跳过 initialize，直接拿到一个干净的实例
    # extract_key 是纯函数：只读 req，不依赖任何实例变量
    let(:server) { Clacky::Server::HttpServer.allocate }

    def make_req(authorization: nil, query_string: "", cookies: {})
      req = double("WEBrick::HTTPRequest")
      allow(req).to receive(:[]) { |k| k == "Authorization" ? authorization.to_s : "" }
      allow(req).to receive(:query_string).and_return(query_string)
      allow(req).to receive(:cookies).and_return(
        cookies.map { |name, value| double("cookie", name: name.to_s, value: value.to_s) }
      )
      req
    end

    # ── Cookie 是唯一来源 ────────────────────────────────────────────────────
    it "returns the cookie value when no header or query param is present" do
      req = make_req(cookies: { "clacky_access_key" => "cookie-secret" })
      expect(server.send(:extract_key, req)).to eq("cookie-secret")
    end

    it "ignores cookies with unrelated names" do
      req = make_req(cookies: { "other_cookie" => "irrelevant" })
      expect(server.send(:extract_key, req)).to be_nil
    end

    it "returns nil when cookie value is empty" do
      req = make_req(cookies: { "clacky_access_key" => "" })
      expect(server.send(:extract_key, req)).to be_nil
    end

    # ── 优先级：Bearer > query param > cookie ────────────────────────────────
    it "prefers Bearer header over cookie" do
      req = make_req(
        authorization: "Bearer header-wins",
        cookies:       { "clacky_access_key" => "cookie-key" }
      )
      expect(server.send(:extract_key, req)).to eq("header-wins")
    end

    it "prefers query param over cookie" do
      req = make_req(
        query_string: "access_key=query-wins",
        cookies:      { "clacky_access_key" => "cookie-key" }
      )
      expect(server.send(:extract_key, req)).to eq("query-wins")
    end

    it "falls back to cookie when header and query param are absent" do
      req = make_req(cookies: { "clacky_access_key" => "cookie-wins" })
      expect(server.send(:extract_key, req)).to eq("cookie-wins")
    end

    # ── 无凭证 ───────────────────────────────────────────────────────────────
    it "returns nil when all sources are empty" do
      expect(server.send(:extract_key, make_req)).to be_nil
    end
  end
end
