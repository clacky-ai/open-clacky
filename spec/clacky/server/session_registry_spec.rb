# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "time"

require "clacky/session_manager"
require "clacky/agent_config"
require "clacky/server/session_registry"

RSpec.describe Clacky::Server::SessionRegistry do
  let(:default_config) { Clacky::AgentConfig.new }

  def write_session_file(dir, session_id:, name:, created_at:, pinned: false)
    data = {
      session_id:    session_id,
      name:          name,
      created_at:    created_at,
      updated_at:    created_at,
      working_dir:   "/tmp",
      source:        "manual",
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

  describe "#snapshot" do
    it "returns a row with the same shape as #list for the given session" do
      Dir.mktmpdir("clacky_snapshot_spec") do |dir|
        write_session_file(dir, session_id: "sess_abcdef01", name: "my-session",
                           created_at: "2026-04-01T00:00:00+00:00")
        write_session_file(dir, session_id: "sess_ffffffff", name: "other",
                           created_at: "2026-04-02T00:00:00+00:00")

        manager  = Clacky::SessionManager.new(sessions_dir: dir)
        registry = described_class.new(session_manager: manager, agent_config: default_config)

        from_list     = registry.list.find { |s| s[:id] == "sess_abcdef01" }
        from_snapshot = registry.snapshot("sess_abcdef01")

        expect(from_snapshot).not_to be_nil
        expect(from_snapshot.keys.sort).to eq(from_list.keys.sort)
        expect(from_snapshot).to eq(from_list)
      end
    end

    it "returns nil for an unknown session id" do
      Dir.mktmpdir("clacky_snapshot_spec") do |dir|
        manager  = Clacky::SessionManager.new(sessions_dir: dir)
        registry = described_class.new(session_manager: manager, agent_config: default_config)
        expect(registry.snapshot("does_not_exist")).to be_nil
      end
    end

    it "marks offline sessions as 'idle' (no live agent => string status)" do
      Dir.mktmpdir("clacky_snapshot_spec") do |dir|
        write_session_file(dir, session_id: "sess_offline", name: "off",
                           created_at: "2026-04-01T00:00:00+00:00")

        manager  = Clacky::SessionManager.new(sessions_dir: dir)
        registry = described_class.new(session_manager: manager, agent_config: default_config)

        snap = registry.snapshot("sess_offline")
        expect(snap[:status]).to eq("idle")
        expect(snap[:error]).to be_nil
        expect(snap[:total_tasks]).to be_a(Integer)
        expect(snap[:total_cost]).to be_a(Numeric)
        expect(snap[:cost_source]).to be_a(String)
      end
    end
  end

  describe "#count_by_status" do
    it "counts sessions with the given status" do
      registry = described_class.new(agent_config: default_config)
      registry.create(session_id: "s1")
      registry.create(session_id: "s2")
      registry.update("s1", status: :running)

      expect(registry.count_by_status(:running)).to eq(1)
      expect(registry.count_by_status(:idle)).to eq(1)
    end
  end

  describe "#running_full?" do
    it "returns true when running count reaches default limit" do
      registry = described_class.new(agent_config: default_config)

      default_config.max_running_agents.times do |i|
        registry.create(session_id: "r#{i}")
        registry.update("r#{i}", status: :running)
      end

      expect(registry.running_full?).to be true
    end

    it "returns false when under the limit" do
      registry = described_class.new(agent_config: default_config)
      registry.create(session_id: "r0")
      registry.update("r0", status: :running)

      expect(registry.running_full?).to be false
    end

    it "respects agent_config max_running_agents" do
      config = Clacky::AgentConfig.new(max_running_agents: 2)
      registry = described_class.new(agent_config: config)

      2.times do |i|
        registry.create(session_id: "r#{i}")
        registry.update("r#{i}", status: :running)
      end

      expect(registry.running_full?).to be true
    end
  end

  describe "#evict_excess_idle!" do
    it "evicts oldest idle agents when exceeding default limit" do
      Dir.mktmpdir("clacky_evict_spec") do |dir|
        manager  = Clacky::SessionManager.new(sessions_dir: dir)
        registry = described_class.new(session_manager: manager, agent_config: default_config)

        agent_double = double("agent", to_session_data: {
          session_id: "x", messages: [], created_at: Time.now.iso8601
        })

        total = default_config.max_idle_agents + 3
        ids = total.times.map { |i| "evict_#{i}" }

        ids.each_with_index do |id, i|
          registry.create(session_id: id)
          registry.with_session(id) { |s| s[:agent] = agent_double }
          registry.update(id, status: :idle, updated_at: Time.now - (total - i))
        end

        expect(registry.count_by_status(:idle)).to eq(total)

        registry.evict_excess_idle!

        expect(registry.count_by_status(:idle)).to eq(default_config.max_idle_agents)

        ids.first(3).each do |id|
          expect(registry.exist?(id)).to be false
        end
        ids.last(default_config.max_idle_agents).each do |id|
          expect(registry.exist?(id)).to be true
        end
      end
    end

    it "respects agent_config max_idle_agents" do
      Dir.mktmpdir("clacky_evict_spec") do |dir|
        config = Clacky::AgentConfig.new(max_idle_agents: 2)
        manager  = Clacky::SessionManager.new(sessions_dir: dir)
        registry = described_class.new(session_manager: manager, agent_config: config)

        agent_double = double("agent", to_session_data: {
          session_id: "x", messages: [], created_at: Time.now.iso8601
        })

        4.times do |i|
          registry.create(session_id: "evict_#{i}")
          registry.with_session("evict_#{i}") { |s| s[:agent] = agent_double }
          registry.update("evict_#{i}", status: :idle, updated_at: Time.now - (4 - i))
        end

        registry.evict_excess_idle!
        expect(registry.count_by_status(:idle)).to eq(2)
      end
    end

    it "does not evict running agents" do
      registry = described_class.new(agent_config: default_config)
      agent_double = double("agent")

      (default_config.max_idle_agents + 2).times do |i|
        registry.create(session_id: "s#{i}")
        registry.with_session("s#{i}") { |s| s[:agent] = agent_double }
        registry.update("s#{i}", status: :running)
      end

      registry.evict_excess_idle!

      (default_config.max_idle_agents + 2).times do |i|
        expect(registry.exist?("s#{i}")).to be true
      end
    end
  end

  describe "#each_live_agent" do
    it "yields [id, agent, thread] only for sessions with an agent attached" do
      registry = described_class.new(agent_config: default_config)
      agent_a = double("agent_a")
      thread_a = double("thread_a")
      agent_b = double("agent_b")

      registry.create(session_id: "with_agent_a")
      registry.with_session("with_agent_a") { |s| s[:agent] = agent_a; s[:thread] = thread_a }

      registry.create(session_id: "with_agent_b")
      registry.with_session("with_agent_b") { |s| s[:agent] = agent_b }

      registry.create(session_id: "no_agent")  # agent stays nil

      seen = []
      registry.each_live_agent { |id, agent, thread| seen << [id, agent, thread] }

      expect(seen).to contain_exactly(
        ["with_agent_a", agent_a, thread_a],
        ["with_agent_b", agent_b, nil]
      )
    end

    it "yields nothing when no sessions have agents" do
      registry = described_class.new(agent_config: default_config)
      registry.create(session_id: "empty")

      seen = []
      registry.each_live_agent { |id, agent, thread| seen << [id, agent, thread] }

      expect(seen).to be_empty
    end
  end
end
