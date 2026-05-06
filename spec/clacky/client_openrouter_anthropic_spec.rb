# frozen_string_literal: true

require "spec_helper"
require "clacky/client"

# Regression guard for the OpenRouter prompt-cache bug:
#
# Previously, OpenRouter was always presented as "openai-responses". When users
# ran Claude through OpenRouter, every request got funnelled into the OpenAI
# /chat/completions shim, which rewrites prefixes in ways that break Claude's
# cache_control semantics — producing ~10% prompt-cache misses.
#
# The fix: Providers.anthropic_format_for_model?("openrouter", "anthropic/…")
# returns true, and Client picks that up at construction time — regardless of
# what the caller passed for `anthropic_format:`. That routes the request to
# OpenRouter's native /v1/messages endpoint, which preserves cache_control
# byte-for-byte (matching what Claude Code CLI does internally).
RSpec.describe Clacky::Client, "OpenRouter Anthropic routing" do
  let(:openrouter_url) { "https://openrouter.ai/api/v1" }
  let(:api_key)        { "sk-or-v1-testkey" }

  def build(model, anthropic_format: false, base_url: openrouter_url)
    described_class.new(api_key, base_url: base_url, model: model,
                                 anthropic_format: anthropic_format)
  end

  describe "#anthropic_format?" do
    it "auto-enables for OpenRouter anthropic/* models even when caller passes false" do
      # Callers that read stale YAML might still pass anthropic_format: false.
      # The provider preset should win — otherwise the cache-miss bug returns.
      client = build("anthropic/claude-sonnet-4-6", anthropic_format: false)
      expect(client.anthropic_format?).to be true
    end

    it "stays disabled for OpenRouter non-Claude models" do
      client = build("google/gemini-3-pro", anthropic_format: false)
      expect(client.anthropic_format?).to be false
    end

    it "does not affect Bedrock-prefixed models (abs-*) which have their own path" do
      # abs-* models go through Bedrock regardless of base_url; anthropic_format?
      # must stay false per its existing contract (checked via !@use_bedrock).
      client = described_class.new("clacky-key",
                                   base_url: "https://api.openclacky.com",
                                   model: "abs-claude-opus-4-7")
      expect(client.bedrock?).to be true
      expect(client.anthropic_format?).to be false
    end

    it "respects explicit anthropic_format: true for custom (unknown) base_urls" do
      # If the user points at a self-hosted Anthropic-compatible proxy whose
      # base_url is not in the preset list, the explicit flag must still work.
      client = described_class.new("anything",
                                   base_url: "https://custom.example.com",
                                   model: "claude-like-model",
                                   anthropic_format: true)
      expect(client.anthropic_format?).to be true
    end
  end

  describe "#anthropic_connection headers" do
    # Rationale: OpenRouter's /v1/messages authenticates with Bearer tokens,
    # not Anthropic's x-api-key. We send both so the same connection code
    # works for direct Anthropic and for OpenRouter-proxied Claude.
    it "sends both Authorization Bearer and x-api-key on OpenRouter" do
      client = build("anthropic/claude-sonnet-4-6")
      conn = client.send(:anthropic_connection)
      expect(conn.headers["Authorization"]).to eq("Bearer #{api_key}")
      expect(conn.headers["x-api-key"]).to eq(api_key)
      expect(conn.headers["anthropic-version"]).to eq("2023-06-01")
    end

    it "does not add an Authorization header for direct Anthropic" do
      # Anthropic's API rejects requests with an Authorization header set to
      # an api-key value; only x-api-key is valid there.
      direct = described_class.new("sk-ant-test",
                                   base_url: "https://api.anthropic.com",
                                   model: "claude-sonnet-4.6",
                                   anthropic_format: true)
      conn = direct.send(:anthropic_connection)
      expect(conn.headers["x-api-key"]).to eq("sk-ant-test")
      expect(conn.headers["Authorization"]).to be_nil
    end
  end

  # Regression: OpenRouter's preset base_url is "https://openrouter.ai/api/v1",
  # which already includes the "/v1" segment. Faraday's URI merge then produced
  # "/api/v1/v1/messages" → 404 HTML page → the user sees
  #   "Invalid API endpoint or server error (received HTML instead of JSON)".
  # The fix: #anthropic_messages_path returns "messages" (not "v1/messages")
  # when base_url already ends with "/v1".
  describe "#anthropic_messages_path" do
    it "returns 'messages' when base_url already ends with /v1 (OpenRouter)" do
      client = build("anthropic/claude-sonnet-4-6")
      expect(client.send(:anthropic_messages_path)).to eq("messages")
    end

    it "tolerates a trailing slash in base_url" do
      client = build("anthropic/claude-sonnet-4-6", base_url: "https://openrouter.ai/api/v1/")
      expect(client.send(:anthropic_messages_path)).to eq("messages")
    end

    it "returns 'v1/messages' for direct Anthropic (no /v1 in base_url)" do
      direct = described_class.new("sk-ant-test",
                                   base_url: "https://api.anthropic.com",
                                   model: "claude-sonnet-4.6",
                                   anthropic_format: true)
      expect(direct.send(:anthropic_messages_path)).to eq("v1/messages")
    end

    it "produces a well-formed full URL when combined with the connection's base_url" do
      # Belt-and-braces check: the whole point of this helper is that the final
      # POST URL is correct. Assert both sides to catch any future regression
      # in Faraday's URI merging semantics.
      client = build("anthropic/claude-sonnet-4-6")
      conn = client.send(:anthropic_connection)
      full = conn.build_url(client.send(:anthropic_messages_path)).to_s
      expect(full).to eq("https://openrouter.ai/api/v1/messages")

      direct = described_class.new("sk-ant-test",
                                   base_url: "https://api.anthropic.com",
                                   model: "claude-sonnet-4.6",
                                   anthropic_format: true)
      dconn = direct.send(:anthropic_connection)
      dfull = dconn.build_url(direct.send(:anthropic_messages_path)).to_s
      expect(dfull).to eq("https://api.anthropic.com/v1/messages")
    end
  end
end
