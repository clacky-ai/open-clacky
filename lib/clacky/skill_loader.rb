# frozen_string_literal: true

require "pathname"
require "fileutils"
require "clacky"

module Clacky
  # Loader and registry for skills.
  # Discovers skills from multiple locations and provides lookup functionality.
  class SkillLoader
    # Skill discovery locations (in priority order: lower index = lower priority)
    LOCATIONS = [
      :default,            # gem's built-in default skills (lowest priority)
      :global_clacky,      # ~/.clacky/skills/
      :project_clacky,     # .clacky/skills/ (highest priority among plain skills)
      :brand               # ~/.clacky/brand_skills/ (encrypted, license-gated)
    ].freeze

    # Note: MAX_SKILLS cap was removed — the MAX_CONTEXT_SKILLS limit in
    # SkillManager already controls system-prompt token usage, and CLI `/` / Web UI
    # skill lists should show all skills without truncation. Project/brand skills
    # (loaded last by priority) must not be silently dropped at registration time.

    # Initialize the skill loader and automatically load all skills
    # @param working_dir [String, nil] Current working directory for project-level discovery.
    #   When nil, project-level skills (.clacky/skills/) are not loaded,
    #   making the loader project-agnostic (used by WebUI server).
    # @param brand_config [Clacky::BrandConfig, nil] Optional brand config used to
    #   decrypt brand skills. When nil, brand skills are silently skipped.
    def initialize(working_dir:, brand_config:)
      @working_dir  = working_dir
      @brand_config = brand_config
      @skills = {}            # Map identifier -> Skill
      @skills_by_command = {} # Map slash_command -> Skill
      @errors = []            # Store loading errors
      @loaded_from = {}       # Track which location each skill was loaded from

      load_all
    end

    # Load all skills from configured locations
    # Clears previously loaded skills before loading to ensure idempotency
    # @return [Array<Skill>] Loaded skills
    def load_all
      # Always refresh brand_config from disk so newly installed/activated brand
      # skills are visible even if this SkillLoader was created before the change.
      @brand_config = Clacky::BrandConfig.load

      # Clear existing skills to ensure idempotent reloading
      clear

      load_default_skills
      load_global_clacky_skills
      
      # Only load project-level skills when working_dir is explicitly provided.
      # When nil (e.g. WebUI server mode), skip project skills to keep the loader
      # project-agnostic and only expose global skills.
      if @working_dir
        load_project_clacky_skills
      end
      
      load_brand_skills

      all_skills
    end

    # Load brand skills from ~/.clacky/brand_skills/
    # Supports both encrypted (SKILL.md.enc) and plain (SKILL.md) brand skills.
    # Encrypted skills require a BrandConfig with an activated license to decrypt.
    #
    # Local plain skills (global_clacky / project_clacky) shadow same-named brand
    # skills — the local version takes priority. This is intentional: creators who
    # have a local SKILL.md for a skill they also publish should always run their
    # own (editable, up-to-date) copy rather than the encrypted distribution copy.
    # @return [Array<Skill>]
    def load_brand_skills
      return [] unless @brand_config&.activated?
      return [] if ENV["CLACKY_TEST"] == "1"

      # Use brand_config#brand_skills_dir so the path respects CONFIG_DIR,
      # which is important for test isolation via stub_const.
      brand_skills_dir = Pathname.new(@brand_config.brand_skills_dir)
      return [] unless brand_skills_dir.exist?

      # Read brand_skills.json once — provides cached name/description so we
      # can skip decrypting each skill's .enc file just to read its frontmatter.
      installed_metadata = @brand_config.installed_brand_skills

      skills = []
      brand_skills_dir.children.select(&:directory?).each do |skill_dir|
        # Support both encrypted (.enc) and plain brand skills
        encrypted = skill_dir.join("SKILL.md.enc").exist?
        plain     = skill_dir.join("SKILL.md").exist?
        next unless encrypted || plain

        skill_name = skill_dir.basename.to_s

        # Skip brand skill when a local plain skill with the same name is already
        # loaded (global_clacky or project_clacky). The local copy shadows it.
        if @skills[skill_name] && %i[global_clacky project_clacky].include?(@loaded_from[skill_name])
          @shadowed_by_local ||= {}
          @shadowed_by_local[skill_name] = @loaded_from[skill_name]
          next
        end

        # Pass cached_metadata for all brand skills (encrypted or plain).
        # brand_skills.json stores sanitized slugs, so this prevents sanitize_frontmatter
        # from flagging human-readable names like "Antique Identifier" as invalid.
        cached_metadata = installed_metadata[skill_name]
        skill = load_single_brand_skill(skill_dir, skill_name, encrypted: encrypted, cached_metadata: cached_metadata)
        skills << skill if skill
      end
      skills
    end

    # Returns a hash of skill names that are shadowed by a local plain skill.
    # e.g. { "commit" => :global_clacky } means brand "commit" is overridden by
    # the user's own ~/.clacky/skills/commit/ copy.
    # @return [Hash{String => Symbol}]
    def shadowed_by_local
      @shadowed_by_local || {}
    end

    # Load skills from ~/.clacky/skills/ (user global)
    # @return [Array<Skill>]
    def load_global_clacky_skills
      global_clacky_dir = Pathname.new(ENV.fetch("HOME", "~")).join(".clacky", "skills")
      load_skills_from_directory(global_clacky_dir, :global_clacky)
    end

    # Load skills from .clacky/skills/ (project-level, highest priority)
    # @return [Array<Skill>]
    def load_project_clacky_skills
      project_clacky_dir = Pathname.new(@working_dir).join(".clacky", "skills")
      load_skills_from_directory(project_clacky_dir, :project_clacky)
    end

    # Get all loaded skills
    # @return [Array<Skill>]
    def all_skills
      @skills.values
    end

    # Get a skill by its identifier
    # @param identifier [String] Skill name or directory name
    # @return [Skill, nil]
    def [](identifier)
      @skills[identifier]
    end

    # Find a skill by its slash command
    # @param command [String] e.g., "/explain-code"
    # @return [Skill, nil]
    def find_by_command(command)
      @skills_by_command[command]
    end

    # Find a skill by its name (identifier)
    # @param name [String] Skill identifier (e.g., "code-explorer", "pptx")
    # @return [Skill, nil]
    def find_by_name(name)
      @skills[name]
    end

    # Get skills that can be invoked by user
    # @return [Array<Skill>]
    def user_invocable_skills
      all_skills.select(&:user_invocable?)
    end

    # Get the count of loaded skills
    # @return [Integer]
    def count
      @skills.size
    end

    # Get loading errors
    # @return [Array<String>]
    def errors
      @errors.dup
    end

    # Get the source location for each loaded skill
    # @return [Hash{String => Symbol}] Map of skill identifier to source location
    def loaded_from
      @loaded_from.dup
    end

    # Clear loaded skills and errors
    def clear
      @skills.clear
      @skills_by_command.clear
      @loaded_from.clear
      @errors.clear
      @shadowed_by_local = {}
    end

    # Create a new skill directory and SKILL.md file
    # @param name [String] Skill name (will be used for directory and slash command)
    # @param content [String] Skill content (SKILL.md body)
    # @param description [String] Skill description
    # @param location [Symbol] Where to create: :global or :project
    # @return [Skill] The created skill
    def create_skill(name, content, description = nil, location: :global)
      # Validate name
      unless name.match?(/^[a-z0-9][a-z0-9-]*$/)
        raise Clacky::AgentError,
          "Invalid skill name '#{name}'. Use lowercase letters, numbers, and hyphens only."
      end

      # Determine directory path
      skill_dir = case location
      when :global
        Pathname.new(ENV.fetch("HOME", "~")).join(".clacky", "skills", name)
      when :project
        Pathname.new(@working_dir).join(".clacky", "skills", name)
      else
        raise Clacky::AgentError, "Unknown skill location: #{location}"
      end

      # Create directory if it doesn't exist
      FileUtils.mkdir_p(skill_dir)

      # Build frontmatter
      frontmatter = { "name" => name, "description" => description }

      # Write SKILL.md
      skill_content = build_skill_content(frontmatter, content)
      skill_file = skill_dir.join("SKILL.md")
      skill_file.write(skill_content)

      # Load the newly created skill
      source_type = case location
      when :global then :global_clacky
      when :project then :project_clacky
      else :global_clacky
      end
      load_single_skill(skill_dir, skill_dir, name, source_type)
    end

    # Toggle a skill's disable-model-invocation field in its SKILL.md.
    # System skills (source: :default) cannot be toggled — raises AgentError.
    # @param name [String] Skill identifier
    # @param enabled [Boolean] true = enable, false = disable
    # @return [Skill] The reloaded skill
    def toggle_skill(name, enabled:)
      skill = @skills[name]
      raise Clacky::AgentError, "Skill not found: #{name}" unless skill
      raise Clacky::AgentError, "Cannot toggle system skill: #{name}" if @loaded_from[name] == :default

      skill_file = skill.directory.join("SKILL.md")
      fm = (skill.frontmatter || {}).dup

      if enabled
        fm["disable-model-invocation"] = false
      else
        fm["disable-model-invocation"] = true
      end

      skill_file.write(build_skill_content(fm, skill.content))

      # Reload into registry
      reloaded = Skill.new(skill.directory, source_path: skill.source_path)
      @skills[reloaded.identifier] = reloaded
      @skills_by_command[reloaded.slash_command] = reloaded
      reloaded
    end

    # Delete a skill
    # @param name [String] Skill name
    # @return [Boolean] True if deleted, false if not found
    def delete_skill(name)
      skill = @skills[name]
      return false unless skill

      # Remove from registry
      @skills.delete(name)
      @skills_by_command.delete(skill.slash_command)

      # Delete directory
      FileUtils.rm_rf(skill.directory)

      true
    end


    def load_skills_from_directory(dir, source_type)
      return [] unless dir.exist?

      source_path = case source_type
      when :global_clacky
        Pathname.new(ENV.fetch("HOME", "~")).join(".clacky")
      when :project_clacky
        Pathname.new(@working_dir)
      else
        dir
      end

      skills = []
      dir.children.select(&:directory?).each do |entry|
        if entry.join("SKILL.md").exist?
          # Direct skill directory
          skill = load_single_skill(entry, source_path, entry.basename.to_s, source_type)
          skills << skill if skill
        else
          # Treat as a category directory — scan one level deeper for skills.
          # This allows grouping skills under ~/.clacky/skills/<category>/<skill>/SKILL.md
          # (e.g. openclaw-imports/my-skill/SKILL.md) without changing the loader contract.
          entry.children.select(&:directory?).each do |skill_dir|
            next unless skill_dir.join("SKILL.md").exist?

            skill = load_single_skill(skill_dir, source_path, skill_dir.basename.to_s, source_type)
            skills << skill if skill
          end
        end
      end
      skills
    end

    # Load a single brand skill directory.
    # Supports encrypted (SKILL.md.enc) and plain (SKILL.md) brand skills.
    # @param skill_dir [Pathname] Directory containing the skill file
    # @param skill_name [String] Directory basename used as fallback identifier
    # @param encrypted [Boolean] Whether to treat this as an encrypted brand skill
    # @param cached_metadata [Hash, nil] Pre-loaded name/description from brand_skills.json.
    #   When provided, Skill.new skips decrypting the .enc file to read frontmatter.
    # @return [Skill, nil]
    private def load_single_brand_skill(skill_dir, skill_name, encrypted: true, cached_metadata: nil)
      skill = Skill.new(
        skill_dir,
        source_path:     skill_dir,
        brand_skill:     true,
        brand_config:    encrypted ? @brand_config : nil,
        cached_metadata: cached_metadata
      )

      register_skill(skill, source: :brand)
      skill
    rescue Clacky::AgentError => e
      @errors << "Error loading brand skill '#{skill_name}' from #{skill_dir}: #{e.message}"
      nil
    rescue StandardError => e
      @errors << "Unexpected error loading brand skill '#{skill_name}' from #{skill_dir}: #{e.message}"
      nil
    end

    private def load_single_skill(skill_dir, source_path, skill_name, source_type)
      skill = Skill.new(skill_dir, source_path: source_path)
      register_skill(skill, source: source_type)
      skill
    rescue Clacky::AgentError => e
      @errors << "Error loading skill '#{skill_name}' from #{skill_dir}: #{e.message}"
      nil
    rescue StandardError => e
      @errors << "Unexpected error loading skill '#{skill_name}' from #{skill_dir}: #{e.message}"
      nil
    end

    # Register a skill into the internal lookup tables.
    # - Always adds to @skills (by identifier) so the skill is discoverable in the UI.
    # - Skips @skills_by_command registration when the skill is invalid (no valid slug
    #   to form a slash command from).
    # - Respects priority ordering for duplicates; enforces MAX_SKILLS cap.
    # @param skill [Skill]
    # @param source [Symbol] one of :default, :global_clacky, :project_clacky, :brand
    # @return [Skill, nil] nil when the skill was rejected (duplicate/limit)
    private def register_skill(skill, source:)
      id             = skill.identifier
      priority_order = %i[default global_clacky project_clacky brand]

      # --- duplicate check ---
      if (existing = @skills[id])
        existing_source = @loaded_from[id]
        if priority_order.index(source) > priority_order.index(existing_source)
          # Incoming skill has higher priority — evict the existing one
          @skills.delete(existing.identifier)
          @skills_by_command.delete(existing.slash_command)
          @loaded_from.delete(existing.identifier)
        else
          @errors << "Skipping duplicate skill '#{id}' (lower priority) from #{skill.directory}"
          return nil
        end
      end

      # Register in main skills hash
      @skills[id]        = skill
      @loaded_from[id]   = source
      skill.source       = source

      # Invalid skills have no usable slug — skip slash command registration but
      # still keep them in @skills so they appear (greyed-out) in the UI.
      unless skill.invalid?
        @skills_by_command[skill.slash_command] = skill
      end

      skill
    end

    def build_skill_content(frontmatter, content)
      yaml = frontmatter
        .reject { |_, v| v.nil? || v.to_s.empty? }
        .to_yaml(line_width: 80)

      "---\n#{yaml}---\n\n#{content}"
    end

    # Load default skills from gem's default_skills directory
    private def load_default_skills
      # Get the gem's lib directory
      gem_lib_dir = File.expand_path("../", __dir__)
      default_skills_dir = File.join(gem_lib_dir, "clacky", "default_skills")

      return unless Dir.exist?(default_skills_dir)

      # Load each skill directory
      Dir.glob(File.join(default_skills_dir, "*/SKILL.md")).each do |skill_file|
        skill_dir = File.dirname(skill_file)
        skill_name = File.basename(skill_dir)

        begin
          skill = Skill.new(Pathname.new(skill_dir))
          register_skill(skill, source: :default)
        rescue StandardError => e
          @errors << "Failed to load default skill #{skill_name}: #{e.message}"
        end
      end
    end
  end
end
