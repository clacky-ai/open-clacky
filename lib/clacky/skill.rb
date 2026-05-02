# frozen_string_literal: true

require "yaml"
require "pathname"
require_relative "utils/file_ignore_helper"
require_relative "utils/gitignore_parser"

module Clacky
  # Represents a skill with its metadata and content.
  # A skill is defined by a SKILL.md file with optional YAML frontmatter.
  class Skill
    # Frontmatter fields that are recognized
    FRONTMATTER_FIELDS = %w[
      name
      name_zh
      description
      description_zh
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
    attr_reader :name, :description, :name_zh, :description_zh, :content
    attr_reader :disable_model_invocation, :user_invocable
    attr_reader :allowed_tools, :context, :agent_type, :argument_hint, :hooks
    attr_reader :fork_agent, :model, :forbidden_tools, :auto_summarize
    attr_reader :brand_skill, :brand_config

    # Source location of this skill — set by SkillLoader after registration.
    # One of: :default, :global_claude, :global_clacky, :project_claude, :project_clacky, :brand
    # @return [Symbol, nil]
    attr_accessor :source

    # Warnings accumulated during load (e.g. name was invalid and fell back to dir name).
    # Non-empty means the skill loaded but something was auto-corrected.
    # @return [Array<String>]
    attr_reader :warnings

    # When true the skill has an unrecoverable metadata problem (e.g. directory name
    # is itself an invalid slug).  The skill is still registered so it can be shown
    # in the UI (greyed-out with an explanation), but it is excluded from the system
    # prompt and slash command dispatch.
    # @return [Boolean]
    attr_reader :invalid

    # Human-readable reason why the skill is invalid (nil when valid).
    # @return [String, nil]
    attr_reader :invalid_reason

    # Check if this skill is disabled (disable-model-invocation: true)
    # @return [Boolean]
    def disabled?
      @disable_model_invocation == true
    end

    # @return [Boolean]
    def invalid?
      @invalid == true
    end

    # @return [Boolean]
    def has_warnings?
      @warnings&.any?
    end


    # @param directory [Pathname, String] Path to the skill directory
    # @param source_path [Pathname, String, nil] Optional source path for priority resolution
    # @param brand_skill [Boolean] When true, content is loaded from an encrypted
    #   SKILL.md.enc file via BrandConfig#decrypt_skill_content at invoke time.
    #   The on-disk file is never read as plain text.
    # @param brand_config [BrandConfig, nil] Required when brand_skill is true.
    # @param cached_metadata [Hash, nil] Pre-loaded name/description from brand_skills.json.
    #   When provided for brand skills, avoids decrypting the file at load time.
    #   Expected keys: "name", "description".
    def initialize(directory, source_path: nil, brand_skill: false, brand_config: nil, cached_metadata: nil)
      @directory       = Pathname.new(directory)
      @source_path     = source_path ? Pathname.new(source_path) : @directory
      @brand_skill     = brand_skill
      @brand_config    = brand_config
      @cached_metadata = cached_metadata
      @encrypted       = false
      @warnings        = []
      @invalid         = false
      @invalid_reason  = nil

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

    # Get the agent scope for this skill.
    # Parsed from the `agent:` frontmatter field.
    # Returns an array of agent names, or ["all"] if not specified.
    # @return [Array<String>]
    def agents_scope
      return ["all"] if @agent_type.nil?

      case @agent_type
      when "all" then ["all"]
      when Array then @agent_type.map(&:to_s)
      else [@agent_type.to_s]
      end
    end

    # Check if this skill is allowed for the given agent profile name.
    # Returns true when the skill's `agent:` field is "all" (default) or
    # includes the given profile name.
    # @param profile_name [String] e.g. "coding", "general"
    # @return [Boolean]
    def allowed_for_agent?(profile_name)
      scope = agents_scope
      scope.include?("all") || scope.include?(profile_name.to_s)
    end

    # Get the slash command for this skill
    # @return [String] e.g., "/explain-code"
    def slash_command
      "/#{identifier}"
    end

    # Maximum length for a skill's description when injected into the system
    # prompt. Descriptions longer than this are truncated to protect the token
    # budget — a good description is a trigger hint, not a tutorial. Authors
    # still see their full description via `skill.description`; only the
    # system-prompt rendering is truncated.
    #
    # Anthropic's hard limit is 1024, but empirically ~300 chars is enough for
    # reliable triggering (including trigger-phrase lists); longer content
    # belongs in the SKILL.md body.
    DESCRIPTION_MAX_CHARS = 300

    # Get the description for context loading.
    # Returns the description from frontmatter (or first paragraph of content),
    # hard-capped at {DESCRIPTION_MAX_CHARS} so a single overlong skill can't
    # blow up the system prompt. Truncation is marked with an ellipsis.
    # @return [String]
    def context_description
      raw = @description || extract_first_paragraph
      return raw if raw.nil? || raw.length <= DESCRIPTION_MAX_CHARS

      raw[0, DESCRIPTION_MAX_CHARS - 1] + "…"
    end

    # Get all supporting files in the skill directory (excluding SKILL.md)
    # @return [Array<Pathname>]
    # Return plain-text supporting files for this skill (non-encrypted skills only).
    # For encrypted skills this always returns [] — the decrypted files live in a
    # tmpdir created by SkillManager at invoke time (see has_supporting_scripts?).
    # @return [Array<Pathname>]
    def supporting_files
      return [] unless @directory.exist?
      return [] if encrypted?

      dir = @directory.to_s
      gitignore_path = Utils::FileIgnoreHelper.find_gitignore(dir)
      gitignore = gitignore_path ? GitignoreParser.new(gitignore_path) : nil

      Dir.glob(File.join(dir, "**", "*"))
         .reject { |f| File.directory?(f) }
         .reject { |f| File.basename(f) == "SKILL.md" }
         .reject { |f| Utils::FileIgnoreHelper.should_ignore_file?(f, dir, gitignore) }
         .map { |f| Pathname.new(f) }
         .sort
    end

    # Check if this skill has any supporting files/scripts beyond SKILL.md.
    # For encrypted skills, checks for .enc files that are not SKILL.md.enc or the manifest.
    # For plain skills, checks for any files other than SKILL.md.
    # @return [Boolean]
    def has_supporting_files?
      return false unless @directory.exist?

      if encrypted?
        Dir.glob(File.join(@directory.to_s, "**", "*.enc")).any? do |f|
          base = File.basename(f)
          base != "SKILL.md.enc" && base != "MANIFEST.enc.json"
        end
      else
        supporting_files.any?
      end
    end



    # Process the skill content with argument substitution and template expansion
    # @param arguments [String] Arguments passed to the skill
    # @param shell_output [Hash] Shell command outputs for !command` syntax (optional)
    # @param template_context [Hash] Named values for <%= key %> template expansion (optional)
    # @param script_dir [String, nil] When provided, the Supporting Files block uses this
    #   directory instead of @directory. Used by SkillManager to point the LLM at the
    #   tmpdir containing decrypted scripts for encrypted brand skills.
    # @return [String] Processed content
    def process_content(shell_output: {}, template_context: {}, script_dir: nil)
      # For brand skills, decrypt content in memory at invoke time.
      # For plain skills, use the already-loaded @content.
      processed_content = decrypted_content.dup

      # Expand <%= key %> templates
      processed_content = expand_templates(processed_content, template_context)

      # Replace shell command outputs
      shell_output.each do |command, output|
        placeholder = "!`#{command}`"
        processed_content.gsub!(placeholder, output.to_s)
      end

      # Append supporting files list if any exist.
      # When script_dir is given (encrypted skill with decrypted tmpdir), use that
      # directory for both the path label and the file listing so the LLM sees real
      # paths it can actually execute.
      effective_dir = script_dir || @directory.to_s
      effective_files = if script_dir && Dir.exist?(script_dir)
        gitignore_path = Utils::FileIgnoreHelper.find_gitignore(script_dir)
        gitignore = gitignore_path ? GitignoreParser.new(gitignore_path) : nil
        Dir.glob(File.join(script_dir, "**", "*"))
           .reject { |f| File.directory?(f) }
           .reject { |f| Utils::FileIgnoreHelper.should_ignore_file?(f, script_dir, gitignore) }
           .map { |f| f.sub("#{script_dir}/", "") }
           .sort
      else
        supporting_files.map { |p| p.relative_path_from(@directory).to_s }
      end

      if effective_files.any?
        max_files = 20
        truncated = effective_files.length > max_files
        listed_files = effective_files.first(max_files)

        processed_content += "\n\n## Supporting Files\n\n"
        processed_content += "The following files are available in this skill's directory (`#{effective_dir}`):\n\n"
        listed_files.each do |file|
          processed_content += "- `#{file}`\n"
        end
        if truncated
          processed_content += "\n_(#{effective_files.length - max_files} more files not shown)_\n"
        end
      end

      processed_content
    end

    # Convert to a hash representation
    # @return [Hash]
    def to_h
      {
        name: identifier,
        name_zh: @name_zh,
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
      @encrypted == true
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


    def load_skill
      if @brand_skill
        load_brand_skill
      else
        load_plain_skill
      end

      # Set defaults
      @user_invocable = true if @user_invocable.nil?
      @disable_model_invocation = false if @disable_model_invocation.nil?

      sanitize_frontmatter
    end

    # Load a plain (unencrypted) skill from SKILL.md
    private def load_plain_skill
      skill_file = @directory.join("SKILL.md")

      unless skill_file.exist?
        raise Clacky::AgentError, "SKILL.md not found in skill directory: #{@directory}"
      end

      content = skill_file.read
      parse_frontmatter(content)
    end

    # Load a brand (encrypted) skill from SKILL.md.enc.
    #
    # When cached_metadata is provided (name + description from brand_skills.json),
    # we skip decryption entirely at load time — no network request needed.
    # The full content is decrypted lazily via #decrypted_content when the skill
    # is actually invoked.
    private def load_brand_skill
      enc_file   = @directory.join("SKILL.md.enc")
      plain_file = @directory.join("SKILL.md")
      encrypted  = enc_file.exist?
      plain      = plain_file.exist?

      unless encrypted || plain
        raise Clacky::AgentError, "No SKILL.md or SKILL.md.enc found in brand skill directory: #{@directory}"
      end

      if encrypted && !@brand_config
        raise Clacky::AgentError, "brand_config is required to load encrypted brand skill"
      end

      # Set the encrypted flag based on which file exists.
      # This is independent of @brand_skill (which just marks this as a brand/proprietary skill).
      @encrypted = encrypted

      # Fast path: cached_metadata provides name + description from brand_skills.json
      # (already sanitized to a valid slug by record_installed_skill).
      # For plain brand skills, also eagerly load the content so it's available at invoke time.
      # For encrypted brand skills, defer decryption to #decrypted_content (invocation time).
      if @cached_metadata
        @frontmatter    = {}
        @name           = @cached_metadata["name"]
        @name_zh        = @cached_metadata["name_zh"]
        @description    = @cached_metadata["description"]
        @description_zh = @cached_metadata["description_zh"]
        @content        = plain ? plain_file.read.then { |raw| extract_content_only(raw) } : nil
        return
      end

      # Slow path: no cached_metadata — parse frontmatter directly from file.
      # This runs only on first install before brand_skills.json is written,
      # or for manually placed brand skills without a registry entry.
      if encrypted
        raw = @brand_config.decrypt_skill_content(enc_file.to_s)
        parse_frontmatter(raw)
        @content = nil  # re-decrypted lazily at invoke time via #decrypted_content
      else
        raw = plain_file.read
        parse_frontmatter(raw)
        # Plain brand skill: content is already in memory from parse_frontmatter
      end
    end

    # Extract only the body content from a SKILL.md, stripping YAML frontmatter.
    # Used so plain brand skills can load content at startup without re-parsing frontmatter.
    private def extract_content_only(raw)
      match = raw.match(/\A---\n.*?\n---[ \t]*\n?/m)
      match ? raw[match.end(0)..].strip : raw.strip
    end

    # Parse content that may or may not have YAML frontmatter.
    # This method is lenient: bad frontmatter format or YAML errors just produce
    # warnings rather than raising — the raw text becomes the skill content instead.
    def parse_frontmatter(content)
      frontmatter_match = content.match(/\A---\n(.*?)\n---[ \t]*\n?/m)

      if frontmatter_match
        yaml_content = frontmatter_match[1]

        begin
          @frontmatter = YAML.safe_load(yaml_content) || {}
        rescue Psych::Exception => e
          # Bad YAML — treat whole file as plain content, record warning
          @warnings << "Could not parse YAML frontmatter: #{e.message}. Treating file as plain content."
          @frontmatter = {}
          @content = content
          extract_fields_from_frontmatter
          return
        end

        @content = content[frontmatter_match.end(0)..-1].to_s.strip
      else
        # No valid frontmatter block — treat everything as content (no YAML at all,
        # or an unclosed --- block).  We record a warning only if it looked like the
        # author tried to write frontmatter but made a mistake.
        if content.start_with?("---")
          @warnings << "Frontmatter block started with '---' but no closing '---' was found. Treating file as plain content."
        end
        @frontmatter = {}
        @content = content
      end

      extract_fields_from_frontmatter
    end

    # Pull known fields out of @frontmatter into instance variables.
    private def extract_fields_from_frontmatter
      @name           = @frontmatter["name"]
      @name_zh        = @frontmatter["name_zh"]
      @description    = @frontmatter["description"]
      @description_zh = @frontmatter["description_zh"]
      @disable_model_invocation = @frontmatter["disable-model-invocation"]
      @user_invocable  = @frontmatter["user-invocable"]
      @allowed_tools   = @frontmatter["allowed-tools"]
      @context         = @frontmatter["context"]
      @agent_type      = @frontmatter["agent"]
      @argument_hint   = @frontmatter["argument-hint"]
      @hooks           = @frontmatter["hooks"]
      @fork_agent      = @frontmatter["fork_agent"]
      @model           = @frontmatter["model"]
      @forbidden_tools = @frontmatter["forbidden_tools"]
      @auto_summarize  = @frontmatter["auto_summarize"]
    end

    # Sanitize and auto-correct frontmatter fields instead of raising on bad data.
    # Skills should always load — invalid fields are corrected with a warning, or
    # the skill is marked @invalid so the UI can display it greyed-out.
    def sanitize_frontmatter
      dir_slug = @directory.basename.to_s
      valid_slug = ->(s) { s.to_s.match?(/\A[a-z0-9][a-z0-9_-]*\z/) }

      # --- name ---
      # Brand skills loaded via cached_metadata have their name pre-sanitized by
      # record_installed_skill (brand_config.rb) — skip slug validation for them.
      # The frontmatter name (e.g. "Antique Identifier") is the human-readable display
      # name and should not be treated as a slug.
      if @cached_metadata
        @name ||= dir_slug
      elsif @name
        name_invalid = !valid_slug.call(@name) || @name.length > 64

        if name_invalid
          if valid_slug.call(dir_slug)
            # Recoverable: fall back to directory name, record a warning
            @warnings << "Invalid name '#{@name}' in metadata; using directory name '#{dir_slug}' instead."
            @name = dir_slug
          else
            # Both name and directory slug are invalid (e.g. contains dots from version suffix).
            # Record a warning but keep the skill usable — do not mark as invalid.
            @warnings << "Invalid skill name '#{@name}' and directory name '#{dir_slug}' is also not a valid slug. " \
                         "Expected lowercase letters, numbers, and hyphens (e.g. 'my-skill')."
            @name = dir_slug
          end
        end
      else
        # No name in frontmatter — check the directory slug itself.
        # Non-conforming names (e.g. version-suffixed dirs like "test-runner-1.0.0")
        # are allowed with a warning rather than being rejected outright.
        unless valid_slug.call(dir_slug)
          @warnings << "Directory name '#{dir_slug}' is not a valid skill slug. " \
                       "Expected lowercase letters, numbers, and hyphens (e.g. 'my-skill')."
        end
      end

      # --- forbidden_tools ---
      if @forbidden_tools && !@forbidden_tools.is_a?(Array)
        @warnings << "forbidden_tools must be an array; ignoring value: #{@forbidden_tools.inspect}"
        @forbidden_tools = nil
      end

      # --- allowed-tools ---
      if @allowed_tools && !@allowed_tools.is_a?(Array)
        @warnings << "allowed-tools must be an array; ignoring value: #{@allowed_tools.inspect}"
        @allowed_tools = nil
      end
    end

    def extract_first_paragraph
      @content.split(/\n\n/).first.to_s
    end

    # Expand <%= key %> template placeholders via ERB.
    # context is a Hash<String|Symbol, String|Proc> — Proc values are called lazily.
    # Unknown bindings raise no error; ERB just leaves them blank (nil.to_s).
    # @param content [String]
    # @param context [Hash]
    # @return [String]
    def expand_templates(content, context)
      # Shell-style ${VAR} substitution from ENV — handles variables like
      # ${CLACKY_SERVER_PORT}, ${CLACKY_SERVER_HOST} used in SKILL.md files.
      # Unknown variables are left as-is (no substitution).
      content = content.gsub(/\$\{([A-Z_][A-Z0-9_]*)\}/) { ENV[$1] || $& }

      return content if context.nil? || context.empty?

      # Build a lightweight binding that exposes each context key as a local method
      scope = Object.new
      context.each do |key, value|
        resolved = value.respond_to?(:call) ? value.call : value
        scope.define_singleton_method(key.to_s) { resolved.to_s }
        scope.define_singleton_method(key.to_sym) { resolved.to_s }
      end

      require "erb"
      ERB.new(content, trim_mode: "-").result(scope.instance_eval { binding })
    rescue => e
      # If ERB fails (e.g. unknown variable), return content as-is
      content
    end


  end
end
