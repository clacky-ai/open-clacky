# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Clacky::Agent do
  let(:client) do
    instance_double(Clacky::Client).tap do |instance|
      instance.instance_variable_set(:@api_key, "test-api-key")
    end
  end

  let(:config) do
    cfg = Clacky::AgentConfig.new(permission_mode: :auto_approve)
    cfg.add_model(
      model: "gpt-4o-mini",
      api_key: "test-api-key",
      base_url: "https://api.example.com"
    )
    cfg
  end

  it "denies tools that are not allowed for the active profile" do
    agent = described_class.new(
      client,
      config,
      working_dir: Dir.pwd,
      ui: nil,
      profile: "admin",
      session_id: Clacky::SessionManager.generate_id,
      source: :manual
    )

    result = agent.send(:act, [{ id: "call_1", name: "terminal", arguments: '{"command":"pwd"}' }])
    payload = JSON.parse(result[:tool_results].first[:content])

    expect(payload["error"]).to include("not allowed")
  end
end
