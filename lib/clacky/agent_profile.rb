# frozen_string_literal: true

require "yaml"

module Clacky
  # Loads and represents an agent profile (system prompt + skill whitelist).
  #
  # Lookup order for a profile named "coding":
  #   1. ~/.clacky/agents/coding/          (user override)
  #   2. <gem>/lib/clacky/default_agents/coding/  (built-in default)
  #
  # Each profile directory must contain:
  #   - profile.yml       — name, description, skills whitelist
  #   - system_prompt.md  — agent-specific system prompt content
  #
  # Global files (shared across all agents), also with user-override support:
  #   - SOUL.md   — agent personality/values
  #   - USER.md   — user profile information
  #   - base_prompt.md — universal behavioral rules (todo manager, tool usage, etc.)
  class AgentProfile
    DEFAULT_AGENTS_DIR = File.expand_path("../default_agents", __FILE__).freeze
    USER_AGENTS_DIR = File.expand_path("~/.clacky/agents").freeze

    attr_reader :name, :description, :skills

    def initialize(name)
      @name = name.to_s
      profile_data = load_profile_yml
      @description = profile_data["description"] || ""
      @skills = Array(profile_data["skills"])
      @system_prompt_content = load_agent_file("system_prompt.md")
    end

    # Load a named profile. Raises ArgumentError if profile directory not found.
    # @param name [String, Symbol] profile name (e.g. "coding", "general")
    # @return [AgentProfile]
    def self.load(name)
      new(name)
    end

    # @return [String] agent-specific system prompt content
    def system_prompt
      @system_prompt_content
    end

    # @return [String] base prompt shared by all agents
    def base_prompt
      load_global_file("base_prompt.md")
    end

    # @return [String] soul content (user override → built-in default)
    def soul
      load_global_file("SOUL.md")
    end

    # @return [String] user profile content (user override → built-in default)
    def user_profile
      load_global_file("USER.md")
    end

    # @return [Boolean] whether a given skill name is allowed for this profile
    def skill_allowed?(skill_name)
      @skills.include?(skill_name.to_s)
    end

    private def load_profile_yml
      path = find_agent_file("profile.yml")
      raise ArgumentError, "Agent profile '#{@name}' not found. " \
        "Looked in #{user_agent_dir} and #{default_agent_dir}" unless path

      YAML.safe_load(File.read(path)) || {}
    end

    # Load a file from the agent-specific directory (user override → built-in)
    private def load_agent_file(filename)
      path = find_agent_file(filename)
      return "" unless path

      File.read(path).strip
    end

    # Load a global file shared across all agents (user override → built-in)
    private def load_global_file(filename)
      user_path = File.join(USER_AGENTS_DIR, filename)
      default_path = File.join(DEFAULT_AGENTS_DIR, filename)

      path = if File.exist?(user_path) && !File.zero?(user_path)
               user_path
             elsif File.exist?(default_path)
               default_path
             end

      return "" unless path

      File.read(path).strip
    end

    # Find a file in user override dir first, then built-in default dir
    private def find_agent_file(filename)
      user_path = File.join(user_agent_dir, filename)
      default_path = File.join(default_agent_dir, filename)

      if File.exist?(user_path) && !File.zero?(user_path)
        user_path
      elsif File.exist?(default_path)
        default_path
      end
    end

    private def user_agent_dir
      File.join(USER_AGENTS_DIR, @name)
    end

    private def default_agent_dir
      File.join(DEFAULT_AGENTS_DIR, @name)
    end
  end
end
