# frozen_string_literal: true

require "yaml"
require "json"
require "fileutils"

module Clacky
  # McpConfig manages MCP (Model Context Protocol) server configurations.
  #
  # MCP servers can be configured at two levels (lower index = lower priority):
  #   1. User-level:    ~/.clacky/mcp.yml
  #   2. Project-level: <working_dir>/.clacky/mcp.yml  (overrides user-level per-key)
  #
  # Both files share the same YAML format. Project-level entries take precedence
  # over user-level entries when they have the same server name.
  #
  # Supported transport types:
  #
  #   stdio  — launch a local subprocess and communicate over stdin/stdout
  #   sse    — connect to a remote Server-Sent Events endpoint
  #   http   — connect to a remote Streamable HTTP endpoint
  #
  # Example ~/.clacky/mcp.yml:
  #
  #   mcpServers:
  #     filesystem:
  #       type: stdio
  #       command: npx
  #       args:
  #         - "-y"
  #         - "@modelcontextprotocol/server-filesystem"
  #         - "/Users/me/projects"
  #       env:
  #         NODE_ENV: production
  #
  #     github:
  #       type: sse
  #       url: https://mcp.github.com/sse
  #       headers:
  #         Authorization: "Bearer ghp_xxxx"
  #
  #     custom_api:
  #       type: http
  #       url: https://my-mcp.example.com/mcp
  #       headers:
  #         X-Api-Key: "secret"
  #
  class McpConfig
    # User-level config file
    USER_CONFIG_FILE = File.join(Dir.home, ".clacky", "mcp.yml")

    # Valid transport types
    VALID_TYPES = %w[stdio sse http].freeze

    # Required fields per transport type
    REQUIRED_FIELDS = {
      "stdio" => %w[command],
      "sse"   => %w[url],
      "http"  => %w[url]
    }.freeze

    # @param servers [Hash<String, Hash>] merged server configs (string-keyed)
    # @param source_map [Hash<String, Symbol>] tracks origin of each server: :user or :project
    def initialize(servers: {}, source_map: {})
      @servers   = servers   || {}
      @source_map = source_map || {}
    end

    # Load and merge configs from user-level and project-level.
    #
    # Merge strategy: project-level server entries completely override
    # user-level entries with the same name (no deep merge within a server).
    #
    # @param working_dir [String, nil] project root directory. When nil, only
    #   user-level config is loaded.
    # @param user_config_file [String] path to user config (override for tests)
    # @return [McpConfig]
    def self.load(working_dir: nil, user_config_file: USER_CONFIG_FILE)
      servers    = {}
      source_map = {}

      # 1. Load user-level config (lowest priority)
      user_servers = load_file(user_config_file)
      user_servers.each do |name, cfg|
        servers[name]     = cfg
        source_map[name]  = :user
      end

      # 2. Load project-level config (higher priority, overrides user-level)
      if working_dir
        project_config_file = File.join(working_dir, ".clacky", "mcp.yml")
        project_servers = load_file(project_config_file)
        project_servers.each do |name, cfg|
          servers[name]     = cfg
          source_map[name]  = :project
        end
      end

      new(servers: servers, source_map: source_map)
    end

    # Whether any MCP servers are configured.
    # @return [Boolean]
    def any?
      @servers.any?
    end

    # Total number of configured servers.
    # @return [Integer]
    def count
      @servers.size
    end

    # All server names.
    # @return [Array<String>]
    def server_names
      @servers.keys
    end

    # Return raw config hash for a named server, or nil if not found.
    # @param name [String]
    # @return [Hash, nil]
    def server(name)
      @servers[name.to_s]
    end

    # Return origin of a named server (:user, :project, or nil).
    # @param name [String]
    # @return [Symbol, nil]
    def source_of(name)
      @source_map[name.to_s]
    end

    # Return all servers as an array of hashes with the name embedded.
    # @return [Array<Hash>]
    def all_servers
      @servers.map do |name, cfg|
        cfg.merge("name" => name, "_source" => @source_map[name])
      end
    end

    # Validate all configured servers. Returns a hash of:
    #   { server_name => [error_message, ...] }
    # An empty hash means everything is valid.
    # @return [Hash<String, Array<String>>]
    def validate
      errors = {}

      @servers.each do |name, cfg|
        errs = validate_server(name, cfg)
        errors[name] = errs unless errs.empty?
      end

      errors
    end

    # Returns true when all servers pass validation.
    # @return [Boolean]
    def valid?
      validate.empty?
    end

    # Add or update a server entry in-memory (does not persist to disk).
    # @param name [String] server identifier
    # @param config [Hash] server configuration
    # @param source [Symbol] :user or :project
    def set_server(name, config, source: :user)
      @servers[name.to_s]    = config
      @source_map[name.to_s] = source
    end

    # Remove a server entry from in-memory config.
    # @param name [String]
    def remove_server(name)
      @servers.delete(name.to_s)
      @source_map.delete(name.to_s)
    end

    # Serialize user-level servers (source == :user) to YAML string.
    # @return [String]
    def to_yaml_user
      user_servers = @servers.select { |n, _| @source_map[n] == :user }
      YAML.dump({ "mcpServers" => user_servers })
    end

    # Serialize project-level servers (source == :project) to YAML string.
    # @return [String]
    def to_yaml_project
      project_servers = @servers.select { |n, _| @source_map[n] == :project }
      YAML.dump({ "mcpServers" => project_servers })
    end

    # Persist user-level servers to the user config file.
    # @param user_config_file [String]
    def save_user(user_config_file = USER_CONFIG_FILE)
      FileUtils.mkdir_p(File.dirname(user_config_file))
      File.write(user_config_file, to_yaml_user)
      FileUtils.chmod(0o600, user_config_file)
    end

    # Persist project-level servers to the project config file.
    # @param working_dir [String] project root directory
    def save_project(working_dir)
      project_file = File.join(working_dir, ".clacky", "mcp.yml")
      FileUtils.mkdir_p(File.dirname(project_file))
      File.write(project_file, to_yaml_project)
      FileUtils.chmod(0o600, project_file)
    end

    # Deep copy — prevents callers from mutating shared state.
    # @return [McpConfig]
    def deep_copy
      self.class.new(
        servers:    JSON.parse(JSON.generate(@servers)),
        source_map: @source_map.dup
      )
    end

    # Human-readable summary of configured servers (useful for debugging).
    # @return [String]
    def inspect
      lines = ["McpConfig (#{count} server(s)):"]
      @servers.each do |name, cfg|
        src  = @source_map[name] || :unknown
        type = cfg["type"] || "unknown"
        lines << "  [#{src}] #{name} (#{type})"
      end
      lines.join("\n")
    end

    # -------------------------------------------------------------------------
    # Class-level private helpers
    # -------------------------------------------------------------------------

    # Load and parse a single YAML config file.
    # Returns empty hash when the file does not exist or has no servers.
    # @param path [String]
    # @return [Hash<String, Hash>]
    def self.load_file(path)
      return {} unless File.exist?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
      servers = data["mcpServers"] || {}

      unless servers.is_a?(Hash)
        warn "[McpConfig] #{path}: 'mcpServers' must be a Hash, got #{servers.class}. Skipping."
        return {}
      end

      # Normalize: ensure all keys and nested values are string-keyed
      servers.transform_keys(&:to_s).transform_values do |cfg|
        cfg.is_a?(Hash) ? cfg.transform_keys(&:to_s) : cfg
      end
    rescue => e
      warn "[McpConfig] Failed to load #{path}: #{e.message}"
      {}
    end

    private_class_method :load_file

    # Validate a single server config and return array of error strings.
    # @param name [String]
    # @param cfg [Hash]
    # @return [Array<String>]
    private def validate_server(name, cfg)
      errs = []

      unless cfg.is_a?(Hash)
        return ["'#{name}' config must be a Hash, got #{cfg.class}"]
      end

      type = cfg["type"]

      if type.nil? || type.empty?
        errs << "missing required field 'type' (must be one of: #{VALID_TYPES.join(', ')})"
        return errs
      end

      unless VALID_TYPES.include?(type)
        errs << "invalid type '#{type}' (must be one of: #{VALID_TYPES.join(', ')})"
        return errs
      end

      # Check required fields for this transport type
      REQUIRED_FIELDS[type].each do |field|
        val = cfg[field]
        if val.nil? || (val.respond_to?(:empty?) && val.empty?)
          errs << "missing required field '#{field}' for type '#{type}'"
        end
      end

      # stdio-specific validations
      if type == "stdio"
        cmd = cfg["command"]
        errs << "'command' must be a non-empty String" unless cmd.is_a?(String) && !cmd.empty?

        args = cfg["args"]
        if args && !args.is_a?(Array)
          errs << "'args' must be an Array"
        end

        env = cfg["env"]
        if env && !env.is_a?(Hash)
          errs << "'env' must be a Hash"
        end
      end

      # sse / http URL validations
      if %w[sse http].include?(type)
        url = cfg["url"]
        errs << "'url' must be a non-empty String" unless url.is_a?(String) && !url.empty?

        if url.is_a?(String) && !url.empty?
          errs << "'url' must start with http:// or https://" unless url.match?(/\Ahttps?:\/\//i)
        end

        headers = cfg["headers"]
        if headers && !headers.is_a?(Hash)
          errs << "'headers' must be a Hash"
        end
      end

      errs
    end
  end
end
