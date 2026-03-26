# frozen_string_literal: true

require "yaml"
require "fileutils"
require "json"

module Clacky
  # ChannelConfig manages IM platform credentials (Feishu, WeCom, etc.).
  #
  # Config is stored in ~/.clacky/channels.yml:
  #
  #   channels:
  #     feishu:
  #       enabled: true
  #       app_id: cli_xxx
  #       app_secret: xxx
  #       domain: https://open.feishu.cn
  #       allowed_users:
  #         - ou_xxx
  #     wecom:
  #       enabled: false
  #       bot_id: xxx
  #       secret: xxx
  #
  # This class is only responsible for platform credentials.
  # working_dir and permission_mode live in AgentConfig.
  class ChannelConfig
    CONFIG_DIR  = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "channels.yml")

    # @param channels [Hash<String, Hash>] string-keyed platform configs (raw from YAML)
    def initialize(channels: {})
      @channels = channels || {}
    end

    # Load from disk. Returns an empty instance if the file does not exist.
    # @param config_file [String]
    # @return [ChannelConfig]
    def self.load(config_file = CONFIG_FILE)
      if File.exist?(config_file)
        data = YAMLCompat.safe_load(File.read(config_file), permitted_classes: [Symbol]) || {}
      else
        data = {}
      end

      new(channels: data["channels"] || {})
    end

    # Persist to disk.
    # @param config_file [String]
    def save(config_file = CONFIG_FILE)
      FileUtils.mkdir_p(File.dirname(config_file))
      File.write(config_file, to_yaml)
      FileUtils.chmod(0o600, config_file)
    end

    # Serialize to YAML string.
    # @return [String]
    def to_yaml
      YAML.dump({ "channels" => @channels })
    end

    # Returns true if at least one channel is enabled.
    def any_enabled?
      @channels.any? { |_, cfg| cfg["enabled"] }
    end

    # Returns the list of enabled platform symbols.
    # @return [Array<Symbol>]
    def enabled_platforms
      @channels
        .select { |_, cfg| cfg["enabled"] }
        .keys
        .map(&:to_sym)
    end

    # Returns true if the given platform is configured and enabled.
    # @param platform [Symbol, String]
    def enabled?(platform)
      cfg = @channels[platform.to_s]
      cfg && cfg["enabled"]
    end

    # Return the symbol-keyed config hash expected by each adapter's initializer.
    # Returns nil if the platform is not configured.
    #
    # @param platform [Symbol, String]
    # @return [Hash, nil]
    def platform_config(platform)
      raw = @channels[platform.to_s]
      return nil unless raw

      case platform.to_sym
      when :feishu
        {
          app_id:        raw["app_id"],
          app_secret:    raw["app_secret"],
          domain:        raw["domain"],
          allowed_users: raw["allowed_users"]
        }.compact
      when :wecom
        {
          bot_id: raw["bot_id"],
          secret: raw["secret"]
        }.compact
      when :weixin
        {
          token:         raw["token"],
          base_url:      raw["base_url"],
          allowed_users: raw["allowed_users"]
        }.compact
      else
        # Unknown platform — pass all non-meta keys as symbol-keyed hash
        raw.reject { |k, _| k == "enabled" }
           .transform_keys(&:to_sym)
      end
    end

    # Set or update a platform's credentials.
    # Merges provided fields into the existing entry.
    # Automatically sets enabled: true unless explicitly provided.
    #
    # @param platform [Symbol, String]
    # @param fields [Hash] symbol-keyed credential fields
    def set_platform(platform, **fields)
      key = platform.to_s
      @channels[key] ||= {}
      fields.each { |k, v| @channels[key][k.to_s] = v }
      @channels[key]["enabled"] = true unless @channels[key].key?("enabled")
    end

    # Disable a platform (keeps credentials, just sets enabled: false).
    # @param platform [Symbol, String]
    def disable_platform(platform)
      key = platform.to_s
      return unless @channels.key?(key)
      @channels[key]["enabled"] = false
    end

    # Remove a platform entry entirely.
    # @param platform [Symbol, String]
    def remove_platform(platform)
      @channels.delete(platform.to_s)
    end

    # Deep copy — prevents callers from mutating shared config state.
    # @return [ChannelConfig]
    def deep_copy
      self.class.new(channels: JSON.parse(JSON.generate(@channels)))
    end
  end
end
