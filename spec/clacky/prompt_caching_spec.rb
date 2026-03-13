# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Prompt Caching Feature" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      # Set @api_key instance variable to avoid "API key not configured" error
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  
  describe "AgentConfig" do
    it "enables prompt caching by default" do
      config = Clacky::AgentConfig.new
      expect(config.enable_prompt_caching).to be true
    end
    
    it "allows disabling prompt caching" do
      config = Clacky::AgentConfig.new(enable_prompt_caching: false)
      expect(config.enable_prompt_caching).to be false
    end
    
    it "allows explicitly enabling prompt caching" do
      config = Clacky::AgentConfig.new(enable_prompt_caching: true)
      expect(config.enable_prompt_caching).to be true
    end
  end
  
  describe "Agent with prompt caching" do
    let(:config) do
      Clacky::AgentConfig.new(
        model: "claude-3.5-sonnet-20241022",
        permission_mode: :auto_approve,
        enable_prompt_caching: true
      )
    end
    let(:agent) { Clacky::Agent.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id) }

    it "passes enable_caching flag to client" do
      allow(client).to receive(:send_messages_with_tools).and_return(
        mock_api_response(content: "Test response")
      )

      agent.run("Test prompt")

      expect(client).to have_received(:send_messages_with_tools).with(
        anything,
        hash_including(enable_caching: true)
      )
    end
  end

  describe "Agent without prompt caching" do
    let(:config) do
      Clacky::AgentConfig.new(
        model: "gpt-4",
        permission_mode: :auto_approve,
        enable_prompt_caching: false
      )
    end
    let(:agent) { Clacky::Agent.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id) }

    it "does not add cache_control to system message in agent messages" do
      allow(client).to receive(:send_messages_with_tools).and_return(
        mock_api_response(content: "Test response")
      )

      agent.run("Test prompt")

      # Agent messages should not have cache_control (it's applied in client layer)
      system_msg = agent.messages.find { |m| m[:role] == "system" }
      expect(system_msg).not_to be_nil
      expect(system_msg[:cache_control]).to be_nil
    end
    
    it "passes enable_caching: false to client" do
      allow(client).to receive(:send_messages_with_tools).and_return(
        mock_api_response(content: "Test response")
      )
      
      agent.run("Test prompt")
      
      expect(client).to have_received(:send_messages_with_tools).with(
        anything,
        hash_including(enable_caching: false)
      )
    end
  end
  
  describe "Client prompt caching support" do
    let(:api_key) { "test-key" }
    let(:base_url) { "https://api.example.com" }
    let(:client) { Clacky::Client.new(api_key, base_url: base_url) }
    
    describe "#supports_prompt_caching?" do
      it "returns true for Claude 3.5 Sonnet models" do
        expect(client.send(:supports_prompt_caching?, "claude-3.5-sonnet-20241022")).to be true
        expect(client.send(:supports_prompt_caching?, "claude-3.5-sonnet-latest")).to be true
      end
      
      it "returns true for Claude 3.7 models" do
        expect(client.send(:supports_prompt_caching?, "claude-3-7-sonnet")).to be true
      end
      
      it "returns true for Claude 4 models" do
        expect(client.send(:supports_prompt_caching?, "claude-4-opus")).to be true
      end
      
      it "returns false for older Claude models" do
        expect(client.send(:supports_prompt_caching?, "claude-3-opus-20240229")).to be false
        expect(client.send(:supports_prompt_caching?, "claude-2.1")).to be false
      end
      
      it "returns false for non-Claude models" do
        expect(client.send(:supports_prompt_caching?, "gpt-4")).to be false
        expect(client.send(:supports_prompt_caching?, "gpt-3.5-turbo")).to be false
      end
    end
    
    describe "#deep_clone" do
      it "deep clones hashes" do
        original = { a: { b: { c: 1 } } }
        cloned = client.send(:deep_clone, original)
        
        cloned[:a][:b][:c] = 2
        expect(original[:a][:b][:c]).to eq(1)
      end
      
      it "deep clones arrays" do
        original = [{ a: 1 }, { b: 2 }]
        cloned = client.send(:deep_clone, original)
        
        cloned[0][:a] = 3
        expect(original[0][:a]).to eq(1)
      end
      
      it "handles mixed structures" do
        original = { tools: [{ name: "test", params: { type: "object" } }] }
        cloned = client.send(:deep_clone, original)
        
        cloned[:tools][0][:params][:type] = "string"
        expect(original[:tools][0][:params][:type]).to eq("object")
      end
      
      it "handles immutable objects" do
        original = { str: "test", num: 42, bool: true, nil: nil }
        cloned = client.send(:deep_clone, original)

        expect(cloned).to eq(original)
      end
    end

    describe "#apply_message_caching" do
      it "adds cache_control to the last message" do
        messages = [
          { role: "system", content: "You are a helpful assistant." },
          { role: "user", content: "Hello" }
        ]

        result = client.send(:apply_message_caching, messages)

        # Last message should have cache_control in content array
        last_msg = result.last
        expect(last_msg[:role]).to eq("user")
        expect(last_msg[:content]).to be_an(Array)
        expect(last_msg[:content].first[:type]).to eq("text")
        expect(last_msg[:content].first[:text]).to eq("Hello")
        expect(last_msg[:content].first[:cache_control]).to eq({ type: "ephemeral" })
      end

      it "does not modify non-last messages" do
        messages = [
          { role: "system", content: "System prompt" },
          { role: "user", content: "User message" }
        ]

        result = client.send(:apply_message_caching, messages)

        # System message (not last) should remain unchanged
        system_msg = result.find { |m| m[:role] == "system" }
        expect(system_msg[:content]).to eq("System prompt")
        expect(system_msg[:cache_control]).to be_nil
      end

      it "handles array content format" do
        messages = [
          { role: "system", content: [{ type: "text", text: "System prompt" }] }
        ]

        result = client.send(:apply_message_caching, messages)

        system_msg = result.first
        expect(system_msg[:content].first[:cache_control]).to eq({ type: "ephemeral" })
      end
    end
  end
  
  describe "Session data with caching config" do
    let(:config) do
      Clacky::AgentConfig.new(
        model: "claude-3.5-sonnet-20241022",
        enable_prompt_caching: true
      )
    end
    let(:agent) { Clacky::Agent.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id) }

    it "includes enable_prompt_caching in session data" do
      allow(client).to receive(:send_messages_with_tools).and_return(
        mock_api_response(content: "Test")
      )
      
      agent.run("Test")
      session_data = agent.to_session_data
      
      expect(session_data[:config][:enable_prompt_caching]).to be true
    end
  end
end

# Helper method for mocking API responses
def mock_api_response(content: nil, tool_calls: nil, finish_reason: "stop")
  {
    content: content,
    tool_calls: tool_calls,
    finish_reason: finish_reason,
    usage: {
      prompt_tokens: 100,
      completion_tokens: 50,
      total_tokens: 150
    }
  }
end
