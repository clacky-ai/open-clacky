# frozen_string_literal: true

module Clacky
  # Built-in model provider presets
  # Provides default configurations for supported AI model providers
  module Providers
    # Provider preset definitions
    # Each preset includes:
    # - name: Human-readable provider name
    # - base_url: Default API endpoint
    # - api: API type (anthropic-messages, openai-responses, openai-completions)
    # - default_model: Recommended default model
    # - capabilities (optional): provider-level capability hash (e.g.
    #   { "vision" => false }). Applies to all models under this provider
    #   unless overridden by model_capabilities below.
    # - model_capabilities (optional): per-model capability override map,
    #   { "<model_name>" => { "<cap>" => bool, ... } }. Use this when a
    #   single provider hosts models with different capabilities (e.g.
    #   openclacky hosts both vision-capable Claude and text-only DeepSeek).
    PRESETS = {
      "openclacky" => {
        "name" => "OpenClacky",
        "base_url" => "https://api.openclacky.com",
        "api" => "bedrock",
        "default_model" => "abs-claude-sonnet-4-6",
        "models" => [
          "abs-claude-opus-4-7",
          "abs-claude-opus-4-6",
          "abs-claude-sonnet-4-6",
          "abs-claude-sonnet-4-5",
          "abs-claude-haiku-4-5",
          "dsk-deepseek-v4-pro",
          "dsk-deepseek-v4-flash",
          "or-gemini-3-1-pro"
        ],
        # Provider-level default: the Claude family served here is vision-capable.
        "capabilities" => { "vision" => true }.freeze,
        # Model-level overrides: DeepSeek models routed through this provider
        # are text-only; images uploaded for them must be downgraded to disk refs.
        # Gemini 3.1 Pro keeps the provider-default vision=true (it accepts
        # image/audio/video input natively via OpenRouter).
        "model_capabilities" => {
          "dsk-deepseek-v4-pro"   => { "vision" => false }.freeze,
          "dsk-deepseek-v4-flash" => { "vision" => false }.freeze
        }.freeze,
        # Per-primary lite pairing: keys are "strong" primary models, values
        # are the lite sidekick to auto-inject when that primary is the
        # default. Lite is consumed by some subagents for cheap/fast work;
        # weak models (haiku / v4-flash) ARE the lite tier themselves, so
        # they're intentionally not listed here — no injection happens when
        # the default model is already lite-class.
        #
        # or-gemini-3-1-pro is intentionally absent: Gemini has no lite
        # sibling wired up (yet) on this provider; subagents using the
        # Gemini default will just reuse it for lite work until we add one.
        "lite_models" => {
          "abs-claude-opus-4-7"   => "abs-claude-haiku-4-5",
          "abs-claude-opus-4-6"   => "abs-claude-haiku-4-5",
          "abs-claude-sonnet-4-6" => "abs-claude-haiku-4-5",
          "abs-claude-sonnet-4-5" => "abs-claude-haiku-4-5",
          "dsk-deepseek-v4-pro"   => "dsk-deepseek-v4-flash"
        },
        # Fallback chain: if a model is unavailable, try the next one in order.
        # Keys are primary model names; values are the fallback model to use instead.
        "fallback_models" => {
          "abs-claude-sonnet-4-6" => "abs-claude-sonnet-4-5"
        },
        "website_url" => "https://www.openclacky.com/ai-keys"
      }.freeze,

      "openrouter" => {
        "name" => "OpenRouter",
        "base_url" => "https://openrouter.ai/api/v1",
        "api" => "openai-responses",
        "default_model" => "anthropic/claude-sonnet-4-6",
        "models" => [],  # Dynamic - fetched from API
        "website_url" => "https://openrouter.ai/keys"
      }.freeze,

      "deepseekv4" => {
        "name" => "DeepSeek V4",
        # DeepSeek API is compatible with both OpenAI and Anthropic formats.
        # We use the OpenAI-compatible endpoint here (matches kimi/minimax/glm style).
        # For Anthropic-format usage, point base_url at https://api.deepseek.com/anthropic
        # and change "api" to "anthropic-messages".
        "base_url" => "https://api.deepseek.com",
        "api" => "openai-completions",
        "default_model" => "deepseek-v4-pro",
        "lite_model" => "deepseek-v4-flash",
        # Note: deepseek-chat and deepseek-reasoner are legacy aliases being
        # deprecated on 2026-07-24; they map to deepseek-v4-flash's non-thinking
        # and thinking modes respectively. Prefer deepseek-v4-flash / deepseek-v4-pro.
        "models" => [
          "deepseek-v4-flash",
          "deepseek-v4-pro",
        ],
        # DeepSeek V4 API does not accept image inputs — text-only across all models.
        "capabilities" => { "vision" => false }.freeze,
        "website_url" => "https://platform.deepseek.com/api_keys"
      }.freeze,

      "minimax" => {
        "name" => "Minimax",
        "base_url" => "https://api.minimaxi.com/v1",
        "api" => "openai-completions",
        "default_model" => "MiniMax-M2.7",
        "models" => ["MiniMax-M2.5", "MiniMax-M2.7"],
        # MiniMax M2.x does not support multimodal/vision input on this endpoint.
        "capabilities" => { "vision" => false }.freeze,
        "website_url" => "https://www.minimaxi.com/user-center/basic-information/interface-key"
      }.freeze,

      "kimi" => {
        "name" => "Kimi (Moonshot)",
        "base_url" => "https://api.moonshot.cn/v1",
        "api" => "openai-completions",
        "default_model" => "kimi-k2.6",
        "models" => ["kimi-k2.6", "kimi-k2.5"],
        # k2.5 / k2.6 are multimodal; legacy k2 text-only models need model_capabilities override if added.
        "capabilities" => { "vision" => true }.freeze,
        "website_url" => "https://platform.moonshot.cn/console/api-keys"
      }.freeze,

      "anthropic" => {
        "name" => "Anthropic (Claude)",
        "base_url" => "https://api.anthropic.com",
        "api" => "anthropic-messages",
        "default_model" => "claude-sonnet-4.6",
        "models" => ["claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4.6", "claude-haiku-4.5"],
        "website_url" => "https://console.anthropic.com/settings/keys"
      }.freeze,

      "clackyai-sea" => {
        "name" => "ClackyAI( Sea )",
        "base_url" => "https://api.clacky.ai",
        "api" => "bedrock",
        "default_model" => "abs-claude-sonnet-4-5",
        "models" => [
          "abs-claude-opus-4-6",
          "abs-claude-sonnet-4-6",
          "abs-claude-sonnet-4-5",
          "abs-claude-haiku-4-5"
        ],
        # Claude family — all vision-capable.
        "capabilities" => { "vision" => true }.freeze,
        # Per-primary lite pairing — see openclacky preset for rationale.
        "lite_models" => {
          "abs-claude-opus-4-6"   => "abs-claude-haiku-4-5",
          "abs-claude-sonnet-4-6" => "abs-claude-haiku-4-5",
          "abs-claude-sonnet-4-5" => "abs-claude-haiku-4-5"
        },
        # Fallback chain: if a model is unavailable, try the next one in order.
        # Keys are primary model names; values are the fallback model to use instead.
        "fallback_models" => {
          "abs-claude-sonnet-4-6" => "abs-claude-sonnet-4-5"
        },
        "website_url" => "https://clacky.ai"
      }.freeze,

      "mimo" => {
        "name" => "MiMo (Xiaomi)",
        "base_url" => "https://api.xiaomimimo.com/v1",
        "api" => "openai-completions",
        "default_model" => "mimo-v2-pro",
        "models" => ["mimo-v2-pro", "mimo-v2-omni"],
        # MiMo-V2-Pro is text-only; MiMo-V2-Omni supports vision (omni = multimodal).
        "capabilities" => { "vision" => false }.freeze,
        "model_capabilities" => {
          "mimo-v2-omni" => { "vision" => true }.freeze
        }.freeze,
        "website_url" => "https://platform.xiaomimimo.com/"
      }.freeze,

      "glm" => {
        "name" => "GLM (ZhipuAI)",
        "base_url" => "https://open.bigmodel.cn/api/paas/v4",
        "api" => "openai-completions",
        "default_model" => "glm-5.1",
        "models" => ["glm-5.1", "glm-5", "glm-5-turbo", "glm-5v-turbo", "glm-4.7"],
        # GLM models are text-only except glm-5v-turbo which is vision-capable ("v" = visual).
        "capabilities" => { "vision" => false }.freeze,
        "model_capabilities" => {
          "glm-5v-turbo" => { "vision" => true }.freeze
        }.freeze,
        "website_url" => "https://open.bigmodel.cn/usercenter/apikeys"
      }.freeze

    }.freeze

    class << self
      # Check if a provider preset exists
      # @param provider_id [String] The provider identifier (e.g., "anthropic", "openrouter")
      # @return [Boolean] True if the preset exists
      def exists?(provider_id)
        PRESETS.key?(provider_id)
      end

      # Get a provider preset by ID
      # @param provider_id [String] The provider identifier
      # @return [Hash, nil] The preset configuration or nil if not found
      def get(provider_id)
        PRESETS[provider_id]
      end

      # Get the default model for a provider
      # @param provider_id [String] The provider identifier
      # @return [String, nil] The default model name or nil if provider not found
      def default_model(provider_id)
        preset = PRESETS[provider_id]
        preset&.dig("default_model")
      end

      # Get the base URL for a provider
      # @param provider_id [String] The provider identifier
      # @return [String, nil] The base URL or nil if provider not found
      def base_url(provider_id)
        preset = PRESETS[provider_id]
        preset&.dig("base_url")
      end

      # Get the API type for a provider
      # @param provider_id [String] The provider identifier
      # @return [String, nil] The API type or nil if provider not found
      def api_type(provider_id)
        preset = PRESETS[provider_id]
        preset&.dig("api")
      end

      # List all available provider IDs
      # @return [Array<String>] List of provider identifiers
      def provider_ids
        PRESETS.keys
      end

      # List all available providers with their names
      # @return [Array<Array(String, String)>] Array of [id, name] pairs
      def list
        PRESETS.map { |id, config| [id, config["name"]] }
      end

      # Get available models for a provider
      # @param provider_id [String] The provider identifier
      # @return [Array<String>] List of model names (empty if dynamic)
      def models(provider_id)
        preset = PRESETS[provider_id]
        preset&.dig("models") || []
      end

      # Get the lite model for a provider.
      # @param provider_id [String] The provider identifier
      # @param primary_model [String, nil] The currently-selected primary model name.
      #   When given, look it up in the provider's `lite_models` table first
      #   (so one provider can host multiple model families, each with its own
      #   lite sidekick — e.g. Claude Opus/Sonnet → Haiku, DeepSeek Pro → Flash).
      #   Falls back to the global `lite_model` field for old-style presets
      #   (e.g. deepseekv4) that declare a single provider-wide lite.
      # @return [String, nil] The lite model name, or nil when the primary is
      #   already lite-class (no entry) and no global `lite_model` is defined.
      def lite_model(provider_id, primary_model = nil)
        preset = PRESETS[provider_id]
        return nil unless preset

        if primary_model && preset["lite_models"].is_a?(Hash)
          mapped = preset["lite_models"][primary_model]
          return mapped if mapped
          # When a `lite_models` table is defined but the current primary
          # isn't listed, it means the primary is already a lite-class model
          # (e.g. haiku / v4-flash) — do NOT fall back to the legacy single
          # field, because that would incorrectly inject a lite for a model
          # that doesn't need one.
          return nil if preset["lite_models"].any?
        end

        preset["lite_model"]
      end

      # Get the fallback model for a given model within a provider.
      # Returns nil if no fallback is defined for that model.
      # @param provider_id [String] The provider identifier
      # @param model [String] The primary model name
      # @return [String, nil] The fallback model name or nil
      def fallback_model(provider_id, model)
        preset = PRESETS[provider_id]
        preset&.dig("fallback_models", model)
      end

      # Find provider ID by base URL.
      # Matches if the given URL starts with the provider's base_url (after normalisation),
      # so both exact matches and sub-path variants (e.g. "/v1") are recognised.
      # @param base_url [String] The base URL to look up
      # @return [String, nil] The provider ID or nil if not found
      def find_by_base_url(base_url)
        return nil if base_url.nil? || base_url.empty?
        normalized = base_url.to_s.chomp("/")
        PRESETS.find do |_id, preset|
          preset_base = preset["base_url"].to_s.chomp("/")
          normalized == preset_base || normalized.start_with?("#{preset_base}/")
        end&.first
      end

      # Resolve the provider id for a model entry, trying base_url first and
      # then falling back to an api_key hint for the openclacky family.
      #
      # Why the api_key fallback exists:
      #   For local-debug / self-hosted proxy setups, users sometimes point
      #   an "abs-claude-*" or "dsk-deepseek-*" model at http://localhost:XXXX
      #   while still using a real `clacky-...` api key. Pure base_url matching
      #   would report "unknown provider" and downstream logic (lite pairing,
      #   fallback_models, capability detection) silently degrades. Recognising
      #   the `clacky-` key prefix keeps those flows working without forcing
      #   the user to edit base_url.
      #
      # Not generalised to other providers: the `sk-...` prefix is used by
      # OpenAI, DeepSeek, Moonshot, and many others, so it can't uniquely
      # identify a provider. We only special-case `clacky-` because it's
      # unique to us and the debug-proxy scenario is specifically ours.
      #
      # @param base_url [String, nil] the configured base_url
      # @param api_key  [String, nil] the configured api_key
      # @return [String, nil] provider id or nil if unresolvable
      def resolve_provider(base_url: nil, api_key: nil)
        id = find_by_base_url(base_url)
        return id if id

        # Local-debug fallback: clacky-* api keys belong to the openclacky
        # family. Both "openclacky" and "clackyai-sea" share the same key
        # namespace and an identical model lineup/lite mapping, so picking
        # "openclacky" is equivalent for downstream lookups.
        if api_key.is_a?(String) && api_key.start_with?("clacky-")
          return "openclacky"
        end

        nil
      end

      # Resolve the capabilities hash for a given provider+model.
      #
      # Resolution order (most specific wins):
      #   1. PRESETS[provider_id]["model_capabilities"][model_name] — per-model
      #      override, used when a single provider hosts a mix of capabilities
      #      (e.g. openclacky serves both Claude [vision] and DeepSeek [text]).
      #   2. PRESETS[provider_id]["capabilities"] — provider-wide defaults,
      #      used when the whole lineup shares the same capabilities.
      #   3. {} — no declaration; callers get the conservative default (true)
      #      via `supports?`.
      #
      # Returns a plain Hash (always safe to inspect; never nil).
      # @param provider_id [String] The provider identifier
      # @param model_name [String, nil] Optional specific model for override lookup
      # @return [Hash] capabilities mapping (e.g. { "vision" => true })
      def capabilities(provider_id, model_name: nil)
        preset = PRESETS[provider_id]
        return {} unless preset

        provider_caps = preset["capabilities"] || {}
        return provider_caps.dup unless model_name

        model_caps = preset.dig("model_capabilities", model_name) || {}
        provider_caps.merge(model_caps)
      end

      # Check if a provider+model supports a capability.
      # Unknown provider / missing capability declaration → returns true
      # (conservative default: assume supported unless we explicitly say otherwise).
      # This keeps custom base_urls working and avoids over-aggressive downgrades.
      #
      # @param provider_id [String] The provider identifier
      # @param capability [String, Symbol] The capability name (e.g. :vision, "vision")
      # @param model_name [String, nil] Optional specific model name
      # @return [Boolean] true unless the preset explicitly says false
      def supports?(provider_id, capability, model_name: nil)
        preset = PRESETS[provider_id]
        return true unless preset

        key = capability.to_s
        caps = capabilities(provider_id, model_name: model_name)
        # When the capability is not declared at either level, default to true.
        return true unless caps.key?(key)
        caps[key] != false
      end
    end
  end
end
