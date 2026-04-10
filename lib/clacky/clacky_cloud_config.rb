# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  # ClackyCloudConfig — stores the Clacky Cloud credentials used for workspace-key
  # import (workspace_api_key + backend base_url) in a dedicated file so the user
  # never has to re-enter them.
  #
  # File location: ~/.clacky/clacky_cloud.yml
  # File format (YAML):
  #   workspace_key: clacky_ak_xxxx
  #   base_url: https://api.clacky.ai
  #   dashboard_url: https://app.clacky.ai   # optional, inferred from base_url if absent
  #
  # Usage:
  #   cfg = ClackyCloudConfig.load
  #   cfg.workspace_key   # => "clacky_ak_xxxx" or nil
  #   cfg.base_url        # => "https://api.clacky.ai"
  #   cfg.dashboard_url   # => "https://app.clacky.ai"  (explicit or inferred)
  #   cfg.configured?     # => true / false
  #
  #   cfg.workspace_key = "clacky_ak_newkey"
  #   cfg.save
  class ClackyCloudConfig
    CONFIG_DIR  = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "clacky_cloud.yml")

    DEFAULT_BASE_URL      = "https://api.clacky.ai"
    DEFAULT_DASHBOARD_URL = "https://app.clacky.ai"

    attr_accessor :workspace_key, :base_url, :dashboard_url

    def initialize(workspace_key: nil, base_url: DEFAULT_BASE_URL, dashboard_url: nil)
      @workspace_key = workspace_key.to_s.strip
      @workspace_key = nil if @workspace_key.empty?
      @base_url      = (base_url.to_s.strip.empty? ? DEFAULT_BASE_URL : base_url.to_s.strip)
                         .sub(%r{/+$}, "")  # strip trailing slash

      # dashboard_url: use explicit value if provided, otherwise infer from base_url
      explicit = dashboard_url.to_s.strip.sub(%r{/+$}, "")
      @dashboard_url = explicit.empty? ? infer_dashboard_url(@base_url) : explicit
    end

    # Load from ~/.clacky/clacky_cloud.yml (returns an empty config if the file is absent)
    def self.load(config_file = CONFIG_FILE)
      if File.exist?(config_file)
        data = YAML.safe_load(File.read(config_file)) || {}
        new(
          workspace_key: data["workspace_key"],
          base_url:      data["base_url"]      || DEFAULT_BASE_URL,
          dashboard_url: data["dashboard_url"]
        )
      else
        new
      end
    rescue => e
      # Corrupt file — return empty config rather than crash
      warn "[clacky_cloud_config] Failed to load #{config_file}: #{e.message}"
      new
    end

    # Persist to ~/.clacky/clacky_cloud.yml
    def save(config_file = CONFIG_FILE)
      FileUtils.mkdir_p(File.dirname(config_file))
      File.write(config_file, to_yaml)
      FileUtils.chmod(0o600, config_file)
      self
    end

    # Serialize to YAML string
    def to_yaml
      data = { "base_url" => @base_url }
      data["workspace_key"]  = @workspace_key  if @workspace_key
      # Only persist dashboard_url when it differs from the inferred default,
      # so the file stays minimal for users who don't need to override it.
      inferred = infer_dashboard_url(@base_url)
      data["dashboard_url"]  = @dashboard_url  if @dashboard_url != inferred
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

    # Derive the dashboard web-app URL from the API base_url.
    #
    # Mapping rules:
    #   https://api.clacky.ai               -> https://app.clacky.ai
    #   https://<env>.api.clackyai.com      -> https://<env>.app.clackyai.com
    #   http://localhost:<port>             -> http://localhost:3001
    #   (anything else)                     -> https://app.clacky.ai  (safe default)
    private def infer_dashboard_url(api_url)
      return DEFAULT_DASHBOARD_URL if api_url.nil? || api_url.strip.empty?

      # Production: api.clacky.ai -> app.clacky.ai
      return "https://app.clacky.ai" if api_url == "https://api.clacky.ai"

      # Staging/dev on clackyai.com: <env>.api.clackyai.com -> <env>.app.clackyai.com
      if api_url =~ %r{\Ahttps?://(.+)\.api\.clackyai\.com\z}
        env_prefix = Regexp.last_match(1)
        scheme     = api_url.start_with?("https") ? "https" : "http"
        return "#{scheme}://#{env_prefix}.app.clackyai.com"
      end

      # Local development: localhost:<port> -> localhost:3001
      if api_url =~ %r{\Ahttps?://localhost(:\d+)?\z}
        scheme = api_url.start_with?("https") ? "https" : "http"
        return "#{scheme}://localhost:3001"
      end

      # Fallback: return production dashboard
      DEFAULT_DASHBOARD_URL
    end
  end
end
