# frozen_string_literal: true

require "spec_helper"
require "clacky/utils/arguments_parser"

RSpec.describe Clacky::Utils::ArgumentsParser do
  let(:tool_registry) do
    registry = instance_double("Clacky::ToolRegistry")
    
    # Mock a tool with required and optional parameters
    tool = double("Tool",
      name: "file_reader",
      description: "Read contents of a file",
      parameters: {
        required: ["path"],
        properties: {
          "path" => { description: "File path" },
          "start_line" => { description: "Start line number" },
          "end_line" => { description: "End line number" },
          "max_lines" => { description: "Maximum lines to read" }
        }
      }
    )
    
    allow(registry).to receive(:get).with("file_reader").and_return(tool)
    registry
  end

  describe ".parse_and_validate" do
    context "with valid JSON" do
      it "parses and validates correctly" do
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb", "start_line": 10, "end_line": 20}'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(10)
        expect(result[:end_line]).to eq(20)
      end

      it "filters out unknown parameters" do
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb", "unknown_param": "value"}'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result).not_to have_key(:unknown_param)
      end
    end

    context "with XML contamination" do
      it "repairs JSON contaminated with XML closing tags" do
        # Simulates: {"path": "test.rb", "start_line":10</parameter>, "end_line": 20}
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb", "start_line":10</parameter>, "end_line": 20}'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(10)
        expect(result[:end_line]).to eq(20)
      end

      it "repairs JSON with XML parameter tags and newlines" do
        # Simulates: {"path": "test.rb", "start_line":315</parameter>\n<parameter name="end_line"> 330}
        # Using double quotes to allow \n to be interpreted as newline
        call = {
          name: "file_reader",
          arguments: "{\"path\": \"test.rb\", \"start_line\":315</parameter>\n<parameter name=\"end_line\"> 330}"
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(315)
        expect(result[:end_line]).to eq(330)
      end

      it "handles real-world example from error log" do
        # Actual example from session log
        call = {
          name: "file_reader",
          arguments: "{\"path\": \"lib/clacky/ui2/components/modal_component.rb\", \"start_line\":315</parameter>\n<parameter name=\"end_line\": 330}"
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("lib/clacky/ui2/components/modal_component.rb")
        expect(result[:start_line]).to eq(315)
        expect(result[:end_line]).to eq(330)
      end

      it "removes multiple XML tags" do
        call = {
          name: "file_reader",
          arguments: "{\"path\": \"test.rb\"</parameter>\n<parameter name=\"start_line\"> 10</parameter>\n<parameter name=\"end_line\"> 20}"
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(10)
        expect(result[:end_line]).to eq(20)
      end
    end

    context "with incomplete JSON" do
      it "completes unclosed braces" do
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb"'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
      end

      it "handles truncated JSON with missing closing brace" do
        # Note: Completing unclosed strings in the middle of JSON is complex
        # and rarely happens in practice. We focus on missing closing braces.
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb", "start_line": 10'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(10)
      end

      it "handles literal backslash-n instead of real newline (session JSON format)" do
        # Real-world case from session 2026-04-10-11-45-34-b8099a0e.json line 821
        # When session JSON is saved/loaded, newlines become literal \n (backslash+n)
        # AND successfully parsed JSON may have malformed keys containing XML tags
        call = {
          name: "file_reader",
          arguments: '{"end_line\":550</parameter>\n<parameter name=\"path":"openclacky/lib/clacky/web/index.html","start_line":400}'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:end_line]).to eq(550)
        expect(result[:path]).to eq("openclacky/lib/clacky/web/index.html")
        expect(result[:start_line]).to eq(400)
      end
    end

    context "with missing required parameters" do
      it "raises error for missing required params" do
        call = {
          name: "file_reader",
          arguments: '{"start_line": 10}'
        }
        
        expect {
          described_class.parse_and_validate(call, tool_registry)
        }.to raise_error(Clacky::Utils::MissingRequiredParamsError, /Missing required parameters: path/)
      end
    end

    context "with completely invalid JSON" do
      it "raises helpful error" do
        call = {
          name: "file_reader",
          arguments: 'totally invalid {][ json'
        }
        
        expect {
          described_class.parse_and_validate(call, tool_registry)
        }.to raise_error(StandardError, /Failed to parse arguments.*file_reader/)
      end
    end
  end

  describe ".repair_json (private method)" do
    it "is tested indirectly through parse_and_validate" do
      # The repair_json method is private, so we test it through the public interface
      # All the XML contamination tests above exercise this method
      expect(true).to be true
    end
  end
end
