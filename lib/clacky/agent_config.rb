# frozen_string_literal: true

require "yaml"
require "fileutils"
require "securerandom"

module Clacky
  # ClaudeCode environment variable compatibility layer
  # Provides configuration detection from ClaudeCode's environment variables
  module ClaudeCodeEnv
    # Environment variable names used by ClaudeCode
    ENV_API_KEY = "ANTHROPIC_API_KEY"
    ENV_AUTH_TOKEN = "ANTHROPIC_AUTH_TOKEN"
    ENV_BASE_URL = "ANTHROPIC_BASE_URL"

    # Default Anthropic API endpoint
    DEFAULT_BASE_URL = "https://api.anthropic.com"

    class << self
      # Check if any ClaudeCode authentication is configured
      def configured?
        !api_key.nil? && !api_key.empty?
      end

      # Get API key - prefer ANTHROPIC_API_KEY, fallback to ANTHROPIC_AUTH_TOKEN
      def api_key
        if ENV[ENV_API_KEY] && !ENV[ENV_API_KEY].empty?
          ENV[ENV_API_KEY]
        elsif ENV[ENV_AUTH_TOKEN] && !ENV[ENV_AUTH_TOKEN].empty?
          ENV[ENV_AUTH_TOKEN]
        end
      end

      # Get base URL from environment, or return default Anthropic API URL
      def base_url
        ENV[ENV_BASE_URL] && !ENV[ENV_BASE_URL].empty? ? ENV[ENV_BASE_URL] : DEFAULT_BASE_URL
      end

      # Get configuration as a hash (includes configured values)
      # Returns api_key and base_url (always available as there's a default)
      def to_h
        {
          "api_key" => api_key,
          "base_url" => base_url
        }.compact
      end
    end
  end

  # Clacky environment variable layer
  # Provides configuration from CLACKY_XXX environment variables
  module ClackyEnv
    # Environment variable names for default model
    ENV_API_KEY = "CLACKY_API_KEY"
    ENV_BASE_URL = "CLACKY_BASE_URL"
    ENV_MODEL = "CLACKY_MODEL"
    ENV_ANTHROPIC_FORMAT = "CLACKY_ANTHROPIC_FORMAT"

    # Environment variable names for lite model
    ENV_LITE_API_KEY = "CLACKY_LITE_API_KEY"
    ENV_LITE_BASE_URL = "CLACKY_LITE_BASE_URL"
    ENV_LITE_MODEL = "CLACKY_LITE_MODEL"
    ENV_LITE_ANTHROPIC_FORMAT = "CLACKY_LITE_ANTHROPIC_FORMAT"

    # Default model name (only for model, not base_url)
    DEFAULT_MODEL = "claude-sonnet-4-5"

    class << self
      # Check if default model is configured via environment variables
      def default_configured?
        !default_api_key.nil? && !default_api_key.empty?
      end

      # Check if lite model is configured via environment variables
      def lite_configured?
        !lite_api_key.nil? && !lite_api_key.empty?
      end

      # Get default model API key
      def default_api_key
        ENV[ENV_API_KEY] if ENV[ENV_API_KEY] && !ENV[ENV_API_KEY].empty?
      end

      # Get default model base URL (no default, must be explicitly set)
      def default_base_url
        ENV[ENV_BASE_URL] if ENV[ENV_BASE_URL] && !ENV[ENV_BASE_URL].empty?
      end

      # Get default model name
      def default_model
        ENV[ENV_MODEL] && !ENV[ENV_MODEL].empty? ? ENV[ENV_MODEL] : DEFAULT_MODEL
      end

      # Get default model anthropic_format flag
      def default_anthropic_format
        return true if ENV[ENV_ANTHROPIC_FORMAT].nil? || ENV[ENV_ANTHROPIC_FORMAT].empty?
        ENV[ENV_ANTHROPIC_FORMAT].downcase == "true"
      end

      # Get default model configuration as a hash
      def default_model_config
        {
          "type" => "default",
          "api_key" => default_api_key,
          "base_url" => default_base_url,
          "model" => default_model,
          "anthropic_format" => default_anthropic_format
        }.compact
      end

      # Get lite model API key
      def lite_api_key
        ENV[ENV_LITE_API_KEY] if ENV[ENV_LITE_API_KEY] && !ENV[ENV_LITE_API_KEY].empty?
      end

      # Get lite model base URL (no default, must be explicitly set)
      def lite_base_url
        ENV[ENV_LITE_BASE_URL] if ENV[ENV_LITE_BASE_URL] && !ENV[ENV_LITE_BASE_URL].empty?
      end

      # Get lite model name
      def lite_model
        ENV[ENV_LITE_MODEL] && !ENV[ENV_LITE_MODEL].empty? ? ENV[ENV_LITE_MODEL] : "claude-haiku-4"
      end

      # Get lite model anthropic_format flag
      def lite_anthropic_format
        return true if ENV[ENV_LITE_ANTHROPIC_FORMAT].nil? || ENV[ENV_LITE_ANTHROPIC_FORMAT].empty?
        ENV[ENV_LITE_ANTHROPIC_FORMAT].downcase == "true"
      end

      # Get lite model configuration as a hash
      def lite_model_config
        {
          "type" => "lite",
          "api_key" => lite_api_key,
          "base_url" => lite_base_url,
          "model" => lite_model,
          "anthropic_format" => lite_anthropic_format
        }.compact
      end
    end
  end

  class AgentConfig
    CONFIG_DIR = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "config.yml")

    # Default model for ClaudeCode environment
    CLAUDE_DEFAULT_MODEL = "claude-sonnet-4-5"

    PERMISSION_MODES = [:auto_approve, :confirm_safes, :confirm_all].freeze

    attr_accessor :permission_mode, :max_tokens, :verbose,
                  :enable_compression, :enable_prompt_caching,
                  :models, :current_model_index, :current_model_id,
                  :memory_update_enabled, :skill_evolution

    def initialize(options = {})
      @permission_mode = validate_permission_mode(options[:permission_mode])
      @max_tokens = options[:max_tokens] || 8192
      @verbose = options[:verbose] || false
      @enable_compression = options[:enable_compression].nil? ? true : options[:enable_compression]
      # Enable prompt caching by default for cost savings
      @enable_prompt_caching = options[:enable_prompt_caching].nil? ? true : options[:enable_prompt_caching]

      # Models configuration
      @models = options[:models] || []
      # Ensure every model has a stable runtime id — this is the single
      # invariant the rest of the system relies on. Regardless of how the
      # config was built (load from yml, direct .new in tests, add_model,
      # api_save_config), every model in @models will have an id.
      @models.each { |m| m["id"] ||= SecureRandom.uuid }

      @current_model_index = options[:current_model_index] || 0
      # Stable runtime id for the currently-selected model. Preferred over
      # @current_model_index because ids are immune to list reordering,
      # additions, and edits to model fields. Ids are injected at load time
      # and never persisted to config.yml (backward compatible with old files).
      # If caller didn't specify current_model_id, prefer the model marked
      # as `type: default` (the documented convention), falling back to
      # models[current_model_index] only if no default marker exists.
      @current_model_id = options[:current_model_id] ||
                          (@models.find { |m| m["type"] == "default" } || @models[@current_model_index])&.dig("id")

      # Memory and skill evolution configuration
      @memory_update_enabled = options[:memory_update_enabled].nil? ? true : options[:memory_update_enabled]
      @skill_evolution = options[:skill_evolution] || {
        enabled: true,
        auto_create_threshold: 12,
        reflection_mode: "llm_analysis"
      }
    end

    # Load configuration from file
    def self.load(config_file = CONFIG_FILE)
      # Load from config file first
      if File.exist?(config_file)
        data = YAML.load_file(config_file)
      else
        data = nil
      end

      # Parse models from config
      models = parse_models(data)

      # Priority: config file > CLACKY_XXX env vars > ClaudeCode env vars
      if models.empty?
        # Try CLACKY_XXX environment variables first
        if ClackyEnv.default_configured?
          models << ClackyEnv.default_model_config
        # ClaudeCode (Anthropic) environment variable support is disabled
        # elsif ClaudeCodeEnv.configured?
        #   models << {
        #     "type" => "default",
        #     "api_key" => ClaudeCodeEnv.api_key,
        #     "base_url" => ClaudeCodeEnv.base_url,
        #     "model" => CLAUDE_DEFAULT_MODEL,
        #     "anthropic_format" => true
        #   }
        end

        # Add CLACKY_LITE_XXX if configured (only when loading from env)
        if ClackyEnv.lite_configured?
          models << ClackyEnv.lite_model_config
        end
      else
        # Config file exists, but check if we need to add env-based models
        # Only add if no model with that type exists
        has_default = models.any? { |m| m["type"] == "default" }
        has_lite = models.any? { |m| m["type"] == "lite" }

        # Add CLACKY default if not in config and env is set
        if !has_default && ClackyEnv.default_configured?
          models << ClackyEnv.default_model_config
        end

        # Add CLACKY lite if not in config and env is set
        if !has_lite && ClackyEnv.lite_configured?
          models << ClackyEnv.lite_model_config
        end

        # Ensure at least one model has type: default
        # If no model has type: default, assign it to the first model
        unless models.any? { |m| m["type"] == "default" }
          models.first["type"] = "default" if models.any?
        end
      end

      # Auto-inject lite model from provider preset when:
      # 1. A default model exists
      # 2. No lite model is configured yet (neither in file nor env)
      # 3. The default model's provider has a known lite_model
      # The injected lite model is runtime-only (not persisted to config.yml)
      inject_provider_lite_model(models)

      # Ensure every model has a stable runtime id — covers env-injected
      # models (CLACKY_XXX, CLAUDE_XXX) that don't go through parse_models.
      # Ids are NOT persisted to config.yml (see to_yaml).
      models.each { |m| m["id"] ||= SecureRandom.uuid }

      # Find the index of the model marked as "default" (type: default)
      # Fall back to 0 if no model has type: default
      default_index = models.find_index { |m| m["type"] == "default" } || 0
      default_id = models[default_index] && models[default_index]["id"]

      new(models: models, current_model_index: default_index, current_model_id: default_id)
    end

    # Auto-inject a lite model entry if the default model's provider supports one
    # and no lite model is already present. The injected entry reuses the same
    # api_key and base_url as the default model — only the model name differs.
    # @param models [Array<Hash>] mutable models array (modified in-place)
    private_class_method def self.inject_provider_lite_model(models)
      return if models.any? { |m| m["type"] == "lite" }

      default_model = models.find { |m| m["type"] == "default" } || models.first
      return unless default_model

      provider_id = Clacky::Providers.find_by_base_url(default_model["base_url"])
      return unless provider_id

      lite_model_name = Clacky::Providers.lite_model(provider_id)
      return unless lite_model_name

      # Don't inject if the default model IS the lite model
      return if default_model["model"] == lite_model_name

      models << {
        "api_key"          => default_model["api_key"],
        "base_url"         => default_model["base_url"],
        "model"            => lite_model_name,
        "anthropic_format" => default_model["anthropic_format"] || false,
        "type"             => "lite",
        "auto_injected"    => true,  # Mark as auto-injected (not saved to file)
        "id"               => SecureRandom.uuid  # Runtime id for stable session references
      }
    end

    # Create a per-session copy of this config.
    #
    # Plan B (shared models): we deliberately share the SAME @models array
    # reference with all sessions (no deep clone). This is the key design
    # decision that keeps session and global views in sync:
    #   - User adds a model in Settings → every live session sees it instantly.
    #   - User edits api_key/base_url → every live session's next API call
    #     picks up the new credentials (via current_model lookup).
    #   - Model ids are stable across edits, so each session's
    #     @current_model_id continues to resolve correctly.
    #
    # Per-session state that MUST stay isolated (permission_mode,
    # @current_model_id, @current_model_index, fallback state) are scalar
    # copies via `dup` and don't leak between sessions.
    #
    # Before Plan B, sessions held deep-copied @models — which silently
    # diverged from the global list any time the user added/edited a model
    # in Settings, producing bugs like "Failed to switch model" for newly
    # added models on Windows and Linux. See http_server.rb#api_switch_session_model
    # and http_server.rb#api_save_config for the companion logic.
    def deep_copy
      # dup gives us a new AgentConfig with independent scalar ivars but
      # the same @models reference — exactly what we want.
      dup
    end

    def save(config_file = CONFIG_FILE)
      config_dir = File.dirname(config_file)
      FileUtils.mkdir_p(config_dir)
      File.write(config_file, to_yaml)
      FileUtils.chmod(0o600, config_file)
    end

    # Convert to YAML format (top-level array)
    # Auto-injected lite models (auto_injected: true) are excluded from persistence —
    # they are regenerated at load time from the provider preset.
    # Runtime-only fields (id, auto_injected) are stripped before writing so
    # config.yml remains backward compatible with users on older versions.
    RUNTIME_ONLY_FIELDS = %w[id auto_injected].freeze

    def to_yaml
      persistable = @models.reject { |m| m["auto_injected"] }.map do |m|
        m.reject { |k, _| RUNTIME_ONLY_FIELDS.include?(k) }
      end
      YAML.dump(persistable)
    end

    # Check if any model is configured
    def models_configured?
      !@models.empty? && !current_model.nil?
    end

    # NOTE: current_model is defined below (near the id-aware lookup path)
    # — the earlier duplicate definition was removed. Ruby silently picks the
    # last definition, but keeping only one avoids confusion.

    # Get model by index
    def get_model(index)
      @models[index]
    end

    # Switch the current session to a specific model, identified by its
    # stable runtime id.
    #
    # This is a **per-session** operation:
    #   - Updates this AgentConfig's `@current_model_id` (primary truth)
    #   - Updates `@current_model_index` for back-compat observers
    #   - Does NOT mutate the shared `@models` array's `type: "default"`
    #     marker. The "default model" is a global setting (initial model
    #     for new sessions) and is only changed via the Settings UI
    #     "save config" flow (`api_save_config`).
    #
    # @param id [String] the model's runtime id (see parse_models)
    # @return [Boolean] true if switched, false if id not found
    def switch_model_by_id(id)
      return false if id.nil? || id.to_s.empty?

      index = @models.find_index { |m| m["id"] == id }
      return false if index.nil?

      @current_model_id = id
      @current_model_index = index

      true
    end

    # Set the **global** default model marker (`type: "default"`).
    #
    # This is separate from `switch_model_by_id`:
    #   - `switch_model_by_id` only changes this session's current model.
    #   - `set_default_model_by_id` mutates the shared `@models` array by
    #     moving the `type: "default"` marker to the given model.
    #
    # Use cases:
    #   - CLI (single-session): when the user picks a model, we both switch
    #     this session AND update the global default so future CLI launches
    #     use the same model. Caller must `save` to persist.
    #   - Web UI Settings save flow: also uses this (via payload).
    #
    # Do NOT call from per-session model switching in multi-session contexts
    # (Web UI session-level switch), since it would leak into other sessions
    # and change what new sessions start with.
    #
    # Only one model may carry `type: "default"` at a time — this method
    # clears the marker on any other model that had it.
    #
    # Note: if the target model currently has `type: "lite"`, this method
    # will overwrite it with `"default"`. That matches the existing
    # single-slot `type` field semantics in the codebase.
    #
    # @param id [String] the model's runtime id
    # @return [Boolean] true if marker was moved, false if id not found
    def set_default_model_by_id(id)
      return false if id.nil? || id.to_s.empty?

      target = @models.find { |m| m["id"] == id }
      return false if target.nil?

      # Clear existing default marker(s) — there should only be one, but
      # be defensive in case of corrupted config.
      @models.each do |m|
        next if m["id"] == id
        m.delete("type") if m["type"] == "default"
      end

      target["type"] = "default"
      true
    end

    # List all model names
    def model_names
      @models.map { |m| m["model"] }
    end

    # Get API key for current model
    def api_key
      current_model&.dig("api_key")
    end

    # Set API key for current model
    def api_key=(value)
      return unless current_model
      current_model["api_key"] = value
    end

    # Get base URL for current model
    def base_url
      current_model&.dig("base_url")
    end

    # Set base URL for current model
    def base_url=(value)
      return unless current_model
      current_model["base_url"] = value
    end

    # Get model name for current model
    def model_name
      current_model&.dig("model")
    end

    # Set model name for current model
    def model_name=(value)
      return unless current_model
      current_model["model"] = value
    end

    # Check if should use Anthropic format for current model
    def anthropic_format?
      current_model&.dig("anthropic_format") || false
    end

    # Check if current model uses Bedrock Converse API (ABSK key prefix or abs- model prefix)
    def bedrock?
      Clacky::MessageFormat::Bedrock.bedrock_api_key?(api_key.to_s, model_name.to_s)
    end

    # Add a new model configuration
    def add_model(model:, api_key:, base_url:, anthropic_format: false, type: nil)
      @models << {
        "id" => SecureRandom.uuid,
        "api_key" => api_key,
        "base_url" => base_url,
        "model" => model,
        "anthropic_format" => anthropic_format,
        "type" => type
      }.compact
    end

    # Find model by type (default or lite)
    # Returns the model hash or nil if not found
    def find_model_by_type(type)
      @models.find { |m| m["type"] == type }
    end

    # Get the default model (type: default)
    # Falls back to current_model for backward compatibility
    def default_model
      find_model_by_type("default") || current_model
    end

    # Get the lite model (type: lite)
    # Returns nil if no lite model configured
    def lite_model
      find_model_by_type("lite")
    end

    # How long to stay on the fallback model before probing the primary again.
    FALLBACK_COOLING_OFF_SECONDS = 30 * 60  # 30 minutes

    # Look up the fallback model name for the given model name.
    # Uses the provider preset's fallback_models table.
    # Returns nil if no fallback is configured for this model.
    # @param model_name [String] the primary model name (e.g. "abs-claude-sonnet-4-6")
    # @return [String, nil]
    def fallback_model_for(model_name)
      m = current_model
      return nil unless m

      provider_id = Clacky::Providers.find_by_base_url(m["base_url"])
      return nil unless provider_id

      Clacky::Providers.fallback_model(provider_id, model_name)
    end

    # Switch to fallback model and start the cooling-off clock.
    # Idempotent — calling again while already in :fallback_active renews the timestamp.
    # @param fallback_model_name [String] the fallback model to use
    def activate_fallback!(fallback_model_name)
      @fallback_state = :fallback_active
      @fallback_since = Time.now
      @fallback_model  = fallback_model_name
    end

    # Called at the start of every call_llm.
    # If cooling-off has expired, transition from :fallback_active → :probing
    # so the next request will silently test the primary model.
    # No-op in any other state.
    def maybe_start_probing
      return unless @fallback_state == :fallback_active
      return unless @fallback_since && (Time.now - @fallback_since) >= FALLBACK_COOLING_OFF_SECONDS

      @fallback_state = :probing
    end

    # Called when a successful API response is received.
    # If we were :probing (testing primary after cooling-off), this confirms
    # the primary model is healthy again and resets everything.
    # No-op in :primary_ok or :fallback_active states.
    def confirm_fallback_ok!
      return unless @fallback_state == :probing

      @fallback_state = nil
      @fallback_since = nil
      @fallback_model = nil
    end

    # Returns true when a fallback model is currently being used
    # (:fallback_active or :probing states).
    def fallback_active?
      @fallback_state == :fallback_active || @fallback_state == :probing
    end

    # Returns true only when we are silently probing the primary model.
    def probing?
      @fallback_state == :probing
    end

    # The effective model name to use for API calls.
    # - :primary_ok / nil → configured model_name (primary)
    # - :fallback_active   → fallback model
    # - :probing           → configured model_name (trying primary silently)
    def effective_model_name
      case @fallback_state
      when :fallback_active
        @fallback_model || model_name
      else
        # :primary_ok (nil) and :probing both use the primary model
        model_name
      end
    end

    # Get current model configuration.
    #
    # Resolution order:
    #   1. @current_model_id (primary source of truth — stable across list edits)
    #   2. type: default (for config.yml that sets a default explicitly)
    #   3. @current_model_index (back-compat for very old code paths)
    def current_model
      return nil if @models.empty?

      if @current_model_id
        m = @models.find { |mm| mm["id"] == @current_model_id }
        return m if m
        # id no longer exists (model was deleted). Fall through to other
        # resolution strategies below, and clear the stale id.
        @current_model_id = nil
      end

      default_model = find_model_by_type("default")
      if default_model
        # Opportunistically re-anchor to this default's id so subsequent
        # lookups are O(1) and survive list reordering.
        @current_model_id = default_model["id"]
        return default_model
      end

      # Fallback to index-based for backward compatibility
      m = @models[@current_model_index]
      @current_model_id = m["id"] if m
      m
    end

    # Set a model's type (default or lite)
    # Ensures only one model has each type
    # @param index [Integer] the model index
    # @param type [String, nil] "default", "lite", or nil to remove type
    # Returns true if successful
    def set_model_type(index, type)
      return false if index < 0 || index >= @models.length
      return false unless ["default", "lite", nil].include?(type)

      if type
        # Remove type from any other model that has it
        @models.each do |m|
          m.delete("type") if m["type"] == type
        end
        
        # Set type on target model
        @models[index]["type"] = type
      else
        # Remove type from target model
        @models[index].delete("type")
      end

      true
    end

    # Remove a model by index
    # Returns true if removed, false if index out of range or it's the last model
    def remove_model(index)
      # Don't allow removing the last model
      return false if @models.length <= 1
      return false if index < 0 || index >= @models.length

      removed = @models.delete_at(index)

      # Adjust current_model_index if necessary
      if @current_model_index >= @models.length
        @current_model_index = @models.length - 1
      end

      # If the removed model was the current one, clear @current_model_id.
      # current_model will then fall back to type: default / current_model_index.
      if removed && @current_model_id == removed["id"]
        @current_model_id = nil
      end

      true
    end

    private def validate_permission_mode(mode)
      mode ||= :confirm_safes
      mode = mode.to_sym

      unless PERMISSION_MODES.include?(mode)
        raise ArgumentError, "Invalid permission mode: #{mode}. Must be one of #{PERMISSION_MODES.join(', ')}"
      end

      mode
    end

    # Parse models from config data
    # Supports new top-level array format and old formats for backward compatibility
    private_class_method def self.parse_models(data)
      models = []

      # Handle nil or empty data
      return models if data.nil?

      if data.is_a?(Array)
        # New format: top-level array of model configurations
        models = data.map do |m|
          # Deep copy to avoid shared references between models
          m = m.dup.transform_values { |v| v.is_a?(String) ? v.dup : v }
          # Convert old name-based format to new model-based format if needed
          if m["name"] && !m["model"]
            m["model"] = m["name"]
            m.delete("name")
          end
          m
        end
      elsif data.is_a?(Hash) && data["models"]
        # Old format with "models:" key
        if data["models"].is_a?(Array)
          # Array under models key
          models = data["models"].map do |m|
            # Convert old name-based format to new model-based format
            if m["name"] && !m["model"]
              m["model"] = m["name"]
              m.delete("name")
            end
            m
          end
        elsif data["models"].is_a?(Hash)
          # Hash format with tier names as keys (very old format)
          data["models"].each do |tier_name, config|
            if config.is_a?(Hash)
              model_config = {
                "api_key" => config["api_key"],
                "base_url" => config["base_url"],
                "model" => config["model_name"] || config["model"] || tier_name,
                "anthropic_format" => config["anthropic_format"] || false
              }
              models << model_config
            elsif config.is_a?(String)
              # Old-style tier with just model name
              model_config = {
                "api_key" => data["api_key"],
                "base_url" => data["base_url"],
                "model" => config,
                "anthropic_format" => data["anthropic_format"] || false
              }
              models << model_config
            end
          end
        end
      elsif data.is_a?(Hash) && data["api_key"]
        # Very old format: single model with global config
        models << {
          "api_key" => data["api_key"],
          "base_url" => data["base_url"],
          "model" => data["model"] || CLAUDE_DEFAULT_MODEL,
          "anthropic_format" => data["anthropic_format"] || false
        }
      end

      # Inject a runtime-only stable id for each model. Ids are NOT written
      # back to config.yml (see `to_yaml`) so this is fully backward
      # compatible — old yml files without ids just get fresh ids on load.
      # The id is the source of truth for session→model identity and is
      # immune to list reordering, additions, and field edits (api_key, etc).
      models.each { |m| m["id"] ||= SecureRandom.uuid }

      models
    end
  end
end
