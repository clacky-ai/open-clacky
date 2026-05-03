# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require "clacky/utils/trash_directory"
require "clacky/tools/trash_manager"

# Minimal helpers duplicated from http_server_spec.rb to stay independent
# of spec file load order.

module HttpServerTrashSpecHelpers
  def fake_req(method:, path:, body: nil, query_string: "")
    req = double("req",
      request_method: method,
      path:           path,
      body:           body ? body.to_json : nil,
      query_string:   query_string,
      "[]":           nil
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

  # Build a server instance suitable for dispatcher tests.
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
      sessions_dir:   Dir.mktmpdir("clacky_trash_spec_sessions")
    )
  end

  # Create a fake trashed file under the given project's trash dir and
  # return the absolute original_path it claims to have come from.
  def seed_trash_file(project_root:, basename:, content: "bye", deleted_at: Time.now.utc.iso8601)
    td = Clacky::TrashDirectory.new(project_root)
    ts = Time.now.strftime("%Y%m%d_%H%M%S_%L%N")
    dest = File.join(td.trash_dir, "#{basename}_deleted_#{ts}")
    File.write(dest, content)
    original_path = File.join(project_root, basename)
    ext = File.extname(basename)
    meta = {
      "original_path"   => original_path,
      "trash_directory" => td.trash_dir,
      "deleted_at"      => deleted_at,
      "deleted_by"      => "clacky_rm_shell",
      "file_size"       => content.bytesize,
      "file_type"       => ext,
      "file_mode"       => "644"
    }
    File.write("#{dest}.metadata.json", JSON.generate(meta))
    { original_path: original_path, trash_file: dest, project_root: project_root }
  end
end

RSpec.describe Clacky::Server::HttpServer, "creator trash endpoints" do
  include HttpServerTrashSpecHelpers

  # Redirect GLOBAL_TRASH_ROOT to a tmpdir for the duration of each spec so we
  # don't pollute the developer's real ~/.clacky/trash.
  let!(:trash_root) { Dir.mktmpdir("clacky_trash_root_spec") }
  before { stub_const("Clacky::TrashDirectory::GLOBAL_TRASH_ROOT", trash_root) }
  after  { FileUtils.rm_rf(trash_root) }

  let(:server) { build_server }

  let(:project_a) { Dir.mktmpdir("proj_a") }
  let(:project_b) { Dir.mktmpdir("proj_b") }
  after do
    FileUtils.rm_rf(project_a)
    FileUtils.rm_rf(project_b)
  end

  describe "GET /api/trash" do
    it "returns ok:true with empty lists when no trash exists" do
      req = fake_req(method: "GET", path: "/api/trash")
      res = fake_res
      dispatch(server, req, res)

      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["ok"]).to eq(true)
      expect(body["files"]).to eq([])
      expect(body["total_count"]).to eq(0)
    end

    it "aggregates trashed files across multiple projects" do
      seed_trash_file(project_root: project_a, basename: "a1.txt", content: "aaa")
      seed_trash_file(project_root: project_a, basename: "a2.txt", content: "bb")
      seed_trash_file(project_root: project_b, basename: "b1.txt", content: "c")

      req = fake_req(method: "GET", path: "/api/trash")
      res = fake_res
      dispatch(server, req, res)

      body = parsed_body(res)
      expect(body["ok"]).to eq(true)
      expect(body["total_count"]).to eq(3)
      expect(body["files"].map { |f| f["project_root"] }).to include(project_a, project_b)
      expect(body["projects"].size).to eq(2)
      # total_size = 3 + 2 + 1
      expect(body["total_size"]).to eq(6)
    end

    it "restricts to a single project when ?project=<path> is given" do
      seed_trash_file(project_root: project_a, basename: "a1.txt")
      seed_trash_file(project_root: project_b, basename: "b1.txt")

      qs  = URI.encode_www_form(project: project_a)
      req = fake_req(method: "GET", path: "/api/trash", query_string: qs)
      res = fake_res
      dispatch(server, req, res)

      body = parsed_body(res)
      expect(body["total_count"]).to eq(1)
      expect(body["files"].first["original_path"]).to eq(File.join(project_a, "a1.txt"))
    end
  end

  describe "POST /api/trash/restore" do
    it "restores a trashed file back to its original path" do
      seeded = seed_trash_file(project_root: project_a, basename: "restore_me.txt", content: "HI")
      original = seeded[:original_path]
      expect(File.exist?(original)).to be(false)

      req = fake_req(
        method: "POST",
        path:   "/api/trash/restore",
        body:   { project_root: project_a, original_path: original }
      )
      res = fake_res
      dispatch(server, req, res)

      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["ok"]).to eq(true)
      expect(File.exist?(original)).to be(true)
      expect(File.read(original)).to eq("HI")
    end

    it "returns 400 when required fields are missing" do
      req = fake_req(
        method: "POST",
        path:   "/api/trash/restore",
        body:   { project_root: project_a }
      )
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(400)
      expect(parsed_body(res)["ok"]).to eq(false)
    end

    it "returns 422 when the file isn't in trash" do
      req = fake_req(
        method: "POST",
        path:   "/api/trash/restore",
        body:   { project_root: project_a, original_path: File.join(project_a, "ghost.txt") }
      )
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(422)
      expect(parsed_body(res)["ok"]).to eq(false)
    end
  end

  describe "DELETE /api/trash (single file mode)" do
    it "permanently deletes a single file when ?file=... & ?project=... are given" do
      seeded = seed_trash_file(project_root: project_a, basename: "bye.log", content: "old")
      trash_file = seeded[:trash_file]
      expect(File.exist?(trash_file)).to be(true)

      qs  = URI.encode_www_form(project: project_a, file: seeded[:original_path])
      req = fake_req(method: "DELETE", path: "/api/trash", query_string: qs)
      res = fake_res
      dispatch(server, req, res)

      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["ok"]).to eq(true)
      expect(body["deleted_count"]).to eq(1)
      expect(File.exist?(trash_file)).to be(false)
      expect(File.exist?("#{trash_file}.metadata.json")).to be(false)
    end

    it "returns 404 if the file doesn't match any trashed entry" do
      qs  = URI.encode_www_form(project: project_a, file: File.join(project_a, "nope.txt"))
      req = fake_req(method: "DELETE", path: "/api/trash", query_string: qs)
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(404)
    end

    it "returns 400 if ?file is given without ?project" do
      qs  = URI.encode_www_form(file: "/some/path.txt")
      req = fake_req(method: "DELETE", path: "/api/trash", query_string: qs)
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(400)
    end
  end

  describe "DELETE /api/trash (bulk empty mode)" do
    it "empties all files when days_old=0 and no project filter is given" do
      seed_trash_file(project_root: project_a, basename: "x.txt")
      seed_trash_file(project_root: project_b, basename: "y.txt")

      qs  = URI.encode_www_form(days_old: "0")
      req = fake_req(method: "DELETE", path: "/api/trash", query_string: qs)
      res = fake_res
      dispatch(server, req, res)

      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["ok"]).to eq(true)
      expect(body["deleted_count"]).to eq(2)

      # Both trash entries should be gone.
      [project_a, project_b].each do |root|
        trash_dir = Clacky::TrashDirectory.new(root).trash_dir
        leftover = Dir.glob(File.join(trash_dir, "*.metadata.json"))
        expect(leftover).to be_empty
      end
    end

    it "only deletes files older than `days_old` days" do
      # Old: 10 days ago; recent: just now.
      old = (Time.now - 10 * 86400).utc.iso8601
      seed_trash_file(project_root: project_a, basename: "old.txt",    content: "o",  deleted_at: old)
      seed_trash_file(project_root: project_a, basename: "recent.txt", content: "r")

      qs  = URI.encode_www_form(project: project_a, days_old: "7")
      req = fake_req(method: "DELETE", path: "/api/trash", query_string: qs)
      res = fake_res
      dispatch(server, req, res)

      body = parsed_body(res)
      expect(body["deleted_count"]).to eq(1)

      # The recent file survives.
      trash_dir = Clacky::TrashDirectory.new(project_a).trash_dir
      surviving = Dir.glob(File.join(trash_dir, "*.metadata.json")).map do |m|
        JSON.parse(File.read(m))["original_path"]
      end
      expect(surviving).to eq([File.join(project_a, "recent.txt")])
    end
  end
end
