# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  # PlatformConfig — stores the Clacky platform credentials used for workspace-key
  # import (workspace_api_key + backend base_url) in a dedicated file so the user
  # never has to re-enter them.
  #
  # File location: ~/.clacky/platform.yml
  # File format (YAML):
  #   workspace_key: clacky_ak_xxxx
  #   base_url: https://api.clacky.ai
  #
  # Usage:
  #   cfg = PlatformConfig.load
  #   cfg.workspace_key  # => "clacky_ak_xxxx" or nil
  #   cfg.base_url       # => "https://api.clacky.ai"
  #   cfg.configured?    # => true / false
  #
  #   cfg.workspace_key = "clacky_ak_newkey"
  #   cfg.save
  class PlatformConfig
    CONFIG_DIR  = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "platform.yml")

    DEFAULT_BASE_URL = "https://api.clacky.ai"

    attr_accessor :workspace_key, :base_url

    def initialize(workspace_key: nil, base_url: DEFAULT_BASE_URL)
      @workspace_key = workspace_key.to_s.strip
      @workspace_key = nil if @workspace_key.empty?
      @base_url      = (base_url.to_s.strip.empty? ? DEFAULT_BASE_URL : base_url.to_s.strip)
                         .sub(%r{/+$}, "")  # strip trailing slash
    end

    # Load from ~/.clacky/platform.yml (returns an empty config if the file is absent)
    def self.load(config_file = CONFIG_FILE)
      if File.exist?(config_file)
        data = YAML.safe_load(File.read(config_file)) || {}
        new(
          workspace_key: data["workspace_key"],
          base_url:      data["base_url"] || DEFAULT_BASE_URL
        )
      else
        new
      end
    rescue => e
      # Corrupt file — return empty config rather than crash
      warn "[platform_config] Failed to load #{config_file}: #{e.message}"
      new
    end

    # Persist to ~/.clacky/platform.yml
    def save(config_file = CONFIG_FILE)
      FileUtils.mkdir_p(File.dirname(config_file))
      File.write(config_file, to_yaml)
      FileUtils.chmod(0o600, config_file)
      self
    end

    # Serialize to YAML string
    def to_yaml
      data = { "base_url" => @base_url }
      data["workspace_key"] = @workspace_key if @workspace_key
      YAML.dump(data)
    end

    # True when a non-empty workspace_key is stored
    def configured?
      !@workspace_key.nil? && !@workspace_key.empty?
    end

    # Remove the saved file (used for reset / tests)
    def self.clear!(config_file = CONFIG_FILE)
      FileUtils.rm_f(config_file)
    end
  end
end
