# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent, "#fork_subagent" do
  let(:config) do
    Clacky::AgentConfig.new(
      api_key: "test-key",
      base_url: "https://api.test.com",
      model: "claude-sonnet-4-5",
      anthropic_format: true
    )
  end
  
  let(:client) { instance_double(Clacky::Client) }
  let(:agent) { described_class.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id) }

  before do
    # Mock client to avoid actual API calls
    allow(Clacky::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_message).and_return({
      "id" => "msg_123",
      "content" => [{ "type" => "text", "text" => "Response" }],
      "usage" => { "input_tokens" => 100, "output_tokens" => 50 }
    })
  end

  describe "#fork_subagent" do
    it "creates a subagent with the same messages" do
      agent.instance_variable_set(:@messages, [
        { role: "system", content: "You are a helpful assistant" },
        { role: "user", content: "Hello" }
      ])

      subagent = agent.fork_subagent

      expect(subagent).to be_a(Clacky::Agent)
      expect(subagent.messages.length).to eq(2)
      expect(subagent.messages[0][:role]).to eq("system")
      expect(subagent.messages[1][:role]).to eq("user")
    end

    it "deep clones messages to avoid cross-contamination" do
      original_messages = [
        { role: "user", content: "Hello", metadata: { key: "value" } }
      ]
      agent.instance_variable_set(:@messages, original_messages)

      subagent = agent.fork_subagent

      # Modify subagent message
      subagent.messages[0][:content] = "Modified"
      subagent.messages[0][:metadata][:key] = "modified"

      # Parent should be unchanged
      expect(agent.messages[0][:content]).to eq("Hello")
      expect(agent.messages[0][:metadata][:key]).to eq("value")
    end

    it "appends system_prompt_suffix as user message followed by assistant acknowledgement" do
      agent.instance_variable_set(:@messages, [
        { role: "system", content: "System prompt" }
      ])

      subagent = agent.fork_subagent(
        system_prompt_suffix: "You are a code explorer."
      )

      # Should have 3 messages: system + user instructions + assistant ack
      expect(subagent.messages.length).to eq(3)

      # [1] user: subagent role/constraints
      expect(subagent.messages[1][:role]).to eq("user")
      expect(subagent.messages[1][:content]).to include("CRITICAL: TASK CONTEXT SWITCH")
      expect(subagent.messages[1][:content]).to include("You are a code explorer.")
      expect(subagent.messages[1][:system_injected]).to be true
      expect(subagent.messages[1][:subagent_instructions]).to be true

      # [2] assistant: acknowledgement — gives run() a clean [user] slot for the actual task
      expect(subagent.messages[2][:role]).to eq("assistant")
      expect(subagent.messages[2][:content]).to include("Understood")
      expect(subagent.messages[2][:system_injected]).to be true
    end

    it "registers hook to forbid tools" do
      subagent = agent.fork_subagent(
        forbidden_tools: ["write", "edit"]
      )

      # Simulate tool use hook
      hook_manager = subagent.instance_variable_get(:@hooks)
      result = hook_manager.trigger(:before_tool_use, { name: "write", arguments: "{}" })

      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to include("forbidden")
    end

    it "allows non-forbidden tools" do
      subagent = agent.fork_subagent(
        forbidden_tools: ["write", "edit"]
      )

      hook_manager = subagent.instance_variable_get(:@hooks)
      result = hook_manager.trigger(:before_tool_use, { name: "file_reader", arguments: "{}" })

      expect(result[:action]).to eq(:allow)
    end

    it "marks subagent with metadata" do
      agent.instance_variable_set(:@messages, [{ role: "user", content: "test" }])
      
      subagent = agent.fork_subagent

      expect(subagent.instance_variable_get(:@is_subagent)).to be true
      expect(subagent.instance_variable_get(:@parent_message_count)).to eq(1)
    end

    context "with model switching" do
      before do
        # Add multiple models to config
        config.add_model(
          model: "claude-haiku-3-5",
          api_key: "test-key",
          base_url: "https://api.test.com",
          anthropic_format: true
        )
      end

      it "switches to specified model" do
        subagent = agent.fork_subagent(model: "claude-haiku-3-5")

        subagent_config = subagent.instance_variable_get(:@config)
        expect(subagent_config.model_name).to eq("claude-haiku-3-5")
      end

      it "raises error for non-existent model" do
        expect {
          agent.fork_subagent(model: "non-existent-model")
        }.to raise_error(Clacky::AgentError, /not found in config/)
      end
    end
  end

  describe "#generate_subagent_summary" do
    it "generates summary from subagent execution" do
      # Set up parent agent with initial message
      agent.instance_variable_set(:@messages, [
        { role: "user", content: "Find all Ruby files" }
      ])
      
      subagent = agent.fork_subagent
      subagent.instance_variable_set(:@parent_message_count, 1)
      subagent.instance_variable_set(:@iterations, 3)
      subagent.instance_variable_set(:@total_cost, 0.0025)
      
      # Simulate subagent adding messages
      subagent.messages << {
        role: "assistant",
        content: "I found 5 files",
        tool_calls: [
          { name: "glob", arguments: "{}" },
          { name: "file_reader", arguments: "{}" }
        ]
      }

      summary = agent.generate_subagent_summary(subagent)

      expect(summary).to include("SUBAGENT SUMMARY")
      expect(summary).to include("3 iterations")
      expect(summary).to include("$0.0025")
      expect(summary).to include("glob, file_reader")
      expect(summary).to include("I found 5 files")
    end

    it "handles subagent with no response" do
      subagent = agent.fork_subagent
      subagent.instance_variable_set(:@parent_message_count, 0)
      subagent.instance_variable_set(:@iterations, 1)
      subagent.instance_variable_set(:@total_cost, 0.001)

      summary = agent.generate_subagent_summary(subagent)

      expect(summary).to include("SUBAGENT SUMMARY")
      expect(summary).to include("(No response)")
    end
  end

  describe "#deep_clone" do
    it "creates a deep copy of objects" do
      original = {
        key: "value",
        nested: { inner: "data" },
        array: [1, 2, { item: "test" }]
      }

      cloned = agent.send(:deep_clone, original)

      # Modify cloned object
      cloned[:key] = "modified"
      cloned[:nested][:inner] = "modified"
      cloned[:array][2][:item] = "modified"

      # Original should be unchanged
      expect(original[:key]).to eq("value")
      expect(original[:nested][:inner]).to eq("data")
      expect(original[:array][2][:item]).to eq("test")
    end
  end
end
