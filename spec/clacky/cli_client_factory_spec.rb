# frozen_string_literal: true

require "spec_helper"
require "clacky/cli"

# Regression test for a real-world 404 bug:
#
#   1. User starts a session on DSK model (dsk-*, base_url http://localhost:3100,
#      OpenAI-compatible /chat/completions).
#   2. User presses `/config` and switches to Opus (abs-*, base_url
#      https://api.openclacky.com, Bedrock Converse /model/{id}/converse).
#   3. User presses `/clear`.
#   4. User sends a chat message → HTTP 404 "page not found".
#
# Root cause: the CLI used to keep a long-lived `client` local variable and
# ivar_set individual fields onto it inside `handle_config_command`. That
# code path missed @model and @use_bedrock (both only computed in
# Client#initialize). When `/clear` then did `Agent.new(client, ...)`, the
# new agent inherited the stale Client → posted to `/chat/completions` on
# api.openclacky.com (which only serves `/model/{id}/converse`) → 404.
#
# Fix: the CLI now holds a `client_factory` lambda (closes over agent_config)
# and calls it whenever a fresh Client is needed. All model switching goes
# through the single `Agent#switch_model_by_id` entry point.
#
# This spec pins the correct behaviour so the bug cannot regress silently.
RSpec.describe "CLI client staleness regression (DSK → Opus → /clear)" do
  let(:config_path) { Dir.mktmpdir("clacky-cli-regression") }
  let(:agent_config) do
    Clacky::AgentConfig.new.tap do |cfg|
      cfg.instance_variable_set(:@models, [
        {
          "id"       => "m-dsk",
          "name"     => "DSK",
          "model"    => "dsk-chat",
          "api_key"  => "clacky-dsk-key",
          "base_url" => "http://localhost:3100"
          # no "type" => not the default
        },
        {
          "id"       => "m-opus",
          "name"     => "Opus",
          "model"    => "abs-claude-opus",
          "api_key"  => "clacky-opus-key",
          "base_url" => "https://api.openclacky.com",
          "type"     => "default"
        }
      ])
      # Start on DSK (the non-default) — mimics CLI reading default first
      # but we want the bug-trigger path: session starts on DSK, user then
      # switches to Opus via /config.
      cfg.switch_model_by_id("m-dsk")
    end
  end

  # The factory lambda is the entire fix. Building one here lets us exercise
  # the same contract the CLI runtime relies on.
  let(:client_factory) do
    lambda do
      Clacky::Client.new(
        agent_config.api_key,
        base_url: agent_config.base_url,
        model: agent_config.model_name,
        anthropic_format: agent_config.anthropic_format?
      )
    end
  end

  # Build an Agent with a real Client built from the factory. No HTTP is
  # actually performed — we only inspect @use_bedrock / @model on the client.
  def build_agent
    Clacky::Agent.new(
      client_factory.call,
      agent_config,
      working_dir:  Dir.pwd,
      ui:           nil,
      profile:      "coding",
      session_id:   Clacky::SessionManager.generate_id,
      source:       :manual
    )
  end

  it "starts on DSK with @use_bedrock=false (OpenAI-compat path)" do
    agent = build_agent
    client = agent.instance_variable_get(:@client)
    expect(client.instance_variable_get(:@model)).to eq("dsk-chat")
    expect(client.instance_variable_get(:@use_bedrock)).to eq(false)
    expect(client.instance_variable_get(:@base_url)).to eq("http://localhost:3100")
  end

  it "after /config → switch_model_by_id('m-opus'), the agent's client is rebuilt with @use_bedrock=true" do
    agent = build_agent
    # Simulate what handle_config_command now does on :switch
    expect(agent.switch_model_by_id("m-opus")).to eq(true)

    client = agent.instance_variable_get(:@client)
    expect(client.instance_variable_get(:@model)).to eq("abs-claude-opus")
    expect(client.instance_variable_get(:@use_bedrock)).to eq(true)
    expect(client.instance_variable_get(:@base_url)).to eq("https://api.openclacky.com")
  end

  it "after /config switch THEN /clear (new Agent from factory), the fresh client still has @use_bedrock=true" do
    # Step 1: start on DSK
    agent = build_agent

    # Step 2: /config → switch to Opus
    agent.switch_model_by_id("m-opus")

    # Step 3: /clear → CLI builds a NEW agent with client_factory.call
    # This is the exact line in run_agent_with_ui2:
    #   agent = Clacky::Agent.new(client_factory.call, agent_config, ...)
    fresh_agent = Clacky::Agent.new(
      client_factory.call,
      agent_config,
      working_dir:  Dir.pwd,
      ui:           nil,
      profile:      "coding",
      session_id:   Clacky::SessionManager.generate_id,
      source:       :manual
    )

    fresh_client = fresh_agent.instance_variable_get(:@client)
    # The regression trap: these must all reflect Opus, not stale DSK state.
    expect(fresh_client.instance_variable_get(:@model)).to eq("abs-claude-opus")
    expect(fresh_client.instance_variable_get(:@use_bedrock)).to eq(true)
    expect(fresh_client.instance_variable_get(:@base_url)).to eq("https://api.openclacky.com")
    expect(fresh_client.instance_variable_get(:@api_key)).to eq("clacky-opus-key")
  end

  it "reverse direction Opus → DSK → /clear: fresh client has @use_bedrock=false" do
    # Start on Opus (the current default), then switch to DSK
    agent_config.switch_model_by_id("m-opus")
    agent = build_agent
    expect(agent.instance_variable_get(:@client).instance_variable_get(:@use_bedrock)).to eq(true)

    agent.switch_model_by_id("m-dsk")

    # /clear
    fresh_agent = Clacky::Agent.new(
      client_factory.call,
      agent_config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id:  Clacky::SessionManager.generate_id, source: :manual
    )
    fresh_client = fresh_agent.instance_variable_get(:@client)
    expect(fresh_client.instance_variable_get(:@model)).to eq("dsk-chat")
    expect(fresh_client.instance_variable_get(:@use_bedrock)).to eq(false)
  end
end
