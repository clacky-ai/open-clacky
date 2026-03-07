# frozen_string_literal: true

require "yaml"
require "pathname"

module Clacky
  # Represents a skill with its metadata and content.
  # A skill is defined by a SKILL.md file with optional YAML frontmatter.
  class Skill
    # Frontmatter fields that are recognized
    FRONTMATTER_FIELDS = %w[
      name
      description
      disable-model-invocation
      user-invocable
      allowed-tools
      context
      agent
      argument-hint
      hooks
      fork_agent
      model
      forbidden_tools
      auto_summarize
    ].freeze

    attr_reader :directory, :frontmatter, :source_path
    attr_reader :name, :description, :content
    attr_reader :disable_model_invocation, :user_invocable
    attr_reader :allowed_tools, :context, :agent_type, :argument_hint, :hooks
    attr_reader :fork_agent, :model, :forbidden_tools, :auto_summarize
    attr_reader :brand_skill, :brand_config

    # Check if this skill is disabled (disable-model-invocation: true)
    # @return [Boolean]
    def disabled?
      @disable_model_invocation == true
    end


    # @param directory [Pathname, String] Path to the skill directory
    # @param source_path [Pathname, String, nil] Optional source path for priority resolution
    # @param brand_skill [Boolean] When true, content is loaded from an encrypted
    #   SKILL.md.enc file via BrandConfig#decrypt_skill_content at invoke time.
    #   The on-disk file is never read as plain text.
    # @param brand_config [BrandConfig, nil] Required when brand_skill is true.
    def initialize(directory, source_path: nil, brand_skill: false, brand_config: nil)
      @directory   = Pathname.new(directory)
      @source_path = source_path ? Pathname.new(source_path) : @directory
      @brand_skill = brand_skill
      @brand_config = brand_config

      load_skill
    end

    # Get the skill identifier (uses name from frontmatter or directory name)
    # @return [String]
    def identifier
      @name || @directory.basename.to_s
    end

    # Check if skill can be invoked by user via slash command
    # @return [Boolean]
    def user_invocable?
      @user_invocable.nil? || @user_invocable
    end

    # Check if skill can be automatically invoked by the model
    # @return [Boolean]
    def model_invocation_allowed?
      !@disable_model_invocation
    end

    # Check if this skill should fork a subagent
    # @return [Boolean]
    def fork_agent?
      @fork_agent == true
    end

    # Get the model to use for the subagent (if fork_agent is true)
    # @return [String, nil]
    def subagent_model
      @model
    end

    # Get the list of forbidden tools for the subagent
    # @return [Array<String>]
    def forbidden_tools_list
      @forbidden_tools || []
    end

    # Check if subagent should auto-summarize results
    # @return [Boolean]
    def auto_summarize?
      @auto_summarize != false
    end

    # Get the slash command for this skill
    # @return [String] e.g., "/explain-code"
    def slash_command
      "/#{identifier}"
    end

    # Get the description for context loading
    # Returns the description from frontmatter, or first paragraph of content
    # @return [String]
    def context_description
      @description || extract_first_paragraph
    end

    # Get all supporting files in the skill directory (excluding SKILL.md)
    # @return [Array<Pathname>]
    def supporting_files
      return [] unless @directory.exist?

      @directory.children.reject { |p| p.basename.to_s == "SKILL.md" }
    end

    # Check if this skill has supporting files
    # @return [Boolean]
    def has_supporting_files?
      supporting_files.any?
    end

    # Process the skill content with argument substitution
    # @param arguments [String] Arguments passed to the skill
    # @param shell_output [Hash] Shell command outputs for !command` syntax (optional)
    # @return [String] Processed content
    def process_content(arguments = "", shell_output: {})
      # For brand skills, decrypt content in memory at invoke time.
      # For plain skills, use the already-loaded @content.
      processed_content = decrypted_content.dup

      # Replace argument placeholders
      processed_content = substitute_arguments(processed_content, arguments)

      # Replace shell command outputs
      shell_output.each do |command, output|
        placeholder = "!`#{command}`"
        processed_content.gsub!(placeholder, output.to_s)
      end

      # Append supporting files list if any exist
      if has_supporting_files?
        processed_content += "\n\n## Supporting Files\n\n"
        processed_content += "The following files are available in this skill's directory:\n\n"
        supporting_files.each do |file|
          relative_path = file.relative_path_from(@directory)
          processed_content += "- `#{relative_path}`\n"
        end
      end

      processed_content
    end

    # Convert to a hash representation
    # @return [Hash]
    def to_h
      {
        name: identifier,
        description: context_description,
        directory: @directory.to_s,
        source_path: @source_path.to_s,
        user_invocable: user_invocable?,
        model_invocation_allowed: model_invocation_allowed?,
        fork_agent: fork_agent?,
        subagent_model: @model,
        forbidden_tools: @forbidden_tools,
        allowed_tools: @allowed_tools,
        argument_hint: @argument_hint,
        content_length: encrypted? ? nil : @content&.length
      }
    end

    # Load content of a supporting file
    # @param filename [String] Relative path from skill directory
    # @return [String, nil] File contents or nil if not found
    def read_supporting_file(filename)
      file_path = @directory.join(filename)
      file_path.exist? ? file_path.read : nil
    end

    # Returns true when this skill's content is stored encrypted on disk.
    # @return [Boolean]
    def encrypted?
      @brand_skill == true
    end

    # Decrypt and return the raw skill content.
    #
    # For brand skills the content lives in SKILL.md.enc and is decrypted
    # in memory via BrandConfig#decrypt_skill_content — it is never written
    # to disk as plain text.
    #
    # For regular skills this is identical to reading @content directly.
    #
    # @return [String] Plain-text SKILL.md body (without frontmatter)
    # @raise [RuntimeError] If the brand_config is missing or decryption fails
    def decrypted_content
      return @content unless encrypted?

      raise "brand_config is required to decrypt brand skill '#{identifier}'" unless @brand_config

      enc_path = @directory.join("SKILL.md.enc").to_s
      raw = @brand_config.decrypt_skill_content(enc_path)

      # Strip frontmatter from the decrypted bytes so callers get only the body
      if raw.start_with?("---")
        fm_match = raw.match(/\A---\n.*?\n---\n*/m)
        fm_match ? raw[fm_match.end(0)..].strip : raw
      else
        raw
      end
    end

    private

    def load_skill
      if @brand_skill
        load_brand_skill
      else
        load_plain_skill
      end

      # Set defaults
      @user_invocable = true if @user_invocable.nil?
      @disable_model_invocation = false if @disable_model_invocation.nil?

      validate_frontmatter
    end

    # Load a plain (unencrypted) skill from SKILL.md
    private def load_plain_skill
      skill_file = @directory.join("SKILL.md")

      unless skill_file.exist?
        raise Clacky::AgentError, "SKILL.md not found in skill directory: #{@directory}"
      end

      content = skill_file.read

      if content.start_with?("---")
        parse_frontmatter(content)
      else
        @frontmatter = {}
        @content = content
      end
    end

    # Load a brand (encrypted) skill from SKILL.md.enc.
    #
    # Only the frontmatter is parsed at load time so the agent can build the
    # skill list (name, description) without decrypting the full content.
    # The body is decrypted lazily via #decrypted_content when the skill is
    # actually invoked.
    private def load_brand_skill
      enc_file = @directory.join("SKILL.md.enc")

      unless enc_file.exist?
        raise Clacky::AgentError, "SKILL.md.enc not found in brand skill directory: #{@directory}"
      end

      raise "brand_config is required to load brand skill" unless @brand_config

      # Decrypt once at load time to parse frontmatter; the result is kept only
      # in memory and discarded after this method returns.
      raw = @brand_config.decrypt_skill_content(enc_file.to_s)

      if raw.start_with?("---")
        parse_frontmatter(raw)
      else
        @frontmatter = {}
        @content = raw
      end

      # Clear content from memory — it will be re-decrypted at invoke time
      # via #decrypted_content so the plain text is never held in a long-lived object.
      @content = nil
    end

    def parse_frontmatter(content)
      # Extract frontmatter between first and second "---"
      frontmatter_match = content.match(/^---\n(.*?)\n---/m)

      unless frontmatter_match
        raise Clacky::AgentError, "Invalid frontmatter format in SKILL.md: missing closing ---"
      end

      yaml_content = frontmatter_match[1]
      @frontmatter = YAML.safe_load(yaml_content) || {}

      # Extract content after frontmatter
      @content = content[frontmatter_match.end(0)..-1].to_s.strip

      # Extract fields from frontmatter
      @name = @frontmatter["name"]
      @description = @frontmatter["description"]
      @disable_model_invocation = @frontmatter["disable-model-invocation"]
      @user_invocable = @frontmatter["user-invocable"]
      @allowed_tools = @frontmatter["allowed-tools"]
      @context = @frontmatter["context"]
      @agent_type = @frontmatter["agent"]
      @argument_hint = @frontmatter["argument-hint"]
      @hooks = @frontmatter["hooks"]
      
      # Subagent configuration
      @fork_agent = @frontmatter["fork_agent"]
      @model = @frontmatter["model"]
      @forbidden_tools = @frontmatter["forbidden_tools"]
      @auto_summarize = @frontmatter["auto_summarize"]
    end

    def validate_frontmatter
      # Validate name if provided
      if @name
        unless @name.match?(/^[a-z0-9][a-z0-9-]*$/)
          raise Clacky::AgentError,
            "Invalid skill name '#{@name}'. Use lowercase letters, numbers, and hyphens only (max 64 chars)."
        end
        if @name.length > 64
          raise Clacky::AgentError, "Skill name '#{@name}' exceeds 64 characters."
        end
      end

      # Validate forbidden_tools format
      if @forbidden_tools && !@forbidden_tools.is_a?(Array)
        raise Clacky::AgentError, "forbidden_tools must be an array of tool names"
      end

      # Validate allowed-tools format
      if @allowed_tools && !@allowed_tools.is_a?(Array)
        raise Clacky::AgentError, "allowed-tools must be an array of tool names"
      end
    end

    def extract_first_paragraph
      @content.split(/\n\n/).first.to_s
    end

    def substitute_arguments(content, arguments)
      # Split arguments by whitespace for indexed access ($0, $1, $ARGUMENTS[N]).
      # Skill arguments are natural language, not shell commands — shellsplit is
      # intentionally avoided here to prevent errors on apostrophes and other
      # characters that have special meaning in shell but not in plain text.
      args_array = arguments.split

      # Replace $ARGUMENTS with all arguments
      result = content.gsub("$ARGUMENTS", arguments.to_s)

      # Replace $ARGUMENTS[N] with specific argument
      result.gsub!(/\$ARGUMENTS\[(\d+)\]/) do
        index = $1.to_i
        args_array[index] || ""
      end

      # Replace $N shorthand ($0, $1, etc.)
      result.gsub!(/\$([0-9]+)/) do
        index = $1.to_i
        args_array[index] || ""
      end

      # Replace ${CLAUDE_SESSION_ID} with empty string (session not available in current context)
      result.gsub!(/\${CLAUDE_SESSION_ID}/, "")

      result
    end
  end
end
