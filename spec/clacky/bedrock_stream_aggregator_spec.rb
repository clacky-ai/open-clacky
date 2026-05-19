# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Clacky::BedrockStreamAggregator do
  it "assembles a text-only stream into a Bedrock-shaped response" do
    progress_events = []
    agg = described_class.new(on_chunk: ->(input_tokens:, output_tokens:) {
      progress_events << [input_tokens, output_tokens]
    })

    agg.handle("messageStart", { role: "assistant" }.to_json)
    agg.handle("contentBlockStart", { contentBlockIndex: 0, start: {} }.to_json)
    agg.handle("contentBlockDelta", { contentBlockIndex: 0, delta: { text: "Hello " } }.to_json)
    agg.handle("contentBlockDelta", { contentBlockIndex: 0, delta: { text: "world" } }.to_json)
    agg.handle("contentBlockStop", { contentBlockIndex: 0 }.to_json)
    agg.handle("messageStop", { stopReason: "end_turn" }.to_json)
    agg.handle("metadata", {
      usage: { inputTokens: 10, outputTokens: 2, cacheReadInputTokens: 0, cacheWriteInputTokens: 0 }
    }.to_json)

    result = agg.to_h
    expect(result["output"]["message"]["role"]).to eq("assistant")
    expect(result["output"]["message"]["content"]).to eq([{ "text" => "Hello world" }])
    expect(result["stopReason"]).to eq("end_turn")
    expect(result["usage"]["inputTokens"]).to eq(10)
    # Streaming deltas emit incremental output-token estimates (chars/4),
    # then the final metadata frame emits the authoritative usage numbers.
    expect(progress_events.last).to eq([10, 2])
    expect(progress_events[0..-2]).to all(satisfy { |inp, out| inp == 0 && out > 0 })
  end

  it "concatenates streamed tool_use input fragments and parses final JSON" do
    agg = described_class.new

    agg.handle("messageStart", { role: "assistant" }.to_json)
    agg.handle("contentBlockStart", {
      contentBlockIndex: 0,
      start: { toolUse: { toolUseId: "tu_1", name: "shell" } }
    }.to_json)
    agg.handle("contentBlockDelta", {
      contentBlockIndex: 0,
      delta: { toolUse: { input: '{"command":"echo' } }
    }.to_json)
    agg.handle("contentBlockDelta", {
      contentBlockIndex: 0,
      delta: { toolUse: { input: ' hi"}' } }
    }.to_json)
    agg.handle("contentBlockStop", { contentBlockIndex: 0 }.to_json)
    agg.handle("messageStop", { stopReason: "tool_use" }.to_json)

    block = agg.to_h["output"]["message"]["content"].first
    expect(block["toolUse"]["toolUseId"]).to eq("tu_1")
    expect(block["toolUse"]["name"]).to eq("shell")
    expect(block["toolUse"]["input"]).to eq("command" => "echo hi")
  end

  it "is robust to unparseable JSON payloads (drops them)" do
    agg = described_class.new
    expect { agg.handle("contentBlockDelta", "not json") }.not_to raise_error
    expect(agg.to_h["output"]["message"]["content"]).to eq([])
  end

  it "falls back to raw input string when tool_use JSON is incomplete" do
    agg = described_class.new
    agg.handle("contentBlockStart", {
      contentBlockIndex: 0,
      start: { toolUse: { toolUseId: "tu_x", name: "noop" } }
    }.to_json)
    agg.handle("contentBlockDelta", {
      contentBlockIndex: 0, delta: { toolUse: { input: "{not-json" } }
    }.to_json)

    block = agg.to_h["output"]["message"]["content"].first
    expect(block["toolUse"]["input"]).to eq("{not-json")
  end
end
