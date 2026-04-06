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
    PRESETS = {

      "openrouter" => {
        "name" => "OpenRouter",
        "base_url" => "https://openrouter.ai/api/v1",
        "api" => "openai-responses",
        "default_model" => "anthropic/claude-sonnet-4-6",
        "lite_model" => "anthropic/claude-haiku-4-5",
        "models" => [],  # Dynamic - fetched from API
        "website_url" => "https://openrouter.ai/keys"
      }.freeze,

      "minimax" => {
        "name" => "Minimax",
        "base_url" => "https://api.minimaxi.com/v1",
        "api" => "openai-completions",
        "default_model" => "MiniMax-M2.7",
        "models" => ["MiniMax-M2.5", "MiniMax-M2.7"],
        "website_url" => "https://www.minimaxi.com/user-center/basic-information/interface-key"
      }.freeze,

      "kimi" => {
        "name" => "Kimi (Moonshot)",
        "base_url" => "https://api.moonshot.cn/v1",
        "api" => "openai-completions",
        "default_model" => "kimi-k2.5",
        "models" => ["kimi-k2.5"],
        "website_url" => "https://platform.moonshot.cn/console/api-keys"
      }.freeze,

      "anthropic" => {
        "name" => "Anthropic (Claude)",
        "base_url" => "https://api.anthropic.com",
        "api" => "anthropic-messages",
        "default_model" => "claude-sonnet-4.6",
        "models" => ["claude-opus-4-6", "claude-sonnet-4.6", "claude-haiku-4.5"],
        "website_url" => "https://console.anthropic.com/settings/keys"
      }.freeze,

      "clackyai" => {
        "name" => "ClackyAI",
        "base_url" => "https://api.clacky.ai",
        "api" => "bedrock",
        "default_model" => "abs-claude-sonnet-4-6",
        "lite_model" => "abs-claude-haiku-4-5",
        "models" => [
          "abs-claude-opus-4-6",
          "abs-claude-sonnet-4-6",
          "abs-claude-haiku-4-5"
        ],
        "website_url" => "https://clacky.ai"
      }.freeze,

      "mimo" => {
        "name" => "MiMo (Xiaomi)",
        "base_url" => "https://api.xiaomimimo.com/v1",
        "api" => "openai-completions",
        "default_model" => "mimo-v2-pro",
        "models" => ["mimo-v2-pro", "mimo-v2-omni"],
        "website_url" => "https://platform.xiaomimimo.com/"
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

      # Get the lite model for a provider (if any)
      # @param provider_id [String] The provider identifier
      # @return [String, nil] The lite model name or nil if provider has no lite model
      def lite_model(provider_id)
        preset = PRESETS[provider_id]
        preset&.dig("lite_model")
      end

      # Find provider ID by base URL
      # @param base_url [String] The base URL to look up
      # @return [String, nil] The provider ID or nil if not found
      def find_by_base_url(base_url)
        return nil if base_url.nil? || base_url.empty?
        normalized = base_url.to_s.chomp("/")
        PRESETS.find { |_id, preset| preset["base_url"].to_s.chomp("/") == normalized }&.first
      end
    end
  end
end
