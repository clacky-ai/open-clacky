# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/server/scheduler"

RSpec.describe Clacky::Server::Scheduler do
  let(:tmpdir) { Dir.mktmpdir("clacky_scheduler_spec") }

  # Build a scheduler that uses tmpdir instead of ~/.clacky
  subject(:scheduler) do
    s = described_class.new(
      session_registry: nil,
      session_builder:  ->(**_) {},
      task_runner:      ->(_sid, _agent, &_blk) {}
    )
    stub_const("Clacky::Server::Scheduler::SCHEDULES_FILE", File.join(tmpdir, "schedules.yml"))
    stub_const("Clacky::Server::Scheduler::TASKS_DIR",      File.join(tmpdir, "tasks"))
    s
  end

  after { FileUtils.rm_rf(tmpdir) }

  # ── Task file helpers ────────────────────────────────────────────────────────

  describe "#write_task / #read_task / #list_tasks" do
    it "creates the tasks directory and writes a task file" do
      scheduler.write_task("daily_report", "Generate a daily report.")
      path = scheduler.task_file_path("daily_report")
      expect(File.exist?(path)).to be true
      expect(File.read(path)).to eq("Generate a daily report.")
    end

    it "reads back the content that was written" do
      scheduler.write_task("hello", "Hello, world!")
      expect(scheduler.read_task("hello")).to eq("Hello, world!")
    end

    it "raises when reading a task that does not exist" do
      expect { scheduler.read_task("nonexistent") }.to raise_error(/Task not found/)
    end

    it "lists all task names sorted alphabetically" do
      scheduler.write_task("beta",  "beta prompt")
      scheduler.write_task("alpha", "alpha prompt")
      expect(scheduler.list_tasks).to eq(%w[alpha beta])
    end

    it "returns an empty array when the tasks directory does not exist" do
      expect(scheduler.list_tasks).to eq([])
    end
  end

  # ── Schedule CRUD ────────────────────────────────────────────────────────────

  describe "#add_schedule / #schedules / #remove_schedule" do
    before { scheduler.write_task("daily_report", "prompt") }

    it "adds a schedule and persists it to YAML" do
      scheduler.add_schedule(name: "Morning", task: "daily_report", cron: "0 9 * * 1-5")
      schedules = scheduler.schedules
      expect(schedules.size).to eq(1)
      expect(schedules.first["name"]).to eq("Morning")
      expect(schedules.first["cron"]).to eq("0 9 * * 1-5")
    end

    it "replaces a schedule with the same name" do
      scheduler.add_schedule(name: "Morning", task: "daily_report", cron: "0 9 * * 1-5")
      scheduler.add_schedule(name: "Morning", task: "daily_report", cron: "0 8 * * *")
      schedules = scheduler.schedules
      expect(schedules.size).to eq(1)
      expect(schedules.first["cron"]).to eq("0 8 * * *")
    end

    it "removes a schedule by name and returns true" do
      scheduler.add_schedule(name: "Morning", task: "daily_report", cron: "0 9 * * *")
      result = scheduler.remove_schedule("Morning")
      expect(result).to be true
      expect(scheduler.schedules).to be_empty
    end

    it "returns false when removing a schedule that does not exist" do
      expect(scheduler.remove_schedule("nonexistent")).to be false
    end

    it "returns an empty array when schedules file does not exist" do
      expect(scheduler.schedules).to eq([])
    end
  end

  # ── Cron matching ────────────────────────────────────────────────────────────

  describe "cron expression matching (via #tick)" do
    # Use send to access private method for focused unit testing
    def matches?(expr, time)
      scheduler.send(:cron_matches?, expr, time)
    end

    it "matches wildcard *" do
      t = Time.new(2025, 1, 1, 9, 0)
      expect(matches?("* * * * *", t)).to be true
    end

    it "matches exact values" do
      t = Time.new(2025, 6, 15, 9, 30)  # minute=30, hour=9, day=15, month=6, wday=0(Sun)
      expect(matches?("30 9 15 6 0", t)).to be true
      expect(matches?("31 9 15 6 0", t)).to be false
    end

    it "matches step expressions (*/15)" do
      expect(matches?("*/15 * * * *", Time.new(2025, 1, 1, 0, 0))).to be true
      expect(matches?("*/15 * * * *", Time.new(2025, 1, 1, 0, 15))).to be true
      expect(matches?("*/15 * * * *", Time.new(2025, 1, 1, 0, 30))).to be true
      expect(matches?("*/15 * * * *", Time.new(2025, 1, 1, 0, 7))).to be false
    end

    it "matches range expressions (1-5)" do
      expect(matches?("0 9 * * 1-5", Time.new(2025, 3, 3, 9, 0))).to be true   # Monday
      expect(matches?("0 9 * * 1-5", Time.new(2025, 3, 8, 9, 0))).to be false  # Saturday
    end

    it "matches comma-separated lists" do
      expect(matches?("0 9,18 * * *", Time.new(2025, 1, 1, 9, 0))).to be true
      expect(matches?("0 9,18 * * *", Time.new(2025, 1, 1, 18, 0))).to be true
      expect(matches?("0 9,18 * * *", Time.new(2025, 1, 1, 12, 0))).to be false
    end

    it "returns false for malformed expressions" do
      expect(matches?("", Time.now)).to be false
      expect(matches?("* * *", Time.now)).to be false
    end
  end

  # ── start / stop ─────────────────────────────────────────────────────────────

  describe "#start and #stop" do
    it "starts and stops the background thread" do
      scheduler.start
      expect(scheduler.running?).to be true
      scheduler.stop
      expect(scheduler.running?).to be false
    end

    it "is idempotent — calling start twice does not raise" do
      scheduler.start
      expect { scheduler.start }.not_to raise_error
      scheduler.stop
    end
  end

  # ── fire_task delegates to task_runner ──────────────────────────────────────
  # Regression for: scheduled cron tasks didn't persist messages because the
  # scheduler spawned its own Thread and never called @session_manager.save.
  # Fix was to route all agent.run calls through the shared task_runner
  # (run_agent_task) that owns status/broadcast/save/idle_timer.
  describe "#fire_task" do
    let(:fake_agent)    { Object.new }
    let(:captured)      { {} }
    let(:fake_registry) do
      agent = fake_agent
      Object.new.tap do |r|
        r.define_singleton_method(:with_session) { |_sid, &blk| blk.call({ agent: agent }) }
        r.define_singleton_method(:update)      { |*_args, **_kw| }
      end
    end
    let(:session_builder) { ->(**_kw) { "session-abc" } }
    let(:task_runner) do
      ->(sid, agent, &blk) {
        captured[:session_id] = sid
        captured[:agent]      = agent
        captured[:block]      = blk
      }
    end
    let(:scheduler_with_runner) do
      s = described_class.new(
        session_registry: fake_registry,
        session_builder:  session_builder,
        task_runner:      task_runner
      )
      stub_const("Clacky::Server::Scheduler::SCHEDULES_FILE", File.join(tmpdir, "schedules.yml"))
      stub_const("Clacky::Server::Scheduler::TASKS_DIR",      File.join(tmpdir, "tasks"))
      s.write_task("my_task", "do the thing")
      s
    end

    it "delegates execution to task_runner instead of running agent.run itself" do
      scheduler_with_runner.send(:fire_task, { "name" => "Morning", "task" => "my_task", "cron" => "* * * * *" })

      expect(captured[:session_id]).to eq("session-abc")
      expect(captured[:agent]).to      eq(fake_agent)
      expect(captured[:block]).to      be_a(Proc)
    end

    it "does nothing when no agent is registered for the new session" do
      empty_registry = Object.new.tap do |r|
        r.define_singleton_method(:with_session) { |_sid, &blk| blk.call({ agent: nil }) }
        r.define_singleton_method(:update)      { |*_a, **_k| }
      end

      s = described_class.new(
        session_registry: empty_registry,
        session_builder:  session_builder,
        task_runner:      task_runner
      )
      stub_const("Clacky::Server::Scheduler::SCHEDULES_FILE", File.join(tmpdir, "schedules.yml"))
      stub_const("Clacky::Server::Scheduler::TASKS_DIR",      File.join(tmpdir, "tasks"))
      s.write_task("my_task", "x")

      s.send(:fire_task, { "name" => "M", "task" => "my_task", "cron" => "* * * * *" })
      expect(captured).to be_empty
    end
  end
end
