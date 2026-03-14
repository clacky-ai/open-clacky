# frozen_string_literal: true

RSpec.describe "Agent#inject_session_context_if_needed" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) do
    Clacky::AgentConfig.new(model: "gpt-4o", permission_mode: :auto_approve)
  end

  def build_agent(tmpdir)
    agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil,
                              profile: "general", session_id: Clacky::SessionManager.generate_id)
    allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
    allow(agent).to receive(:inject_memory_prompt!).and_return(false)
    agent
  end

  def session_ctx_messages(agent)
    agent.messages.select { |m| m[:session_context] }
  end

  it "injects a session context message on the first run" do
    Dir.mktmpdir do |tmpdir|
      agent = build_agent(tmpdir)

      agent.run("hello")

      ctxs = session_ctx_messages(agent)
      expect(ctxs.size).to eq(1)

      msg = ctxs.first
      expect(msg[:role]).to eq("user")
      expect(msg[:system_injected]).to be(true)
      expect(msg[:context_date]).to eq(Time.now.strftime("%Y-%m-%d"))
      expect(msg[:content]).to include("Today is")
      expect(msg[:content]).to include("Current model:")
    end
  end

  it "does NOT inject a second context message if date has not changed" do
    Dir.mktmpdir do |tmpdir|
      agent = build_agent(tmpdir)

      agent.run("first message")
      agent.run("second message")

      expect(session_ctx_messages(agent).size).to eq(1)
    end
  end

  it "re-injects a new context message when the date changes (cross-day scenario)" do
    Dir.mktmpdir do |tmpdir|
      agent = build_agent(tmpdir)

      agent.run("day 1 message")
      expect(session_ctx_messages(agent).size).to eq(1)

      # Simulate crossing midnight: backdate the injected context to yesterday
      session_ctx_messages(agent).first[:context_date] = "2000-01-01"

      agent.run("day 2 message")

      ctxs = session_ctx_messages(agent)
      expect(ctxs.size).to eq(2)
      expect(ctxs.last[:context_date]).to eq(Time.now.strftime("%Y-%m-%d"))
    end
  end

  it "context message is marked system_injected so it is excluded from replay history" do
    Dir.mktmpdir do |tmpdir|
      agent = build_agent(tmpdir)

      agent.run("test")

      ctx = session_ctx_messages(agent).first
      expect(ctx[:system_injected]).to be(true)
    end
  end
end
