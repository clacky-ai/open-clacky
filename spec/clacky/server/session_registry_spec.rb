# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "time"

require "clacky/session_manager"
require "clacky/server/session_registry"

# Targeted specs for SessionRegistry#snapshot — the O(1) single-session
# counterpart to #list used by the WS layer when pushing a fresh snapshot
# to a client that just (re)subscribed.
RSpec.describe Clacky::Server::SessionRegistry do
  # Helper: materialize a minimal-but-valid session JSON on disk so
  # session_manager.load / all_sessions can read it back.
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
        registry = described_class.new(session_manager: manager)

        from_list     = registry.list.find { |s| s[:id] == "sess_abcdef01" }
        from_snapshot = registry.snapshot("sess_abcdef01")

        expect(from_snapshot).not_to be_nil
        # Keys must match 1:1 so the frontend's session_update handler can
        # patch from either source interchangeably.
        expect(from_snapshot.keys.sort).to eq(from_list.keys.sort)
        expect(from_snapshot).to eq(from_list)
      end
    end

    it "returns nil for an unknown session id" do
      Dir.mktmpdir("clacky_snapshot_spec") do |dir|
        manager  = Clacky::SessionManager.new(sessions_dir: dir)
        registry = described_class.new(session_manager: manager)
        expect(registry.snapshot("does_not_exist")).to be_nil
      end
    end

    it "marks offline sessions as 'idle' (no live agent => string status)" do
      Dir.mktmpdir("clacky_snapshot_spec") do |dir|
        write_session_file(dir, session_id: "sess_offline", name: "off",
                           created_at: "2026-04-01T00:00:00+00:00")

        manager  = Clacky::SessionManager.new(sessions_dir: dir)
        registry = described_class.new(session_manager: manager)

        snap = registry.snapshot("sess_offline")
        expect(snap[:status]).to eq("idle")
        expect(snap[:error]).to be_nil
        # Field types the frontend relies on
        expect(snap[:total_tasks]).to be_a(Integer)
        expect(snap[:total_cost]).to be_a(Numeric)
        expect(snap[:cost_source]).to be_a(String)
      end
    end
  end
end
