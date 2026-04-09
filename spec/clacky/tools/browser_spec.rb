# frozen_string_literal: true

require "spec_helper"
require "clacky/tools/browser"

RSpec.describe Clacky::Tools::Browser do
  let(:tool) { described_class.new }

  # ---------------------------------------------------------------------------
  # compress_snapshot
  # ---------------------------------------------------------------------------
  describe "#compress_snapshot" do
    let(:snapshot_with_noise) do
      <<~SNAP
        - document:
          - heading "Example" [ref=e1]
          - link "Learn more" [ref=e2]:
            - /url: https://example.com/path
          - textbox "Email" [ref=e3]:
            - /placeholder: you@example.com
          - img
          - img "Logo"
          - button "Submit" [ref=e4]
      SNAP
    end

    subject(:compressed) { tool.send(:compress_snapshot, snapshot_with_noise) }

    it "removes /url: lines" do
      expect(compressed).not_to include("/url:")
    end

    it "removes /placeholder: lines" do
      expect(compressed).not_to include("/placeholder:")
    end

    it "removes bare img lines" do
      expect(compressed.lines.map(&:strip)).not_to include("- img")
    end

    it "keeps img lines with alt text" do
      expect(compressed).to include('img "Logo"')
    end

    it "keeps ref anchors" do
      %w[e1 e2 e3 e4].each { |r| expect(compressed).to include("[ref=#{r}]") }
    end

    it "appends compression note" do
      expect(compressed).to include("[snapshot compressed:")
    end

    it "returns unchanged output when nothing to remove" do
      plain = "- button \"Go\" [ref=e1]\n"
      expect(tool.send(:compress_snapshot, plain)).to eq(plain)
    end

    it "handles empty input" do
      expect(tool.send(:compress_snapshot, "")).to eq("")
    end
  end

  # ---------------------------------------------------------------------------
  # build_ai_snapshot
  # ---------------------------------------------------------------------------
  describe "#build_ai_snapshot" do
    let(:snapshot_node) do
      {
        "id"   => "root",
        "role" => "document",
        "name" => "Example",
        "children" => [
          { "id" => "btn-1", "role" => "button",  "name" => "Continue" },
          { "id" => "txt-1", "role" => "textbox", "name" => "Email",
            "value" => "user@example.com" }
        ]
      }
    end

    subject(:output) { tool.send(:build_ai_snapshot, snapshot_node) }

    it "renders button ref" do
      expect(output).to include('- button "Continue" [ref=btn-1]')
    end

    it "renders textbox ref with value" do
      expect(output).to include('- textbox "Email" [ref=txt-1] value="user@example.com"')
    end

    it "renders the root document role" do
      expect(output).to include("- document")
    end

    context "with interactive: true" do
      subject(:output) { tool.send(:build_ai_snapshot, snapshot_node, interactive: true) }

      it "includes button" do
        expect(output).to include("button")
      end

      it "includes textbox" do
        expect(output).to include("textbox")
      end

      it "excludes non-interactive document role" do
        expect(output).not_to include("- document")
      end
    end

    context "with max_depth: 0" do
      subject(:output) { tool.send(:build_ai_snapshot, snapshot_node, max_depth: 0) }

      it "only shows the root node" do
        expect(output).to include("- document")
        expect(output).not_to include("button")
      end
    end

    it "handles nil/empty node gracefully" do
      expect(tool.send(:build_ai_snapshot, nil)).to eq("")
      expect(tool.send(:build_ai_snapshot, {})).to eq("")
    end
  end

  # ---------------------------------------------------------------------------
  # MCP response extractors
  # ---------------------------------------------------------------------------
  describe "#extract_pages" do
    it "extracts pages from structuredContent" do
      result = {
        "structuredContent" => {
          "pages" => [
            { "id" => 1, "url" => "https://example.com", "selected" => true },
            { "id" => 2, "url" => "https://other.com",   "selected" => false }
          ]
        }
      }
      pages = tool.send(:extract_pages, result)
      expect(pages.size).to eq(2)
      expect(pages.first[:id]).to eq(1)
      expect(pages.first[:url]).to eq("https://example.com")
      expect(pages.first[:selected]).to be true
    end

    it "falls back to text content parsing" do
      result = {
        "content" => [
          { "type" => "text", "text" => "1: https://example.com [selected]\n2: https://other.com" }
        ]
      }
      pages = tool.send(:extract_pages, result)
      expect(pages.size).to eq(2)
      expect(pages.first[:url]).to eq("https://example.com")
      expect(pages.first[:selected]).to be true
    end

    it "returns empty array for nil/empty" do
      expect(tool.send(:extract_pages, nil)).to eq([])
      expect(tool.send(:extract_pages, {})).to eq([])
    end
  end

  describe "#extract_snapshot" do
    it "extracts snapshot from structuredContent" do
      node = { "id" => "root", "role" => "document" }
      result = { "structuredContent" => { "snapshot" => node } }
      expect(tool.send(:extract_snapshot, result)).to eq(node)
    end

    it "returns empty hash for missing snapshot" do
      expect(tool.send(:extract_snapshot, {})).to eq({})
    end
  end

  # ---------------------------------------------------------------------------
  # format_result_for_llm
  # ---------------------------------------------------------------------------
  describe "#format_result_for_llm" do
    it "returns error result unchanged" do
      result = { error: "something went wrong" }
      expect(tool.format_result_for_llm(result)).to eq(result)
    end

    it "compresses snapshot output" do
      output = "- link \"X\" [ref=e1]:\n  - /url: https://example.com\n"
      result = { action: "snapshot", success: true, output: output, profile: "user" }
      formatted = tool.format_result_for_llm(result)
      expect(formatted[:stdout]).not_to include("/url:")
    end

    it "does not compress non-snapshot output" do
      result = { action: "open", success: true, output: "Opened: https://x.com", profile: "user" }
      formatted = tool.format_result_for_llm(result)
      expect(formatted[:stdout]).to eq("Opened: https://x.com")
    end

    it "includes action and success fields" do
      result = { action: "tabs", success: true, output: "1: https://x.com", profile: "user" }
      formatted = tool.format_result_for_llm(result)
      expect(formatted[:action]).to eq("tabs")
      expect(formatted[:success]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # format_tabs
  # ---------------------------------------------------------------------------
  describe "#format_tabs" do
    it "formats tab list" do
      pages = [
        { id: 1, url: "https://example.com", selected: true },
        { id: 2, url: "https://other.com",   selected: false }
      ]
      output = tool.send(:format_tabs, pages)
      expect(output).to include("1: https://example.com [selected]")
      expect(output).to include("2: https://other.com")
    end

    it "returns message for empty tabs" do
      expect(tool.send(:format_tabs, [])).to eq("No open tabs.")
    end
  end

  # ---------------------------------------------------------------------------
  # parameter helpers
  # ---------------------------------------------------------------------------
  describe "#require_url" do
    it "returns url when present" do
      expect(tool.send(:require_url, { url: "https://example.com" })).to eq("https://example.com")
    end

    it "returns error hash when missing" do
      result = tool.send(:require_url, {})
      expect(result).to be_a(Hash)
      expect(result[:error]).to match(/url is required/)
    end
  end

  describe "#require_ref" do
    it "returns ref string when present" do
      expect(tool.send(:require_ref, "btn-1")).to eq("btn-1")
    end

    it "returns error hash when nil" do
      result = tool.send(:require_ref, nil)
      expect(result).to be_a(Hash)
      expect(result[:error]).to match(/ref is required/)
    end
  end

  # ---------------------------------------------------------------------------
  # truncate_output
  # ---------------------------------------------------------------------------
  describe "#truncate_output" do
    it "returns output unchanged when within limit" do
      out = "hello world"
      expect(tool.send(:truncate_output, out, 100)).to eq(out)
    end

    it "truncates long output with notice" do
      long_output = ("x" * 50 + "\n") * 100
      truncated = tool.send(:truncate_output, long_output, 200)
      expect(truncated.length).to be < long_output.length
      expect(truncated).to include("truncated")
    end
  end

  # ---------------------------------------------------------------------------
  # find_node_binary / chrome_mcp_available?
  # ---------------------------------------------------------------------------
  describe "#find_node_binary" do
    it "returns a string path or nil" do
      result = tool.send(:find_node_binary)
      expect(result).to satisfy { |r| r.nil? || (r.is_a?(String) && !r.empty?) }
    end

    it "returns a path to an executable file when found" do
      result = tool.send(:find_node_binary)
      if result
        expect(File.executable?(result)).to be true
      end
    end
  end

  describe "#node_error" do
    it "returns nil when node is installed and version is sufficient" do
      allow(tool).to receive(:node_major_version).and_return(22)
      expect(tool.send(:node_error)).to be_nil
    end

    it "returns an error hash when node is not installed" do
      allow(tool).to receive(:node_major_version).and_return(nil)
      result = tool.send(:node_error)
      expect(result).to be_a(Hash)
      expect(result[:error]).to include("Node.js")
      expect(result[:error]).to include("nodejs.org")
    end

    it "returns an error hash when node version is too old" do
      allow(tool).to receive(:node_major_version).and_return(18)
      result = tool.send(:node_error)
      expect(result).to be_a(Hash)
      expect(result[:error]).to include("版本过低")
      expect(result[:error]).to include("v18")
    end
  end

  # ---------------------------------------------------------------------------
  # Tool metadata
  # ---------------------------------------------------------------------------
  describe "tool metadata" do
    it "has correct tool_name" do
      expect(described_class.tool_name).to eq("browser")
    end

    it "has required action parameter" do
      required = described_class.tool_parameters[:required]
      expect(required).to include("action")
    end

    it "does not expose a profile parameter (always uses the user's real browser)" do
      expect(described_class.tool_parameters.dig(:properties, :profile)).to be_nil
    end
  end

end
