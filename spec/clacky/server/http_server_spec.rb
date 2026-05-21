# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

module HttpServerSpecHelpers
  # Start the server in a background thread; yield a Net::HTTP instance.
  # The server is shut down after the block returns.
  def with_server(agent_config:, client_factory: -> { double("client") }, sessions_dir: nil)
    dir = sessions_dir || Dir.mktmpdir("clacky_http_spec_sessions")
    server = Clacky::Server::HttpServer.new(
      host:           "127.0.0.1",
      port:           0,  # OS picks a free port
      agent_config:   agent_config,
      client_factory: client_factory,
      sessions_dir:   dir
    )

    # We only need the dispatcher (dispatch method), not the full WEBrick loop.
    # Expose the internal dispatcher directly for unit testing via a lightweight
    # Rack-like test harness.
    yield server
  ensure
    FileUtils.rm_rf(dir) unless sessions_dir  # only clean up if we created it
  end

  # Build a minimal fake WEBrick request object.
  def fake_req(method:, path:, body: nil, headers: {}, query_string: "")
    req = double("req",
      request_method: method,
      path:           path,
      body:           body ? body.to_json : nil,
      query_string:   query_string,
      "[]":           nil
    )
    allow(req).to receive(:instance_variable_get).and_return(nil)
    allow(req).to receive(:[]) { |k| headers[k] }
    req
  end

  # Build a response collector that captures status + body.
  def fake_res
    res = double("res").as_null_object
    allow(res).to receive(:status=)  { |v| res.instance_variable_set(:@status, v) }
    allow(res).to receive(:body=)    { |v| res.instance_variable_set(:@body, v) }
    allow(res).to receive(:content_type=)
    allow(res).to receive(:[]=)
    allow(res).to receive(:status)   { res.instance_variable_get(:@status) }
    allow(res).to receive(:body)     { res.instance_variable_get(:@body) }
    res
  end

  def parsed_body(res)
    JSON.parse(res.body)
  end

  # Call the private dispatch method directly.
  def dispatch(server, req, res)
    server.send(:dispatch, req, res)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Specs
# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe Clacky::Server::HttpServer do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_http_server_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      {
        "model"            => "test-model",
        "api_key"          => "sk-testkey1234567890abcd",
        "base_url"         => "https://api.example.com",
        "anthropic_format" => true,
        "type"             => "default"
      }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  after { FileUtils.rm_rf(tmpdir) }

  # ── Initialization ────────────────────────────────────────────────────────

  describe "#initialize" do
    it "stores host, port, agent_config, and client_factory" do
      factory = -> { double("client") }
      server = described_class.new(
        host: "0.0.0.0", port: 8080,
        agent_config: agent_config, client_factory: factory
      )
      expect(server.instance_variable_get(:@host)).to eq("0.0.0.0")
      expect(server.instance_variable_get(:@port)).to eq(8080)
      expect(server.instance_variable_get(:@agent_config)).to eq(agent_config)
      expect(server.instance_variable_get(:@client_factory)).to eq(factory)
    end

    it "creates an empty session registry when sessions_dir is empty" do
      server = described_class.new(
        agent_config: agent_config, client_factory: -> {}, sessions_dir: tmpdir
      )
      expect(server.instance_variable_get(:@registry).list).to eq([])
    end
  end

  # ── GET /api/sessions ─────────────────────────────────────────────────────

  describe "GET /api/sessions" do
    it "returns an empty sessions array initially" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/sessions")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body).to have_key("sessions")
        expect(body["sessions"]).to be_an(Array)
        expect(body).to have_key("has_more")
      end
    end

    it "filters by source via ?source= query param" do
      with_server(agent_config: agent_config) do |server|
        # Create a manual session and a cron session
        dispatch(server, fake_req(method: "POST", path: "/api/sessions",
                                  body: { name: "manual-s", source: "manual" }), fake_res)
        dispatch(server, fake_req(method: "POST", path: "/api/sessions",
                                  body: { name: "cron-s", source: "cron" }), fake_res)

        req = fake_req(method: "GET", path: "/api/sessions", query_string: "source=cron")
        res = fake_res
        dispatch(server, req, res)

        sessions = parsed_body(res)["sessions"]
        expect(sessions.map { |s| s["name"] }).to include("cron-s")
        expect(sessions.map { |s| s["source"] }.uniq).to eq(["cron"])
      end
    end

    it "returns all sessions when no source filter given" do
      with_server(agent_config: agent_config) do |server|
        dispatch(server, fake_req(method: "POST", path: "/api/sessions",
                                  body: { name: "onboard", source: "setup" }), fake_res)
        dispatch(server, fake_req(method: "POST", path: "/api/sessions",
                                  body: { name: "normal" }), fake_res)

        req = fake_req(method: "GET", path: "/api/sessions")
        res = fake_res
        dispatch(server, req, res)

        names = parsed_body(res)["sessions"].map { |s| s["name"] }
        expect(names).to include("normal")
        expect(names).to include("onboard")
      end
    end

    it "returns setup sessions when source=setup" do
      with_server(agent_config: agent_config) do |server|
        dispatch(server, fake_req(method: "POST", path: "/api/sessions",
                                  body: { name: "setup-s", source: "setup" }), fake_res)
        dispatch(server, fake_req(method: "POST", path: "/api/sessions",
                                  body: { name: "manual-s" }), fake_res)

        req = fake_req(method: "GET", path: "/api/sessions", query_string: "source=setup")
        res = fake_res
        dispatch(server, req, res)

        names = parsed_body(res)["sessions"].map { |s| s["name"] }
        expect(names).to include("setup-s")
        expect(names).not_to include("manual-s")
      end
    end

    it "filters by profile=coding via ?profile= query param" do
      with_server(agent_config: agent_config) do |server|
        dispatch(server, fake_req(method: "POST", path: "/api/sessions",
                                  body: { name: "general-s" }), fake_res)
        dispatch(server, fake_req(method: "POST", path: "/api/sessions",
                                  body: { name: "coding-s", agent_profile: "coding" }), fake_res)

        req = fake_req(method: "GET", path: "/api/sessions", query_string: "profile=coding")
        res = fake_res
        dispatch(server, req, res)

        sessions = parsed_body(res)["sessions"]
        expect(sessions.map { |s| s["name"] }).to include("coding-s")
        expect(sessions.map { |s| s["agent_profile"] }.uniq).to eq(["coding"])
      end
    end

    it "respects limit and returns has_more=true when more sessions exist" do
      with_server(agent_config: agent_config) do |server|
        3.times { |i| dispatch(server, fake_req(method: "POST", path: "/api/sessions",
                                                body: { name: "s#{i}" }), fake_res) }

        req = fake_req(method: "GET", path: "/api/sessions", query_string: "limit=2")
        res = fake_res
        dispatch(server, req, res)

        body = parsed_body(res)
        expect(body["sessions"].size).to eq(2)
        expect(body["has_more"]).to be true
      end
    end

    # ── Pinned-session visibility (regression for 0.9.37) ─────────────────
    #
    # Before this fix, the sidebar would sometimes fail to show pinned
    # sessions and "refreshing sometimes fixed it". Root cause: the backend
    # only ordered by created_at and applied `limit` blindly, so a pinned
    # session older than the first `limit` rows would be cut off entirely.
    # The fix: `registry.list` always returns ALL matching pinned sessions
    # on the first page, then fills up to `limit` non-pinned rows after.
    describe "pinned sessions always appear on the first page" do
      # Helper: drop a fully-formed session JSON directly on disk so we
      # control created_at precisely (POST /api/sessions always uses Time.now,
      # which can't reliably produce "old" sessions for this test).
      def write_session_file(dir, session_id:, name:, created_at:, pinned: false, source: "manual")
        data = {
          session_id:    session_id,
          name:          name,
          created_at:    created_at,
          updated_at:    created_at,
          working_dir:   "/tmp",
          source:        source,
          agent_profile: "general",
          pinned:        pinned,
          messages:      [],
          stats:         { total_tasks: 0, total_cost_usd: 0.0 },
        }
        datetime = Time.parse(created_at).strftime("%Y-%m-%d-%H-%M-%S")
        short_id = session_id[0..7]
        File.write(File.join(dir, "#{datetime}-#{short_id}.json"),
                   JSON.pretty_generate(data))
      end

      it "includes an OLD pinned session in the first page even when limit is small" do
        # Simulate the user-reported bug: one pinned session is very old,
        # and many newer sessions exist. With limit=3, the old pinned one
        # would previously be cut off. After the fix, it MUST still appear.
        Dir.mktmpdir("clacky_pin_spec") do |dir|
          # 1 very old pinned session + 5 newer non-pinned sessions
          write_session_file(dir, session_id: "old_pin_01",  name: "old-pin",
                             created_at: "2020-01-01T00:00:00+00:00", pinned: true)
          5.times do |i|
            ts = "2026-04-01T0#{i}:00:00+00:00"
            write_session_file(dir, session_id: "newer#{i}_abcdef01",
                               name: "newer-#{i}", created_at: ts, pinned: false)
          end

          with_server(agent_config: agent_config, sessions_dir: dir) do |server|
            req = fake_req(method: "GET", path: "/api/sessions",
                           query_string: "limit=3")
            res = fake_res
            dispatch(server, req, res)

            body = parsed_body(res)
            names = body["sessions"].map { |s| s["name"] }
            # The critical assertion: old pinned session must be present
            expect(names).to include("old-pin"), "old pinned session must appear on first page (got #{names.inspect})"
            # And it should be at the TOP (pinned first)
            expect(names.first).to eq("old-pin")
            # limit=3 still returns up to 3 NON-pinned, so total is 1 + 3 = 4
            expect(body["sessions"].size).to eq(4)
            # has_more reflects non-pinned overflow (5 non-pinned, 3 returned → more)
            expect(body["has_more"]).to be true
          end
        end
      end

      it "returns multiple pinned sessions all on the first page regardless of limit" do
        Dir.mktmpdir("clacky_pin_spec") do |dir|
          # 3 pinned (across different ages) + 2 non-pinned
          write_session_file(dir, session_id: "pin_a_aaaaaaaa", name: "pin-a",
                             created_at: "2020-01-01T00:00:00+00:00", pinned: true)
          write_session_file(dir, session_id: "pin_b_bbbbbbbb", name: "pin-b",
                             created_at: "2023-06-01T00:00:00+00:00", pinned: true)
          write_session_file(dir, session_id: "pin_c_cccccccc", name: "pin-c",
                             created_at: "2026-04-01T00:00:00+00:00", pinned: true)
          write_session_file(dir, session_id: "plain_x_xxxxxxx", name: "plain-x",
                             created_at: "2026-04-10T00:00:00+00:00", pinned: false)
          write_session_file(dir, session_id: "plain_y_yyyyyyy", name: "plain-y",
                             created_at: "2026-04-11T00:00:00+00:00", pinned: false)

          with_server(agent_config: agent_config, sessions_dir: dir) do |server|
            # Even with limit=1, all 3 pinned should come through.
            req = fake_req(method: "GET", path: "/api/sessions",
                           query_string: "limit=1")
            res = fake_res
            dispatch(server, req, res)

            body = parsed_body(res)
            names = body["sessions"].map { |s| s["name"] }
            # All three pinned present
            expect(names).to include("pin-a", "pin-b", "pin-c")
            # Pinned come before non-pinned
            pinned_idx = names.each_index.select { |i| body["sessions"][i]["pinned"] }
            non_idx    = names.each_index.reject { |i| body["sessions"][i]["pinned"] }
            expect(pinned_idx.max).to be < non_idx.min if non_idx.any?
            # Pinned sorted newest-first among themselves (pin-c, pin-b, pin-a)
            pinned_names = pinned_idx.map { |i| names[i] }
            expect(pinned_names).to eq(["pin-c", "pin-b", "pin-a"])
          end
        end
      end

      it "does NOT include pinned sessions on subsequent pages (before cursor set)" do
        # Pinned sessions are a first-page-only section; the load-more
        # responses must contain only non-pinned rows to avoid duplication.
        Dir.mktmpdir("clacky_pin_spec") do |dir|
          write_session_file(dir, session_id: "pin_a_aaaaaaaa", name: "pin-a",
                             created_at: "2026-04-15T00:00:00+00:00", pinned: true)
          write_session_file(dir, session_id: "plain_1_1111111", name: "plain-1",
                             created_at: "2026-04-10T00:00:00+00:00", pinned: false)
          write_session_file(dir, session_id: "plain_2_2222222", name: "plain-2",
                             created_at: "2026-04-05T00:00:00+00:00", pinned: false)

          with_server(agent_config: agent_config, sessions_dir: dir) do |server|
            # Simulate "load more": cursor = before plain-1
            req = fake_req(method: "GET", path: "/api/sessions",
                           query_string: "limit=10&before=2026-04-10T00:00:00%2B00:00")
            res = fake_res
            dispatch(server, req, res)

            body = parsed_body(res)
            names = body["sessions"].map { |s| s["name"] }
            expect(names).to eq(["plain-2"])   # only the older non-pinned
            expect(names).not_to include("pin-a")
          end
        end
      end
    end
  end

  # ── POST /api/sessions ────────────────────────────────────────────────────

  describe "POST /api/sessions" do
    it "creates a new session and returns it" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/sessions",
                       body: { name: "my-session" })
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(201)
        body = parsed_body(res)
        expect(body["session"]).to include("name" => "my-session")
        expect(body["session"]["id"]).not_to be_nil
      end
    end

    it "defaults source to manual" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/sessions", body: { name: "s" })
        res = fake_res
        dispatch(server, req, res)

        expect(parsed_body(res)["session"]["source"]).to eq("manual")
      end
    end

    it "accepts source: setup and sets it on the session" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/sessions",
                       body: { name: "onboard", source: "setup" })
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(201)
        expect(parsed_body(res)["session"]["source"]).to eq("setup")
      end
    end

    it "ignores unknown source values and falls back to manual" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/sessions",
                       body: { name: "s", source: "bogus" })
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(201)
        expect(parsed_body(res)["session"]["source"]).to eq("manual")
      end
    end

    it "accepts agent_profile: coding" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/sessions",
                       body: { name: "code-s", agent_profile: "coding" })
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(201)
        expect(parsed_body(res)["session"]["agent_profile"]).to eq("coding")
      end
    end

    it "returns 400 when name is not provided" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/sessions", body: {})
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(400)
        body = parsed_body(res)
        expect(body["error"]).to match(/name is required/i)
      end
    end

    # ── model_id override ──────────────────────────────────────────────────
    # Regression: webui "More Options" used to pass a bare model name and the
    # server rewrote current_model["model"] in place, keeping the old
    # api_key / base_url / anthropic_format. Picking a non-default model
    # therefore produced "unknown model <name>" from the original provider.
    # Fix: pass the stable model_id and call switch_model_by_id so the full
    # model entry (credentials + endpoint + format) is activated for the
    # new session only.
    context "with model_id override" do
      let(:multi_model_config) do
        cfg = Clacky::AgentConfig.new(models: [
          {
            "model"            => "abs-claude-sonnet-4-5",
            "api_key"          => "clacky-aaaaaaaaaaaa1111",
            "base_url"         => "https://api.openclacky.com",
            "anthropic_format" => true,
            "type"             => "default"
          },
          {
            "model"            => "deepseek-v4-pro",
            "api_key"          => "sk-deepseekkey1234567890",
            "base_url"         => "https://api.deepseek.com",
            "anthropic_format" => false
          }
        ])
        stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
        cfg
      end

      it "creates a session on the overridden model (by id) without touching the default entry" do
        with_server(agent_config: multi_model_config) do |server|
          target = multi_model_config.models.find { |m| m["model"] == "deepseek-v4-pro" }
          original_default_name = multi_model_config.models.first["model"]

          req = fake_req(method: "POST", path: "/api/sessions",
                         body: { name: "ds-s", model_id: target["id"] })
          res = fake_res
          dispatch(server, req, res)

          expect(res.status).to eq(201)
          session_id = parsed_body(res)["session"]["id"]

          # The created session should resolve to the deepseek entry.
          registry = server.instance_variable_get(:@registry)
          agent = nil
          registry.with_session(session_id) { |s| agent = s[:agent] }
          expect(agent.current_model_info[:model]).to eq("deepseek-v4-pro")
          expect(agent.current_model_info[:base_url]).to eq("https://api.deepseek.com")

          # The shared @models array MUST NOT be mutated — the default entry's
          # model name stays put, so other sessions (and config.yml on save)
          # are unaffected by this per-session override.
          expect(multi_model_config.models.first["model"]).to eq(original_default_name)
        end
      end

      it "returns 400 when model_id does not match any configured model" do
        with_server(agent_config: multi_model_config) do |server|
          req = fake_req(method: "POST", path: "/api/sessions",
                         body: { name: "bad-s", model_id: "nonexistent-uuid" })
          res = fake_res
          dispatch(server, req, res)

          expect(res.status).to eq(400)
          expect(parsed_body(res)["error"]).to match(/Model not found/i)
        end
      end

      it "falls back to the default model when model_id is omitted" do
        with_server(agent_config: multi_model_config) do |server|
          req = fake_req(method: "POST", path: "/api/sessions", body: { name: "def-s" })
          res = fake_res
          dispatch(server, req, res)

          expect(res.status).to eq(201)
          session_id = parsed_body(res)["session"]["id"]

          registry = server.instance_variable_get(:@registry)
          agent = nil
          registry.with_session(session_id) { |s| agent = s[:agent] }
          expect(agent.current_model_info[:model]).to eq("abs-claude-sonnet-4-5")
        end
      end
    end
  end

  # ── DELETE /api/sessions/:id ──────────────────────────────────────────────

  describe "DELETE /api/sessions/:id" do
    it "deletes an existing session" do
      with_server(agent_config: agent_config) do |server|
        # Create a session first
        create_req = fake_req(method: "POST", path: "/api/sessions",
                              body: { name: "to-delete" })
        create_res = fake_res
        dispatch(server, create_req, create_res)
        session_id = parsed_body(create_res)["session"]["id"]

        # Now delete it
        del_req = fake_req(method: "DELETE", path: "/api/sessions/#{session_id}")
        del_res = fake_res
        dispatch(server, del_req, del_res)

        expect(del_res.status).to eq(200)
        expect(parsed_body(del_res)["ok"]).to be true
      end
    end

    it "returns 404 when session does not exist" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "DELETE", path: "/api/sessions/nonexistent-id")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(404)
      end
    end
  end

  # ── GET /api/config ───────────────────────────────────────────────────────

  describe "GET /api/config" do
    it "returns the model list with masked API keys" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/config")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["models"]).to be_an(Array)
        expect(body["models"].length).to eq(1)

        m = body["models"].first
        expect(m["model"]).to eq("test-model")
        expect(m["base_url"]).to eq("https://api.example.com")
        expect(m["anthropic_format"]).to be true
        expect(m["type"]).to eq("default")
        # API key should be masked
        expect(m["api_key_masked"]).to include("****")
        expect(m["api_key_masked"]).not_to eq("sk-testkey1234567890abcd")
      end
    end

    it "includes current_index in the response" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/config")
        res = fake_res
        dispatch(server, req, res)

        body = parsed_body(res)
        expect(body).to have_key("current_index")
      end
    end
  end

  # ── Single-item model CRUD APIs ───────────────────────────────────────────
  # These replace the old bulk POST /api/config. Each endpoint touches
  # exactly ONE model, so a bug in one save path cannot corrupt other rows.

  describe "POST /api/config/models" do
    it "creates a new model and returns its id" do
      with_server(agent_config: agent_config) do |server|
        payload = {
          model:            "claude-opus-4",
          base_url:         "https://api.anthropic.com",
          api_key:          "sk-newkey0000111122223333",
          anthropic_format: true
        }
        req = fake_req(method: "POST", path: "/api/config/models", body: payload)
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["ok"]).to be true
        expect(body["id"]).to be_a(String)

        created = agent_config.models.find { |m| m["id"] == body["id"] }
        expect(created["model"]).to eq("claude-opus-4")
        expect(created["api_key"]).to eq("sk-newkey0000111122223333")
      end
    end

    it "rejects creation without a real api_key" do
      with_server(agent_config: agent_config) do |server|
        payload = { model: "x", base_url: "https://x", api_key: "" }
        req = fake_req(method: "POST", path: "/api/config/models", body: payload)
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
      end
    end

    it "rejects creation with a masked placeholder api_key" do
      with_server(agent_config: agent_config) do |server|
        payload = { model: "x", base_url: "https://x", api_key: "sk-ab****wxyz" }
        req = fake_req(method: "POST", path: "/api/config/models", body: payload)
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
      end
    end
  end

  describe "PATCH /api/config/models/:id" do
    it "updates only the specified fields" do
      with_server(agent_config: agent_config) do |server|
        id = agent_config.models[0]["id"]
        original_key = agent_config.models[0]["api_key"]

        payload = { model: "renamed-model" }
        req = fake_req(method: "PATCH", path: "/api/config/models/#{id}", body: payload)
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        expect(agent_config.models[0]["model"]).to eq("renamed-model")
        # api_key untouched (not in payload)
        expect(agent_config.models[0]["api_key"]).to eq(original_key)
      end
    end

    it "ignores api_key when value is masked (****)" do
      with_server(agent_config: agent_config) do |server|
        id = agent_config.models[0]["id"]
        original_key = agent_config.models[0]["api_key"]

        payload = { api_key: "sk-test****abcd" }
        req = fake_req(method: "PATCH", path: "/api/config/models/#{id}", body: payload)
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        expect(agent_config.models[0]["api_key"]).to eq(original_key)
      end
    end

    it "ignores api_key when value is empty string" do
      with_server(agent_config: agent_config) do |server|
        id = agent_config.models[0]["id"]
        original_key = agent_config.models[0]["api_key"]

        payload = { api_key: "" }
        req = fake_req(method: "PATCH", path: "/api/config/models/#{id}", body: payload)
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        expect(agent_config.models[0]["api_key"]).to eq(original_key)
      end
    end

    it "updates api_key when a real non-masked value is provided" do
      with_server(agent_config: agent_config) do |server|
        id = agent_config.models[0]["id"]

        payload = { api_key: "sk-brand-new-key-here" }
        req = fake_req(method: "PATCH", path: "/api/config/models/#{id}", body: payload)
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        expect(agent_config.models[0]["api_key"]).to eq("sk-brand-new-key-here")
      end
    end

    it "returns 404 for unknown id" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "PATCH", path: "/api/config/models/nope", body: { model: "x" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(404)
      end
    end

    # Regression for the "saving one model wiped other api_keys" bug:
    # PATCHing model A must never touch model B's api_key, by design.
    it "does not touch other models' api_keys" do
      agent_config.models << {
        "id"       => "model-2-id",
        "model"    => "second-model",
        "api_key"  => "sk-second-must-survive",
        "base_url" => "https://api2.example.com"
      }

      with_server(agent_config: agent_config) do |server|
        id = agent_config.models[0]["id"]
        payload = { model: "renamed", api_key: "sk-brand-new-one" }
        req = fake_req(method: "PATCH", path: "/api/config/models/#{id}", body: payload)
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        second = agent_config.models.find { |m| m["id"] == "model-2-id" }
        expect(second["api_key"]).to eq("sk-second-must-survive")
      end
    end
  end

  describe "DELETE /api/config/models/:id" do
    it "removes the specified model" do
      agent_config.models << {
        "id" => "model-2-id", "model" => "m2",
        "api_key" => "k2", "base_url" => "https://x"
      }

      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "DELETE", path: "/api/config/models/model-2-id")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        expect(agent_config.models.none? { |m| m["id"] == "model-2-id" }).to be true
      end
    end

    it "returns 422 when trying to delete the last model" do
      with_server(agent_config: agent_config) do |server|
        id = agent_config.models[0]["id"]
        req = fake_req(method: "DELETE", path: "/api/config/models/#{id}")
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
      end
    end

    it "returns 404 for unknown id" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "DELETE", path: "/api/config/models/nope")
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(404)
      end
    end
  end

  describe "POST /api/config/models/:id/default" do
    it "promotes the target model to default and re-anchors current_*" do
      agent_config.models << {
        "id" => "model-2-id", "model" => "opus",
        "api_key" => "k2", "base_url" => "https://opus"
      }

      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/config/models/model-2-id/default")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        new_default = agent_config.models.find { |m| m["type"] == "default" }
        expect(new_default["id"]).to eq("model-2-id")
        expect(agent_config.current_model_id).to eq("model-2-id")

        # A freshly-derived session config must see the new default — this
        # is the regression guard for the old "requires restart" bug.
        fresh = agent_config.deep_copy
        expect(fresh.current_model["id"]).to eq("model-2-id")
      end
    end

    it "returns 404 for unknown id" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/config/models/nope/default")
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(404)
      end
    end
  end

  # ── POST /api/config/test ─────────────────────────────────────────────────

  describe "POST /api/config/test" do
    it "returns ok: true when connection succeeds" do
      test_client = double("client")
      allow(test_client).to receive(:test_connection).and_return({ success: true })

      factory_called = false
      client_factory = -> { factory_called = true; double("main_client") }

      with_server(agent_config: agent_config, client_factory: client_factory) do |server|
        allow(Clacky::Client).to receive(:new).and_return(test_client)

        payload = {
          model:            "test-model",
          base_url:         "https://api.example.com",
          api_key:          "sk-testkey1234567890abcd",
          anthropic_format: false
        }
        req = fake_req(method: "POST", path: "/api/config/test", body: payload)
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["ok"]).to be true
        expect(body["message"]).to eq("Connected successfully")
      end
    end

    it "returns ok: false when connection fails" do
      test_client = double("client")
      allow(test_client).to receive(:test_connection).and_raise(StandardError, "Unauthorized")

      with_server(agent_config: agent_config) do |server|
        allow(Clacky::Client).to receive(:new).and_return(test_client)

        payload = {
          model:    "bad-model",
          base_url: "https://api.example.com",
          api_key:  "sk-invalid",
          anthropic_format: false
        }
        req = fake_req(method: "POST", path: "/api/config/test", body: payload)
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["ok"]).to be false
        expect(body["message"]).to match(/Unauthorized/)
      end
    end

    it "uses stored key when masked placeholder is sent" do
      test_client = double("client")
      allow(test_client).to receive(:test_connection).and_return({ success: true })

      with_server(agent_config: agent_config) do |server|
        expect(Clacky::Client).to receive(:new) do |key, **|
          # Should receive the real stored key, not the masked one
          expect(key).to eq("sk-testkey1234567890abcd")
          test_client
        end

        payload = {
          index:    0,
          model:    "test-model",
          base_url: "https://api.example.com",
          api_key:  "sk-testke****abcd",  # masked
          anthropic_format: true
        }
        req = fake_req(method: "POST", path: "/api/config/test", body: payload)
        res = fake_res
        dispatch(server, req, res)

        expect(parsed_body(res)["ok"]).to be true
      end
    end
  end

  # ── 404 for unknown routes ────────────────────────────────────────────────

  describe "unknown routes" do
    it "returns 404 for an unrecognised path" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/does-not-exist")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(404)
      end
    end
  end

  # ── GET /api/sessions/:id/skills ─────────────────────────────────────────

  describe "GET /api/sessions/:id/skills" do
    it "returns 404 when the session does not exist" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/sessions/nonexistent/skills")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(404)
        expect(parsed_body(res)["error"]).to match(/not found/i)
      end
    end

    it "returns profile-filtered user_invocable skills for a session" do
      with_server(agent_config: agent_config) do |server|
        # Create a session
        create_req = fake_req(method: "POST", path: "/api/sessions",
                              body: { name: "skill-test-session", profile: "general" })
        create_res = fake_res
        dispatch(server, create_req, create_res)
        session_id = parsed_body(create_res)["session"]["id"]

        # Mock the agent's skill_loader and agent_profile
        session_data = server.instance_variable_get(:@registry).get(session_id)
        agent        = session_data[:agent]

        mock_skill = instance_double(Clacky::Skill,
          identifier:           "recall-memory",
          description:          "Recall memories",
          description_zh:       nil,
          name_zh:              nil,
          context_description:  "Recall memories",
          user_invocable?:      true,
          disabled?:            false,
          allowed_for_agent?:   true,
          encrypted?:           false
        )
        allow(mock_skill).to receive(:allowed_for_agent?).with(anything).and_return(true)

        mock_loader = instance_double(Clacky::SkillLoader,
          load_all:              nil,
          user_invocable_skills: [mock_skill],
          loaded_from:           { "recall-memory" => "user" }
        )
        allow(agent).to receive(:skill_loader).and_return(mock_loader)

        req = fake_req(method: "GET", path: "/api/sessions/#{session_id}/skills")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body).to have_key("skills")
        expect(body["skills"]).to be_an(Array)
        expect(body["skills"].first["name"]).to eq("recall-memory")
      end
    end
  end

  # ── mask_api_key helper ───────────────────────────────────────────────────

  describe "#mask_api_key (private)" do
    subject(:server) do
      described_class.new(agent_config: agent_config, client_factory: -> {})
    end

    it "masks a normal key showing first 8 and last 4 chars" do
      result = server.send(:mask_api_key, "sk-testkey1234567890abcd")
      expect(result).to start_with("sk-testk")
      expect(result).to end_with("abcd")
      expect(result).to include("****")
    end

    it "returns empty string for nil key" do
      expect(server.send(:mask_api_key, nil)).to eq("")
    end

    it "returns empty string for empty key" do
      expect(server.send(:mask_api_key, "")).to eq("")
    end

    it "masks short keys (≤12 chars) so plaintext never leaks" do
      # Regression: old implementation returned short keys verbatim, which
      # leaked them in GET /api/config and bypassed the frontend's
      # "contains ****" detection for masked values.
      result = server.send(:mask_api_key, "short")
      expect(result).to include("****")
      expect(result).not_to eq("short")
    end
  end

  # ── interrupt_all_agents (private) ───────────────────────────────────────
  #
  # Worker shutdown path. The `:interrupted` rescue branch in run_agent_task
  # (http_server.rb) is what writes session JSON on a clean Thread#raise. When
  # the agent thread refuses to die in 2s, interrupt_all_agents must fall back
  # to a manual save so the in-flight @history isn't lost.

  describe "#interrupt_all_agents (private)" do
    let(:sessions_dir) { Dir.mktmpdir("clacky_interrupt_spec_sessions") }

    after { FileUtils.rm_rf(sessions_dir) }

    def build_server
      described_class.new(
        agent_config:   agent_config,
        client_factory: -> { double("client") },
        sessions_dir:   sessions_dir
      )
    end

    # Stand-in for Clacky::Agent. We only need the surface that
    # interrupt_all_agents touches: cancel! and to_session_data.
    def fake_agent(session_id)
      a = double("Agent[#{session_id}]", session_id: session_id)
      cancelled_ref = [false]
      allow(a).to receive(:cancel!) { cancelled_ref[0] = true }
      allow(a).to receive(:cancelled?) { cancelled_ref[0] }
      allow(a).to receive(:to_session_data) do |status: nil, error_message: nil|
        { session_id: session_id, created_at: Time.now.iso8601, name: "T", last_status: status&.to_s }
      end
      a
    end

    # Spawn an agent-like thread that mimics run_agent_task's rescue block.
    # Crucially, waits until the thread is sleeping inside the begin scope
    # before returning — otherwise Thread#raise can fire before the rescue
    # handler is established, and the thread dies with an unhandled exception.
    def spawn_interruptible_agent_thread(&work)
      ready = Queue.new
      t = Thread.new do
        Thread.current.report_on_exception = false
        begin
          ready << :in_rescue_scope
          (work || -> { sleep 5 }).call
        rescue Clacky::AgentInterrupted
          :exited_cleanly
        end
      end
      ready.pop
      # Spin until the thread is actually blocked in sleep (not just past `ready << ...`).
      sleep 0.005 until t.status == "sleep"
      t
    end

    # Spawn a thread that swallows Thread#raise so interrupt_all_agents'
    # join(2) is forced to time out and exercise the manual-save fallback.
    def spawn_uninterruptible_thread
      ready = Queue.new
      t = Thread.new do
        Thread.current.report_on_exception = false
        Thread.handle_interrupt(Exception => :never) do
          ready << :in_handle_interrupt
          sleep 10
        end
      end
      ready.pop
      sleep 0.005 until t.status == "sleep"
      t
    end

    it "does not manual-save sessions whose threads exit within 2s" do
      server   = build_server
      registry = server.instance_variable_get(:@registry)
      agent    = fake_agent("clean-1")

      registry.create(session_id: "clean-1")
      thread = spawn_interruptible_agent_thread
      registry.with_session("clean-1") { |s| s[:agent] = agent; s[:thread] = thread }

      expect(agent).not_to receive(:to_session_data)

      server.send(:interrupt_all_agents)

      # Thread should be gone shortly after the raise.
      expect(thread.join(1)).to eq(thread)
    end

    it "falls back to manual save when a thread refuses to die in 2s" do
      server   = build_server
      registry = server.instance_variable_get(:@registry)
      sm       = server.instance_variable_get(:@session_manager)
      agent    = fake_agent("stuck-1")

      registry.create(session_id: "stuck-1")
      stuck_thread = spawn_uninterruptible_thread
      registry.with_session("stuck-1") { |s| s[:agent] = agent; s[:thread] = stuck_thread }

      expect(sm).to receive(:save).with(hash_including(session_id: "stuck-1")).once

      server.send(:interrupt_all_agents)

      stuck_thread.kill
      stuck_thread.join
    end

    it "sets the agent cancel flag before raising on the thread" do
      server   = build_server
      registry = server.instance_variable_get(:@registry)
      agent    = fake_agent("cancel-1")

      registry.create(session_id: "cancel-1")
      thread = spawn_interruptible_agent_thread
      registry.with_session("cancel-1") { |s| s[:agent] = agent; s[:thread] = thread }

      server.send(:interrupt_all_agents)

      expect(agent).to have_received(:cancel!)
      thread.join(1)
    end

    it "waits in parallel — total wall time is bounded by per-thread timeout, not N × timeout" do
      server   = build_server
      registry = server.instance_variable_get(:@registry)
      sm       = server.instance_variable_get(:@session_manager)

      # Three unresponsive threads — serial would take ≥ 6s, parallel ≈ 2s.
      stuck_threads = []
      3.times do |i|
        sid   = "stuck-#{i}"
        agent = fake_agent(sid)
        registry.create(session_id: sid)
        t = spawn_uninterruptible_thread
        registry.with_session(sid) { |s| s[:agent] = agent; s[:thread] = t }
        stuck_threads << t
      end

      allow(sm).to receive(:save)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      server.send(:interrupt_all_agents)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 3.5

      stuck_threads.each(&:kill)
      stuck_threads.each(&:join)
    end
  end
end
