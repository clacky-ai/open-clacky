# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

# Tests the /api/profile and /api/memories endpoints.
# The server writes under ~/.clacky/agents and ~/.clacky/memories, so we
# stub the target directories to a tmpdir to keep tests hermetic.

module HttpServerProfileSpecHelpers
  def fake_req(method:, path:, body: nil, query_string: "")
    req = double("req",
      request_method: method,
      path:           path,
      body:           body ? body.to_json : nil,
      query_string:   query_string
    )
    allow(req).to receive(:[]).and_return(nil)
    req
  end

  def fake_res
    res = double("res").as_null_object
    allow(res).to receive(:status=) { |v| res.instance_variable_set(:@status, v) }
    allow(res).to receive(:body=)   { |v| res.instance_variable_set(:@body, v) }
    allow(res).to receive(:content_type=)
    allow(res).to receive(:[]=)
    allow(res).to receive(:status)  { res.instance_variable_get(:@status) }
    allow(res).to receive(:body)    { res.instance_variable_get(:@body) }
    res
  end

  def parsed_body(res)
    JSON.parse(res.body)
  end

  def dispatch(server, req, res)
    server.send(:dispatch, req, res)
  end

  def build_server
    cfg = Clacky::AgentConfig.new(models: [{
      "model"            => "test-model",
      "api_key"          => "sk-testkey1234567890abcd",
      "base_url"         => "https://api.example.com",
      "anthropic_format" => true,
      "type"             => "default"
    }])
    Clacky::Server::HttpServer.new(
      host:           "127.0.0.1",
      port:           0,
      agent_config:   cfg,
      client_factory: -> { double("client") },
      sessions_dir:   Dir.mktmpdir("clacky_profile_spec_sessions")
    )
  end
end

RSpec.describe Clacky::Server::HttpServer, "profile + memories endpoints" do
  include HttpServerProfileSpecHelpers

  let!(:agents_dir) { Dir.mktmpdir("clacky_agents_spec") }
  let!(:memories_dir) { Dir.mktmpdir("clacky_memories_spec") }

  before do
    stub_const("Clacky::Server::HttpServer::PROFILE_USER_AGENTS_DIR", agents_dir)
    stub_const("Clacky::Server::HttpServer::MEMORIES_DIR", memories_dir)
  end

  after do
    FileUtils.rm_rf(agents_dir)
    FileUtils.rm_rf(memories_dir)
  end

  let(:server) { build_server }

  # ── Profile ──────────────────────────────────────────────────────────

  describe "GET /api/profile" do
    it "returns both user and soul with is_default when no overrides exist" do
      req = fake_req(method: "GET", path: "/api/profile")
      res = fake_res
      dispatch(server, req, res)

      body = parsed_body(res)
      expect(res.status).to eq(200)
      expect(body["ok"]).to be true
      expect(body["user"]).to include("is_default" => true)
      expect(body["soul"]).to include("is_default" => true)
    end

    it "reads user override when present" do
      File.write(File.join(agents_dir, "USER.md"), "I am Yafei.\n")
      req = fake_req(method: "GET", path: "/api/profile")
      res = fake_res
      dispatch(server, req, res)
      body = parsed_body(res)
      expect(body["user"]["is_default"]).to be false
      expect(body["user"]["content"]).to include("Yafei")
    end
  end

  describe "PUT /api/profile" do
    it "writes a user override" do
      req = fake_req(method: "PUT", path: "/api/profile",
                     body: { kind: "user", content: "I love Ruby." })
      res = fake_res
      dispatch(server, req, res)
      body = parsed_body(res)
      expect(res.status).to eq(200)
      expect(body["ok"]).to be true
      expect(File.read(File.join(agents_dir, "USER.md"))).to eq("I love Ruby.")
    end

    it "writes a soul override" do
      req = fake_req(method: "PUT", path: "/api/profile",
                     body: { kind: "soul", content: "Be playful." })
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(200)
      expect(File.read(File.join(agents_dir, "SOUL.md"))).to eq("Be playful.")
    end

    it "deletes the override when content is empty (reset)" do
      File.write(File.join(agents_dir, "USER.md"), "old content")
      req = fake_req(method: "PUT", path: "/api/profile",
                     body: { kind: "user", content: "" })
      res = fake_res
      dispatch(server, req, res)
      body = parsed_body(res)
      expect(body["ok"]).to be true
      expect(body["reset"]).to be true
      expect(File.exist?(File.join(agents_dir, "USER.md"))).to be false
    end

    it "rejects an unknown kind" do
      req = fake_req(method: "PUT", path: "/api/profile",
                     body: { kind: "banana", content: "x" })
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(400)
    end
  end

  # ── Memories ─────────────────────────────────────────────────────────

  describe "GET /api/memories" do
    it "returns an empty list when dir is empty" do
      req = fake_req(method: "GET", path: "/api/memories")
      res = fake_res
      dispatch(server, req, res)
      body = parsed_body(res)
      expect(res.status).to eq(200)
      expect(body["ok"]).to be true
      expect(body["memories"]).to eq([])
    end

    it "parses frontmatter and returns summaries" do
      File.write(File.join(memories_dir, "ruby-style.md"), <<~MD)
        ---
        topic: Ruby style
        description: Yafei prefers inline private
        updated_at: 2026-05-01
        ---
        Body text here.
      MD

      req = fake_req(method: "GET", path: "/api/memories")
      res = fake_res
      dispatch(server, req, res)
      body = parsed_body(res)
      expect(body["memories"].size).to eq(1)
      m = body["memories"].first
      expect(m["topic"]).to eq("Ruby style")
      expect(m["description"]).to eq("Yafei prefers inline private")
      expect(m["updated_at"]).to eq("2026-05-01")
      expect(m["preview"]).to include("Body text")
    end
  end

  describe "POST /api/memories" do
    it "creates a new memory file" do
      req = fake_req(method: "POST", path: "/api/memories",
                     body: { filename: "test-topic.md", content: "hello" })
      res = fake_res
      dispatch(server, req, res)
      body = parsed_body(res)
      expect(res.status).to eq(201)
      expect(body["ok"]).to be true
      expect(File.read(File.join(memories_dir, "test-topic.md"))).to eq("hello")
    end

    it "rejects paths with slashes" do
      req = fake_req(method: "POST", path: "/api/memories",
                     body: { filename: "../evil.md", content: "x" })
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(400)
    end

    it "refuses to overwrite existing file" do
      File.write(File.join(memories_dir, "dupe.md"), "existing")
      req = fake_req(method: "POST", path: "/api/memories",
                     body: { filename: "dupe.md", content: "new" })
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(409)
    end
  end

  describe "GET /api/memories/:filename" do
    it "returns content for an existing memory" do
      File.write(File.join(memories_dir, "hello.md"), "# Hi there")
      req = fake_req(method: "GET", path: "/api/memories/hello.md")
      res = fake_res
      dispatch(server, req, res)
      body = parsed_body(res)
      expect(res.status).to eq(200)
      expect(body["content"]).to eq("# Hi there")
    end

    it "404s for missing memory" do
      req = fake_req(method: "GET", path: "/api/memories/nope.md")
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(404)
    end
  end

  describe "PUT /api/memories/:filename" do
    it "updates existing memory" do
      File.write(File.join(memories_dir, "edit.md"), "old")
      req = fake_req(method: "PUT", path: "/api/memories/edit.md",
                     body: { content: "new content" })
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(200)
      expect(File.read(File.join(memories_dir, "edit.md"))).to eq("new content")
    end

    it "404s for missing memory" do
      req = fake_req(method: "PUT", path: "/api/memories/missing.md",
                     body: { content: "x" })
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(404)
    end
  end

  describe "DELETE /api/memories/:filename" do
    it "removes the file" do
      File.write(File.join(memories_dir, "kill.md"), "bye")
      req = fake_req(method: "DELETE", path: "/api/memories/kill.md")
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(200)
      expect(File.exist?(File.join(memories_dir, "kill.md"))).to be false
    end
  end
end
