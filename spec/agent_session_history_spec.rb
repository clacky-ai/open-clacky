# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent session history" do
  describe "#get_recent_user_messages" do
    let(:client) { instance_double(Clacky::Client) }
    let(:config) { Clacky::AgentConfig.new }
    let(:agent) { Clacky::Agent.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id) }

    before do
      # Simulate a conversation with multiple user/assistant exchanges
      agent.instance_variable_set(:@messages, [
        { role: "system", content: "System prompt" },
        { role: "user", content: "First user message" },
        { role: "assistant", content: "First assistant response" },
        { role: "user", content: "Second user message" },
        { role: "assistant", content: "Second assistant response" },
        { role: "user", content: "Third user message" },
        { role: "assistant", content: "Third assistant response" },
        { role: "user", content: "Fourth user message" },
        { role: "assistant", content: "Fourth assistant response" },
        { role: "user", content: "Fifth user message" },
        { role: "assistant", content: "Fifth assistant response" },
        { role: "user", content: "Sixth user message" }
      ])
    end

    it "returns the last 5 user messages by default" do
      messages = agent.get_recent_user_messages(limit: 5)
      
      expect(messages.size).to eq(5)
      expect(messages).to eq([
        "Second user message",
        "Third user message",
        "Fourth user message",
        "Fifth user message",
        "Sixth user message"
      ])
    end

    it "returns all user messages when limit exceeds message count" do
      messages = agent.get_recent_user_messages(limit: 100)
      
      expect(messages.size).to eq(6)
      expect(messages.first).to eq("First user message")
      expect(messages.last).to eq("Sixth user message")
    end

    it "handles empty messages array" do
      agent.instance_variable_set(:@messages, [])
      messages = agent.get_recent_user_messages(limit: 5)
      
      expect(messages).to be_empty
    end

    it "handles messages with only system prompt" do
      agent.instance_variable_set(:@messages, [
        { role: "system", content: "System prompt" }
      ])
      messages = agent.get_recent_user_messages(limit: 5)
      
      expect(messages).to be_empty
    end

    it "extracts text from array-formatted content (with images)" do
      agent.instance_variable_set(:@messages, [
        { role: "system", content: "System prompt" },
        { 
          role: "user", 
          content: [
            { type: "text", text: "User message with image" },
            { type: "image", source: { type: "base64", data: "..." } }
          ]
        },
        { role: "assistant", content: "Response to message with image" }
      ])
      
      messages = agent.get_recent_user_messages(limit: 5)
      
      expect(messages.size).to eq(1)
      expect(messages.first).to eq("User message with image")
    end

    it "filters out system-injected feedback messages" do
      agent.instance_variable_set(:@messages, [
        { role: "system", content: "System prompt" },
        { role: "user", content: "First real user message" },
        { role: "assistant", content: "First response" },
        { 
          role: "user", 
          content: "STOP. The user has a question/feedback for you: some feedback",
          system_injected: true
        },
        { role: "assistant", content: "Response to feedback" },
        { role: "user", content: "Second real user message" }
      ])
      
      messages = agent.get_recent_user_messages(limit: 5)
      
      expect(messages.size).to eq(2)
      expect(messages).to eq([
        "First real user message",
        "Second real user message"
      ])
    end

    it "filters out edit preview error feedback messages" do
      agent.instance_variable_set(:@messages, [
        { role: "system", content: "System prompt" },
        { role: "user", content: "Edit this file" },
        { role: "assistant", content: "I'll edit the file", tool_calls: [{ id: "1", function: { name: "edit" } }] },
        { 
          role: "user", 
          content: "STOP. The user has a question/feedback for you: The edit operation will fail...",
          system_injected: true
        },
        { role: "assistant", content: "Let me read the file first" },
        { role: "user", content: "Another real user request" }
      ])
      
      messages = agent.get_recent_user_messages(limit: 5)
      
      expect(messages.size).to eq(2)
      expect(messages).to eq([
        "Edit this file",
        "Another real user request"
      ])
    end
  end
end
