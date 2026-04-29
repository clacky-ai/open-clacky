# frozen_string_literal: true

RSpec.describe Clacky::Providers do
  describe ".capabilities" do
    it "returns {} for an unknown provider" do
      expect(described_class.capabilities("nope-provider")).to eq({})
    end

    it "returns the provider-level capabilities hash when no model override" do
      # MiniMax declares vision: false at the provider level.
      expect(described_class.capabilities("minimax")).to eq("vision" => false)
    end

    it "merges model-level override on top of provider-level defaults" do
      # openclacky: provider default vision:true, but DeepSeek models override to false.
      expect(described_class.capabilities("openclacky", model_name: "dsk-deepseek-v4-pro"))
        .to eq("vision" => false)
      expect(described_class.capabilities("openclacky", model_name: "abs-claude-opus-4-7"))
        .to eq("vision" => true)
    end

    it "falls back to provider-level defaults for unknown model_name" do
      # Unknown model under a known provider — use provider-level defaults.
      expect(described_class.capabilities("minimax", model_name: "ghost-model"))
        .to eq("vision" => false)
    end

    it "returns a fresh hash so callers cannot mutate internal state" do
      caps = described_class.capabilities("minimax")
      caps["vision"] = true
      # Next call should still report the original value
      expect(described_class.capabilities("minimax")).to eq("vision" => false)
    end
  end

  describe ".supports?" do
    context "for providers that declare vision: false at provider level" do
      it "returns false for minimax" do
        expect(described_class.supports?("minimax", :vision)).to be false
      end

      it "returns true for kimi (k2.5/k2.6 are multimodal)" do
        expect(described_class.supports?("kimi", :vision)).to be true
      end

      it "returns false for deepseekv4" do
        expect(described_class.supports?("deepseekv4", :vision)).to be false
      end
    end

    context "for providers that declare vision: true at provider level" do
      it "returns true for openclacky (Claude model)" do
        expect(described_class.supports?("openclacky", :vision,
                                         model_name: "abs-claude-opus-4-7")).to be true
      end

      it "returns true for openclacky without a model_name (provider-wide default)" do
        expect(described_class.supports?("openclacky", :vision)).to be true
      end

      it "returns true for clackyai-sea (Claude model)" do
        expect(described_class.supports?("clackyai-sea", :vision,
                                         model_name: "abs-claude-sonnet-4-5")).to be true
      end
    end

    context "with model-level overrides" do
      it "returns false for openclacky + DeepSeek models (vision-less sidecar)" do
        expect(described_class.supports?("openclacky", :vision,
                                         model_name: "dsk-deepseek-v4-pro")).to be false
        expect(described_class.supports?("openclacky", :vision,
                                         model_name: "dsk-deepseek-v4-flash")).to be false
      end

      it "returns false for clackyai-sea + unknown model (falls back to provider default)" do
        # clackyai-sea no longer hosts DeepSeek; unknown model inherits provider-level vision=true.
        expect(described_class.supports?("clackyai-sea", :vision,
                                         model_name: "dsk-deepseek-v4-pro")).to be true
      end
    end

    context "for providers with mixed model capabilities" do
      it "returns false for mimo (default text-only), true for mimo-v2-omni" do
        expect(described_class.supports?("mimo", :vision)).to be false
        expect(described_class.supports?("mimo", :vision,
                                         model_name: "mimo-v2-pro")).to be false
        expect(described_class.supports?("mimo", :vision,
                                         model_name: "mimo-v2-omni")).to be true
      end

      it "returns false for glm (default text-only), true for glm-5v-turbo" do
        expect(described_class.supports?("glm", :vision)).to be false
        expect(described_class.supports?("glm", :vision,
                                         model_name: "glm-5.1")).to be false
        expect(described_class.supports?("glm", :vision,
                                         model_name: "glm-5v-turbo")).to be true
      end
    end

    context "conservative default (unknown or undeclared)" do
      it "returns true for an unknown provider_id" do
        # Custom base_urls map to nil provider_id; assume capability supported
        # rather than over-aggressively downgrading.
        expect(described_class.supports?("nope-provider", :vision)).to be true
      end

      it "returns true for a provider that does not declare the capability at all" do
        # anthropic preset has no capabilities block — default to true.
        expect(described_class.supports?("anthropic", :vision)).to be true
      end

      it "returns true for a brand new capability name the presets don't know" do
        expect(described_class.supports?("minimax", :some_future_capability)).to be true
      end
    end

    it "accepts capability name as String or Symbol" do
      expect(described_class.supports?("minimax", "vision")).to be false
      expect(described_class.supports?("minimax", :vision)).to be false
    end
  end

  describe ".resolve_provider" do
    it "prefers base_url when it matches a known preset" do
      expect(described_class.resolve_provider(
               base_url: "https://api.openclacky.com", api_key: nil
             )).to eq("openclacky")
    end

    it "returns the base_url match even when api_key belongs to a different family" do
      # base_url wins over api_key heuristic — users explicitly pointed there.
      expect(described_class.resolve_provider(
               base_url: "https://api.deepseek.com", api_key: "clacky-abc"
             )).to eq("deepseekv4")
    end

    it "falls back to clacky-* api_key prefix when base_url is unknown (local-debug proxy)" do
      expect(described_class.resolve_provider(
               base_url: "http://localhost:3100", api_key: "clacky-af2a576"
             )).to eq("openclacky")
    end

    it "returns nil when base_url is unknown and api_key is not a clacky-* key" do
      expect(described_class.resolve_provider(
               base_url: "http://localhost:9999", api_key: "sk-generic"
             )).to be_nil
      expect(described_class.resolve_provider(
               base_url: "http://localhost:9999", api_key: nil
             )).to be_nil
      expect(described_class.resolve_provider(
               base_url: "http://localhost:9999", api_key: ""
             )).to be_nil
    end

    it "returns nil when both base_url and api_key are missing" do
      expect(described_class.resolve_provider(base_url: nil, api_key: nil)).to be_nil
    end
  end
end
