# frozen_string_literal: true

RSpec.describe "Agent#inject_skill_command_as_assistant_message" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) { Clacky::AgentConfig.new(model: "gpt-3.5-turbo", permission_mode: :auto_approve) }

  # Helper: create a temp skill with given frontmatter flags
  def create_skill(dir, name:, disable_model_invocation: false, user_invocable: true, content: "Skill instructions here.")
    skill_dir = File.join(dir, ".clacky", "skills", name)
    FileUtils.mkdir_p(skill_dir)
    frontmatter = ["---", "name: #{name}", "description: Test skill #{name}"]
    frontmatter << "disable-model-invocation: true" if disable_model_invocation
    frontmatter << "user-invocable: #{user_invocable}"
    frontmatter << "---"
    File.write(File.join(skill_dir, "SKILL.md"), (frontmatter + ["", content]).join("\n"))
  end

  it "injects assistant message with skill content when skill has disable-model-invocation: true" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "onboard", disable_model_invocation: true, content: "Onboard the user now.")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)

      # Stub run's LLM call so we can inspect messages without hitting the API
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("/onboard")

      assistant_msgs = agent.messages.select { |m| m[:role] == "assistant" && m[:system_injected] }
      expect(assistant_msgs.size).to eq(1)
      expect(assistant_msgs.first[:content]).to include("Onboard the user now.")
    end
  end

  it "appends a synthetic user shim message after skill injection for Claude compat" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "onboard", disable_model_invocation: true, content: "Onboard the user now.")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("/onboard")

      # After the injected assistant message there must be a user shim so the
      # conversation sequence ends with a user turn (required by Claude / Anthropic API).
      # Exclude session_context messages which are also system_injected but unrelated to skills.
      injected_msgs = agent.messages.select { |m| m[:system_injected] && !m[:session_context] }
      expect(injected_msgs.size).to eq(2)

      assistant_shim = injected_msgs.find { |m| m[:role] == "assistant" }
      user_shim      = injected_msgs.find { |m| m[:role] == "user" }

      expect(assistant_shim).not_to be_nil
      expect(user_shim).not_to be_nil
      expect(user_shim[:content]).to include("proceed")

      # The user shim must appear immediately after the assistant shim
      all_msgs = agent.messages
      assistant_idx = all_msgs.index(assistant_shim)
      user_idx      = all_msgs.index(user_shim)
      expect(user_idx).to eq(assistant_idx + 1)
    end
  end

  it "passes arguments as part of the expanded skill content" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "onboard", disable_model_invocation: true, content: "Task: \$ARGUMENTS")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("/onboard hello world")

      injected = agent.messages.find { |m| m[:role] == "assistant" && m[:system_injected] }
      expect(injected[:content]).to include("hello world")
    end
  end

  it "also injects for skills that are model-invocable (slash command is always direct)" do
    Dir.mktmpdir do |tmpdir|
      # No disable-model-invocation: true => model_invocation_allowed? == true
      create_skill(tmpdir, name: "my-skill", disable_model_invocation: false, content: "Normal skill content.")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("/my-skill")

      injected = agent.messages.select { |m| m[:role] == "assistant" && m[:system_injected] }
      expect(injected.size).to eq(1)
      expect(injected.first[:content]).to include("Normal skill content.")
    end
  end

  it "does NOT inject when input is not a slash command" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "onboard", disable_model_invocation: true, content: "Onboard.")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("just a normal message")

      # Only check skill-injected messages; session_context messages are also system_injected but expected
      injected = agent.messages.select { |m| m[:system_injected] && !m[:session_context] }
      expect(injected).to be_empty
    end
  end
end
