# frozen_string_literal: true

require "spec_helper"
require "clacky/cli"

# Tests for slash commands in UI2 interactive mode.
#
# Strategy: call run_agent_with_ui2 with a fake UIController that captures
# the on_input block, then trigger the block manually with each slash command.
# This avoids starting a real TUI while still exercising the exact routing
# logic that ships in production.
RSpec.describe Clacky::CLI, "UI2 slash commands" do
  let(:cli) { Clacky::CLI.new }
  let(:working_dir) { Dir.pwd }
  let(:agent_config) { Clacky::AgentConfig.new }
  let(:client) { instance_double(Clacky::Client) }
  # client_factory is the new contract: a zero-arg lambda the CLI calls whenever
  # it needs a Client. Must reflect *current* agent_config state.
  let(:client_factory) { -> { client } }

  # Fake UIController: stores registered callbacks so tests can invoke them.
  let(:ui_controller) do
    double("UIController").tap do |ui|
      allow(ui).to receive(:on_mode_toggle)
      allow(ui).to receive(:on_time_machine)
      allow(ui).to receive(:on_interrupt)
      allow(ui).to receive(:on_input) { |&block| @input_handler = block }
      allow(ui).to receive(:set_skill_loader)
      allow(ui).to receive(:initialize_and_show_banner)
      allow(ui).to receive(:start_input_loop)  # blocks in real code — no-op here
      allow(ui).to receive(:update_sessionbar)
    end
  end

  # Fake layout used by /clear
  let(:layout) do
    double("Layout").tap { |l| allow(l).to receive(:clear_output) }
  end

  let(:agent_profile) { instance_double(Clacky::AgentProfile, name: "coding") }
  let(:skill_loader) { instance_double(Clacky::SkillLoader) }

  let(:agent) do
    instance_double(Clacky::Agent,
      skill_loader: skill_loader,
      agent_profile: agent_profile,
      total_tasks: 0,
      total_cost: 0.0)
  end

  # Trigger the registered on_input block with a given command string.
  def send_input(command)
    @input_handler.call(command, [])
  end

  before do
    # Bypass brand check and terminal detection
    allow(cli).to receive(:check_brand_license_cli)
    allow(Clacky::UI2::TerminalDetector).to receive(:detect_dark_background).and_return(true)
    allow(Clacky::UI2::ThemeManager.instance).to receive(:set_background_mode)
    allow(Clacky::UI2::ThemeManager).to receive(:available_themes).and_return(%i[hacker minimal])

    # Return our fake UIController instead of building a real one
    allow(Clacky::UI2::UIController).to receive(:new).and_return(ui_controller)

    # Inject fake UI into agent (the real code calls instance_variable_set)
    allow(agent).to receive(:instance_variable_set)

    # Run the method — start_input_loop is a no-op so it returns immediately
    cli.send(:run_agent_with_ui2, agent, working_dir, agent_config, nil, client_factory)
  end

  # ── /help ──────────────────────────────────────────────────────────────────
  describe "/help" do
    it "calls show_help on the UI controller" do
      allow(ui_controller).to receive(:show_help)
      expect(ui_controller).to receive(:show_help).once
      send_input("/help")
    end
  end

  # ── /clear ─────────────────────────────────────────────────────────────────
  describe "/clear" do
    let(:new_agent) do
      instance_double(Clacky::Agent, total_tasks: 0, total_cost: 0.0)
    end

    before do
      allow(ui_controller).to receive(:layout).and_return(layout)
      allow(ui_controller).to receive(:show_info)
      allow(ui_controller).to receive(:update_todos)
      allow(Clacky::SessionManager).to receive(:generate_id).and_return("fresh-session-id")
      allow(Clacky::Agent).to receive(:new).and_return(new_agent)
      allow(new_agent).to receive(:instance_variable_set)
    end

    it "creates a new Agent with a fresh session_id" do
      expect(Clacky::Agent).to receive(:new).with(
        client, agent_config,
        working_dir: working_dir,
        ui: ui_controller,
        profile: agent_profile.name,
        session_id: "fresh-session-id",
        source: :manual
      ).and_return(new_agent)
      send_input("/clear")
    end

    it "clears the output area" do
      expect(layout).to receive(:clear_output)
      send_input("/clear")
    end

    it "shows a confirmation message" do
      expect(ui_controller).to receive(:show_info).with(a_string_including("cleared"))
      send_input("/clear")
    end

    it "resets the session bar to zero" do
      expect(ui_controller).to receive(:update_sessionbar).with(tasks: 0, cost: 0.0)
      send_input("/clear")
    end

    it "clears the todo display" do
      expect(ui_controller).to receive(:update_todos).with([])
      send_input("/clear")
    end
  end

  # ── /exit and /quit ────────────────────────────────────────────────────────
  describe "/exit" do
    it "stops the UI and exits" do
      allow(ui_controller).to receive(:stop)
      expect(ui_controller).to receive(:stop)
      expect { send_input("/exit") }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end
  end

  describe "/quit" do
    it "stops the UI and exits (alias for /exit)" do
      allow(ui_controller).to receive(:stop)
      expect(ui_controller).to receive(:stop)
      expect { send_input("/quit") }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end
  end

  # ── /undo ──────────────────────────────────────────────────────────────────
  describe "/undo" do
    it "delegates to handle_time_machine_command" do
      expect(cli).to receive(:handle_time_machine_command).with(ui_controller, agent, nil)
      send_input("/undo")
    end
  end

  # ── /config ────────────────────────────────────────────────────────────────
  describe "/config" do
    it "delegates to handle_config_command without the client param (agent owns its client)" do
      expect(cli).to receive(:handle_config_command).with(ui_controller, agent_config, agent)
      send_input("/config")
    end
  end
end
