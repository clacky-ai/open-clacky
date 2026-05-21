# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/clacky/rich_ui_controller"

RSpec.describe Clacky::RichUIController do
  describe "layout" do
    it "uses the full body width for the transcript without a plan/tasks sidebar" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.shell.layout.calculate_dimensions(100, 30)

      expect(ui.shell.layout[:sidebar]).to be_nil
      expect(ui.shell.layout[:transcript].width).to eq(100)
      expect(ui.shell.layout.render).not_to include("Plan")
      expect(ui.shell.layout.render).not_to include("Tasks")
    end
  end

  describe "#stop" do
    it "clears the terminal when requested" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      expect(ui.shell).to receive(:stop)
      expect(RubyRich::Terminal).to receive(:clear)

      ui.stop(clear_screen: true)
    end
  end

  describe "#initialize_and_show_banner" do
    it "shows the full startup welcome banner" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.initialize_and_show_banner

      entry = ui.shell.transcript.store.entries.last
      expect(entry.type).to eq(:markdown)
      expect(entry.metadata[:plain]).to eq(true)
      expect(entry.content).to include("Your personal Assistant & Technical Co-founder")
      expect(entry.content).to include("AGENT MODE INITIALIZED")
      expect(entry.content).to include("[Working Directory]")
      expect(ui.shell.transcript.render.join("\n")).to include("[*] Ask questions")
      expect(entry.content).not_to eq("OpenClacky is ready.")
    end
  end

  describe "#show_assistant_message" do
    it "adds assistant content as markdown so RubyRich renders headings, lists, code, and tables" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.show_assistant_message(<<~MARKDOWN, files: [])
        <think>hidden reasoning</think>

        ## Result

        - `one`
        - **two**
      MARKDOWN

      entry = ui.shell.transcript.store.entries.last
      expect(entry.type).to eq(:markdown)
      expect(entry.content).to include("## Result")
      expect(entry.content).to include("- **two**")
      expect(entry.content).not_to include("hidden reasoning")
    end

    it "adds attached files as a compact markdown list" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.show_assistant_message("Done", files: [{ path: "README.md" }, { "name" => "notes.txt" }])

      entries = ui.shell.transcript.store.entries
      expect(entries.map(&:type)).to eq([:markdown, :markdown])
      expect(entries.last.content).to eq("**Files**\n\n- `README.md`\n- `notes.txt`")
    end

    it "wraps markdown table cells to fit the transcript content width" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.show_assistant_message(<<~MARKDOWN, files: [])
        | Column A | Column B | Column C |
        | --- | --- | --- |
        | veryveryveryveryveryverylong | another very very very long value | 中文中文中文中文中文中文 |
      MARKDOWN

      ui.shell.transcript.width = 40
      lines = ui.shell.transcript.render
      table_lines = lines.select { |line| line.gsub(/\e\[[0-9;:]*m/, "").include?("│") }

      expect(table_lines).not_to be_empty
      expect(table_lines.map { |line| visible_width(line) }.max).to be <= 39
    end

    it "does not stretch inline-code background across markdown table cell padding" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.show_assistant_message(<<~MARKDOWN, files: [])
        | Runtime | Detail |
        | --- | --- |
        | Async | `tokio` and `ratatui` |
      MARKDOWN

      ui.shell.transcript.width = 60
      rendered = ui.shell.transcript.render.join("\n")

      expect(rendered).to include("tokio")
      expect(rendered).not_to include("\e[47m")
      expect(rendered).not_to include("\e[37m")
    end
  end

  def visible_width(line)
    line.gsub(/\e\[[0-9;:]*m/, "").display_width
  end

  describe Clacky::RichUIController::ConfigMenuDialog do
    it "renders a selectable model configuration menu" do
      dialog = described_class.new(
        choices: [
          { label: "[default] deepseek-v4-pro (sk-31e...b5ee)", value: { action: :switch }, current: true },
          { label: "─" * 50, disabled: true },
          { label: "[+] Add New Model", value: { action: :add } },
          { label: "[*] Edit Current Model", value: { action: :edit } },
          { label: "[X] Close", value: { action: :close } }
        ],
        selected_index: 0
      )

      rendered = dialog.render_to_buffer.map { |line| line.compact.join }.join("\n")

      expect(rendered).to include("Model Configuration")
      expect(rendered).to include("➜")
      expect(rendered).to include("[+] Add New Model")
      expect(rendered).to include("[*] Edit Current Model")
      expect(rendered).to include("[X] Close")
      expect(rendered).to include("Enter: Select")
    end

    it "skips disabled separators when navigating" do
      dialog = described_class.new(
        choices: [
          { label: "first", value: { action: :switch } },
          { label: "─" * 50, disabled: true },
          { label: "[+] Add New Model", value: { action: :add } }
        ],
        selected_index: 0
      )

      dialog.move_down

      expect(dialog.selected_choice[:label]).to eq("[+] Add New Model")
    end
  end

  describe Clacky::RichUIController::FormDialog do
    it "edits fields and returns keyed values" do
      dialog = described_class.new(
        title: "Edit Model",
        fields: [
          { name: :api_key, label: "API Key:", default: "", mask: true },
          { name: :model, label: "Model:", default: "" }
        ]
      )

      dialog.notify_listeners(type: :key, name: :string, value: "secret")
      dialog.notify_listeners(type: :key, name: :tab)
      dialog.notify_listeners(type: :key, name: :string, value: "new-model")
      dialog.notify_listeners(type: :key, name: :enter)

      expect(dialog.wait).to eq(api_key: "secret", model: "new-model")
    end

    it "renders masked values without exposing the raw API key" do
      dialog = described_class.new(
        title: "Edit Model",
        fields: [{ name: :api_key, label: "API Key:", default: "sk-secret", mask: true }]
      )

      rendered = dialog.render_to_buffer.map { |line| line.compact.join }.join("\n")

      expect(rendered).to include("*********")
      expect(rendered).not_to include("sk-secret")
    end
  end
end
