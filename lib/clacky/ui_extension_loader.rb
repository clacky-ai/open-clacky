# frozen_string_literal: true

require "yaml"
require "fileutils"
require "json"

module Clacky
  # UiExtensionLoader scans ~/.clacky/skills/*/ui/ and loads UI extensions bundled
  # inside skills. A skill that ships a UI places its assets under a `ui/`
  # subdirectory inside the skill directory:
  #
  #   ~/.clacky/skills/
  #   └── <skill-name>/
  #       ├── SKILL.md      ← Agent instructions (handled by SkillLoader)
  #       └── ui/           ← UI extension (handled by UiExtensionLoader)
  #           ├── manifest.yml  ← required: metadata (id, name, icon, etc.)
  #           ├── sidebar.html  ← optional: sidebar nav entry HTML fragment
  #           ├── panel.html    ← optional: main panel HTML fragment
  #           ├── index.js      ← optional: UI JavaScript logic
  #           └── routes.rb     ← optional: custom API routes (SkillUiRouter DSL)
  #
  # manifest.yml schema:
  #   id: "coding-agent"
  #   name: "Coding Agent"         # string OR {en: "...", zh: "..."}
  #   version: "0.1.0"
  #   author: "Your Name"
  #   description: "..."           # string OR {en: "...", zh: "..."}
  #   icon: "💻"                   ← emoji or URL
  #   sidebar: true                ← whether to inject a sidebar entry (default: true)
  #   sidebar_divider: "Projects"  # optional; string OR {en: "...", zh: "..."}
  #
  # UI extensions are loaded at server startup and served via GET /api/ui-extensions.
  # The frontend dynamically injects sidebar entries and panels on boot.
  class UiExtensionLoader
    SKILLS_DIR = File.join(Dir.home, ".clacky", "skills")

    def initialize(skills_dir = SKILLS_DIR)
      @skills_dir = skills_dir
    end

    # Scan all skill ui/ subdirectories and return a list of loaded UI extension descriptors.
    # Each descriptor is a Hash ready to be serialized as JSON.
    # Skills without a ui/ directory, or with missing/invalid skill_ui.yml, are skipped.
    def load_all
      return [] unless Dir.exist?(@skills_dir)

      Dir.entries(@skills_dir)
         .select { |entry| skill_dir?(entry) }
         .map    { |entry| load_extension(entry) }
         .compact
    end

    # Read an asset file from a skill's ui/ directory. Returns nil if missing.
    def read_asset(skill_id, filename)
      path = File.join(@skills_dir, skill_id, "ui", filename)
      return nil unless File.exist?(path)

      File.read(path)
    rescue StandardError
      nil
    end

    private

    # Check if an entry is a valid skill directory (not . or ..)
    private def skill_dir?(entry)
      return false if entry.start_with?(".")

      dir_path = File.join(@skills_dir, entry)
      Dir.exist?(dir_path)
    end

    # Load a single UI extension from a skill's ui/ subdirectory. Returns nil if absent/invalid.
    private def load_extension(skill_name)
      ui_dir      = File.join(@skills_dir, skill_name, "ui")
      config_path = File.join(ui_dir, "manifest.yml")

      # Skip skills that have no ui/ directory or no config file
      return nil unless Dir.exist?(ui_dir)
      return nil unless File.exist?(config_path)

      config = YAML.safe_load(File.read(config_path)) || {}
      return nil unless config.is_a?(Hash)

      # Build the UI extension descriptor.
      # name / description / sidebar_divider support two formats:
      #   - String:   "Coding Agent"
      #   - Hash (i18n): { "en" => "Coding Agent", "zh" => "编程助手" }
      # The hash is passed through as-is; the frontend resolves the active language.
      {
        id:               config["id"]              || skill_name,
        name:             config["name"]            || skill_name,
        version:          config["version"]         || "0.0.1",
        author:           config["author"]          || "",
        description:      config["description"]     || "",
        icon:             config["icon"]            || "🧩",
        sidebar:          config.fetch("sidebar", true),
        sidebar_divider:  config["sidebar_divider"] || nil,
        dir:              ui_dir,
        # Flags indicating which optional asset files are present
        has_sidebar_html: File.exist?(File.join(ui_dir, "sidebar.html")),
        has_panel_html:   File.exist?(File.join(ui_dir, "panel.html")),
        has_index_js:     File.exist?(File.join(ui_dir, "index.js")),
      }
    rescue StandardError => e
      warn "[UiExtensionLoader] Failed to load UI extension for skill '#{skill_name}': #{e.message}"
      nil
    end
  end
end
