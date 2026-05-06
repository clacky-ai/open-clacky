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

  describe ".find_by_base_url with endpoint_variants" do
    # Regression guard for C-5563: providers that expose multiple regional
    # / billing-plan endpoints must be recognised regardless of which URL
    # the user configured, so capability checks (vision=false for GLM
    # text models, MiniMax text-only) fire correctly.

    context "GLM (Zhipu / Z.ai) four endpoints" do
      it "recognises mainland pay-as-you-go" do
        expect(described_class.find_by_base_url("https://open.bigmodel.cn/api/paas/v4"))
          .to eq("glm")
      end

      it "recognises mainland Coding Plan (subpath variant)" do
        # Distinct from paas/v4 — must not be matched as a prefix of the
        # canonical URL, and must be identified as glm via endpoint_variants.
        expect(described_class.find_by_base_url("https://open.bigmodel.cn/api/coding/paas/v4"))
          .to eq("glm")
      end

      it "recognises international pay-as-you-go (api.z.ai)" do
        expect(described_class.find_by_base_url("https://api.z.ai/api/paas/v4"))
          .to eq("glm")
      end

      it "recognises international Coding Plan (api.z.ai)" do
        expect(described_class.find_by_base_url("https://api.z.ai/api/coding/paas/v4"))
          .to eq("glm")
      end

      it "recognises endpoint subpaths under any variant" do
        expect(described_class.find_by_base_url("https://api.z.ai/api/coding/paas/v4/chat/completions"))
          .to eq("glm")
      end

      it "ensures capability detection fires for all four URLs + text model (C-5563 fix)" do
        [
          "https://open.bigmodel.cn/api/paas/v4",
          "https://open.bigmodel.cn/api/coding/paas/v4",
          "https://api.z.ai/api/paas/v4",
          "https://api.z.ai/api/coding/paas/v4"
        ].each do |url|
          id = described_class.find_by_base_url(url)
          # vision=false must be enforced for text-only GLM models regardless
          # of which endpoint the user picked; this is the whole point of
          # declaring endpoint_variants.
          expect(described_class.supports?(id, :vision, model_name: "glm-5.1"))
            .to be(false), "expected vision=false at #{url}"
          # vision model still reports true (per-model override).
          expect(described_class.supports?(id, :vision, model_name: "glm-5v-turbo"))
            .to be(true), "expected vision=true at #{url} for glm-5v-turbo"
        end
      end
    end

    context "MiniMax two regional endpoints" do
      it "recognises mainland (.com)" do
        expect(described_class.find_by_base_url("https://api.minimaxi.com/v1"))
          .to eq("minimax")
      end

      it "recognises international (.io)" do
        expect(described_class.find_by_base_url("https://api.minimax.io/v1"))
          .to eq("minimax")
      end

      it "enforces vision=false on both regional endpoints" do
        ["https://api.minimaxi.com/v1", "https://api.minimax.io/v1"].each do |url|
          expect(described_class.supports?(described_class.find_by_base_url(url), :vision))
            .to be(false), "expected vision=false at #{url}"
        end
      end
    end

    context "Kimi (Moonshot) two regional endpoints" do
      it "recognises mainland (.cn)" do
        expect(described_class.find_by_base_url("https://api.moonshot.cn/v1"))
          .to eq("kimi")
      end

      it "recognises international (.ai)" do
        expect(described_class.find_by_base_url("https://api.moonshot.ai/v1"))
          .to eq("kimi")
      end

      it "keeps vision=true on both endpoints (Kimi k2.5/k2.6 are multimodal)" do
        # Unlike GLM/MiniMax, Kimi's current models support vision — so the
        # whole point of declaring variants here is purely to let capability
        # detection (fallback chains, provider-specific behaviours) wire up
        # correctly, not to force vision=false.
        ["https://api.moonshot.cn/v1", "https://api.moonshot.ai/v1"].each do |url|
          expect(described_class.supports?(described_class.find_by_base_url(url), :vision))
            .to be(true), "expected vision=true at #{url}"
        end
      end
    end

    it "returns nil for an unknown URL unrelated to any preset or variant" do
      expect(described_class.find_by_base_url("https://api.unknown-provider.example/v1"))
        .to be_nil
    end

    it "still recognises the canonical base_url when endpoint_variants is absent" do
      # Anthropic has no endpoint_variants — should behave exactly as before.
      expect(described_class.find_by_base_url("https://api.anthropic.com"))
        .to eq("anthropic")
    end
  end
end
