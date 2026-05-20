# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::MessageFormat::Anthropic do
  describe ".build_request_body" do
    let(:model) { "claude-sonnet-4" }
    let(:tools) { [] }
    let(:max_tokens) { 1024 }

    it "parses well-formed tool_call arguments into structured input" do
      messages = [
        {
          role: "assistant",
          content: "",
          tool_calls: [
            {
              id: "call_1",
              function: { name: "shell", arguments: '{"cmd":"ls"}' }
            }
          ]
        }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      block = body[:messages].first[:content].find { |b| b[:type] == "tool_use" }

      expect(block[:input]).to eq({ "cmd" => "ls" })
    end

    # Regression: a previous task can leave a truncated/invalid `arguments`
    # string in session.json (upstream SSE cut mid-stream, oversized JSON, etc.).
    # Replaying that history must NOT crash the agent on startup — we degrade
    # to an empty input so the conversation can continue and the model can
    # self-correct from the tool_result that follows.
    it "degrades to empty input when tool_call arguments are truncated JSON" do
      truncated = '{"path":"/tmp/x.py","content":"print(\\"hi'
      messages = [
        {
          role: "assistant",
          content: "",
          tool_calls: [
            {
              id: "call_truncated",
              function: { name: "write", arguments: truncated }
            }
          ]
        }
      ]

      expect {
        body = described_class.build_request_body(messages, model, tools, max_tokens, false)
        block = body[:messages].first[:content].find { |b| b[:type] == "tool_use" }
        expect(block[:input]).to eq({})
        expect(block[:name]).to eq("write")
        expect(block[:id]).to eq("call_truncated")
      }.not_to raise_error
    end

    it "passes through pre-parsed Hash arguments without re-parsing" do
      messages = [
        {
          role: "assistant",
          content: "",
          tool_calls: [
            {
              id: "call_2",
              function: { name: "shell", arguments: { "cmd" => "ls" } }
            }
          ]
        }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      block = body[:messages].first[:content].find { |b| b[:type] == "tool_use" }

      expect(block[:input]).to eq({ "cmd" => "ls" })
    end
  end
end
