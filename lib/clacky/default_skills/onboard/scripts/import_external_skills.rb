#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'pathname'

# Import skills from external AI tool installations into ~/.clacky/skills/.
#
# Supported sources:
#   - OpenClaw: ~/.openclaw/skills/, ~/.openclaw/workspace/skills/,
#               ~/.agents/skills/, ~/.openclaw/workspace/.agents/skills/
#
# Each source is imported into a dedicated category subdirectory under ~/.clacky/skills/,
# e.g. ~/.clacky/skills/openclaw-imports/<skill-name>/. This keeps imported skills
# isolated from the user's own skills and makes the origin traceable.
#
# Usage: ruby import_external_skills.rb [--source <name>] [--dry-run] [--yes]
#
# Options:
#   --source <name>          Import only from the named source (e.g. "openclaw").
#                            Defaults to all supported sources.
#   --dry-run                Preview what would be imported without making any changes.
#   --yes                    Skip confirmation prompt and execute immediately.
#
# Exit codes:
#   0 - success (including "nothing to import" case)
#   1 - unexpected error

# ---------------------------------------------------------------------------
# Base class for a single-source importer
# ---------------------------------------------------------------------------
class ExternalSkillsImporter
  # @param target_skills_dir [Pathname] ~/.clacky/skills/
  # @param category_subdir [String] subdirectory name used to group imported skills
  # @param dry_run [Boolean] when true, only preview without making changes
  def initialize(target_skills_dir:, category_subdir:, dry_run: false)
    @target_skills_dir = target_skills_dir
    @target_import_dir = target_skills_dir.join(category_subdir)
    @dry_run           = dry_run
    @imported          = []
    @errors            = []
  end

  # Run the import for this source.
  # @return [Integer] number of skills imported (or would be imported in dry-run mode)
  def run
    unless source_available?
      puts "[INFO] #{source_label} not found - skipping."
      return 0
    end

    skills = discover_skills
    if skills.empty?
      puts "[INFO] No #{source_label} skills found - nothing to import."
      return 0
    end

    skills.each { |skill| process_skill(skill) }

    @imported.size
  end

  # Errors encountered during this import run.
  # @return [Array<String>]
  def errors
    @errors.dup
  end

  # Imported skill records for reporting.
  # @return [Array<Hash>]
  def imported
    @imported.dup
  end

  # Human-readable name for this source (used in output messages).
  # Subclasses must override.
  # @return [String]
  private def source_label
    raise NotImplementedError
  end

  # Return true when the source root directory exists on this machine.
  # Subclasses must override.
  # @return [Boolean]
  private def source_available?
    raise NotImplementedError
  end

  # Discover all valid skill directories from the external source.
  # Each element must be a Hash with at least: { name:, source_dir:, origin: }
  # Subclasses must override.
  # @return [Array<Hash>]
  private def discover_skills
    raise NotImplementedError
  end

  # Process a single skill: record it for preview, and copy if not in dry-run mode.
  #
  # @param skill [Hash] { name:, source_dir:, origin: }
  private def process_skill(skill)
    name       = skill[:name]
    source_dir = Pathname.new(skill[:source_dir])
    dest_dir   = @target_import_dir.join(name)

    action = dest_dir.exist? ? 'updated' : 'imported'
    description = read_description(source_dir.join('SKILL.md'))

    @imported << {
      name:        name,
      action:      action,
      description: description,
      dest:        dest_dir,
      source_dir:  source_dir,
      origin:      skill[:origin]
    }

    return if @dry_run

    copy_skill(name, source_dir, dest_dir, action)
  rescue StandardError => e
    @errors << "Failed to process '#{name}': #{e.message}"
  end

  # Copy a single skill directory into @target_import_dir.
  # Existing destinations are removed first so re-running is idempotent.
  #
  # @param name [String]
  # @param source_dir [Pathname]
  # @param dest_dir [Pathname]
  # @param action [String] 'imported' or 'updated'
  private def copy_skill(name, source_dir, dest_dir, action)
    FileUtils.mkdir_p(@target_import_dir)
    FileUtils.rm_rf(dest_dir) if dest_dir.exist?
    FileUtils.mkdir_p(dest_dir)

    # Copy all contents: SKILL.md, scripts/, assets/, etc.
    source_dir.children.each { |child| FileUtils.cp_r(child, dest_dir) }
  rescue StandardError => e
    @errors << "Failed to import '#{name}': #{e.message}"
  end

  # Extract the description field from SKILL.md YAML frontmatter.
  # @param skill_file [Pathname]
  # @return [String]
  private def read_description(skill_file)
    return 'No description' unless skill_file.exist?

    content = skill_file.read
    return $1.strip if content =~ /\A---\s*\n.*?^description:\s*(.+)$/m

    'No description'
  rescue StandardError
    'No description'
  end
end

# ---------------------------------------------------------------------------
# OpenClaw importer
# ---------------------------------------------------------------------------
class OpenClawImporter < ExternalSkillsImporter
  SOURCE_NAME          = 'openclaw'
  DEFAULT_OPENCLAW_DIR = File.join(Dir.home, '.openclaw')

  # @param kwargs forwarded to ExternalSkillsImporter
  def initialize(**kwargs)
    super(category_subdir: 'openclaw-imports', **kwargs)
    @openclaw_dir = Pathname.new(DEFAULT_OPENCLAW_DIR).expand_path
  end

  private def source_label
    'OpenClaw (~/.openclaw)'
  end

  private def source_available?
    @openclaw_dir.exist?
  end

  # Returns all directories that may contain OpenClaw skills.
  # Each entry is a hash: { root: Pathname, layout: :flat }
  #
  # Mirrors the four sources from hermes openclaw_to_hermes.py:
  #   - ~/.openclaw/workspace/skills/             (workspace skills)
  #   - ~/.openclaw/skills/                        (managed/shared skills)
  #   - ~/.agents/skills/                          (personal cross-project skills)
  #   - ~/.openclaw/workspace/.agents/skills/      (project-level shared skills)
  private def source_dirs
    [
      @openclaw_dir.join('workspace', 'skills'),
      @openclaw_dir.join('skills'),
      Pathname.new(Dir.home).join('.agents', 'skills'),
      @openclaw_dir.join('workspace', '.agents', 'skills')
    ].select(&:exist?)
  end

  private def discover_skills
    skills = []

    source_dirs.each do |dir|
      dir.children.select(&:directory?).each do |skill_dir|
        next unless skill_dir.join('SKILL.md').exist?

        skills << {
          name:       skill_dir.basename.to_s,
          source_dir: skill_dir,
          origin:     dir.basename.to_s
        }
      end
    end

    skills.sort_by { |s| s[:name] }
  end
end

# ---------------------------------------------------------------------------
# Coordinator - runs all enabled importers and prints a combined report
# ---------------------------------------------------------------------------
class ExternalSkillsImportRunner
  # Register new importer classes here to add support for more sources.
  IMPORTERS = [OpenClawImporter].freeze
  SOURCES   = IMPORTERS.map { |klass| klass::SOURCE_NAME }.freeze

  # @param sources [Array<String>] subset of SOURCES to run; nil means all
  # @param target_skills_dir [String]
  # @param dry_run [Boolean] when true, only preview without making changes
  # @param yes [Boolean] when true, skip confirmation prompt
  def initialize(sources: nil,
                 target_skills_dir: File.join(Dir.home, '.clacky', 'skills'),
                 dry_run: false,
                 yes: false)
    @sources           = (sources || SOURCES) & SOURCES
    @target_skills_dir = Pathname.new(target_skills_dir).expand_path
    @dry_run           = dry_run
    @yes               = yes
  end

  def run
    # In dry-run mode: collect plan and print preview only
    if @dry_run
      importers = build_importers(dry_run: true)
      all_imported = []
      importers.each { |i| i.run; all_imported.concat(i.imported) }
      print_preview(all_imported, dry_run: true)
      return all_imported.size
    end

    # Normal mode: collect plan first, show preview, then confirm
    preview_importers = build_importers(dry_run: true)
    all_preview = []
    preview_importers.each { |i| i.run; all_preview.concat(i.imported) }

    if all_preview.empty?
      puts 'Nothing to import.'
      return 0
    end

    print_preview(all_preview, dry_run: false)

    unless @yes || confirm?
      puts 'Import cancelled.'
      return 0
    end

    # Execute the actual import
    importers = build_importers(dry_run: false)
    all_imported = []
    all_errors   = []

    importers.each do |importer|
      importer.run
      all_imported.concat(importer.imported)
      all_errors.concat(importer.errors)
    end

    print_summary(all_imported, all_errors)
    all_imported.size
  end

  private def build_importers(dry_run:)
    common = { target_skills_dir: @target_skills_dir, dry_run: dry_run }

    IMPORTERS
      .select { |klass| @sources.include?(klass::SOURCE_NAME) }
      .map { |klass| klass.new(**common) }
  end

  # Print a Hermes-style preview of what would be / will be imported.
  # @param skills [Array<Hash>]
  # @param dry_run [Boolean]
  private def print_preview(skills, dry_run:)
    if dry_run
      puts 'Dry Run Results'
      puts '  No files will be modified. This is a preview of what would happen.'
    else
      puts 'Import Preview'
      puts '  The following skills will be imported/updated:'
    end
    puts

    if skills.empty?
      puts '  (nothing to import)'
    else
      label_width = skills.map { |s| s[:origin].length }.max || 0
      skills.each do |s|
        action_marker = s[:action] == 'updated' ? '~' : '✓'
        puts "  #{action_marker} Would import:  #{s[:origin].ljust(label_width)}  →  #{s[:dest]}"
      end
    end

    puts
    puts "  Summary: #{skills.size} skill(s) would be #{dry_run ? 'imported' : 'imported/updated'}"
    puts
  end

  # Print summary after actual import.
  private def print_summary(imported, errors)
    puts '=' * 60

    if imported.empty? && errors.empty?
      puts 'Nothing was imported.'
    elsif imported.any?
      puts "Import complete! #{imported.size} skill(s) ready:\n\n"
      imported.each do |s|
        action_label = s[:action] == 'updated' ? '[updated]' : '[new]'
        puts "  #{action_label} #{s[:name]}"
        puts "    #{s[:description]}"
        puts "    -> #{s[:dest]}"
        puts
      end
      puts 'Skills will be available automatically next time Clacky starts.'
    end

    if errors.any?
      puts 'Errors:'
      errors.each { |e| puts "  - #{e}" }
    end

    puts '=' * 60
  end

  # Prompt user for confirmation.
  # @return [Boolean]
  private def confirm?
    print 'Proceed with import? [y/N] '
    $stdout.flush
    answer = $stdin.gets&.strip&.downcase
    answer == 'y' || answer == 'yes'
  end
end

# -- Entry point ------------------------------------------------------------
if __FILE__ == $PROGRAM_NAME
  require 'optparse'

  options = {}

  OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"
    opts.on('--source NAME',
            "Import only from NAME (e.g. openclaw). Supported: #{ExternalSkillsImportRunner::SOURCES.join(', ')}") do |name|
      options[:sources] = [name]
    end
    opts.on('--dry-run', 'Preview what would be imported without making any changes.') do
      options[:dry_run] = true
    end
    opts.on('--yes', '-y', 'Skip confirmation prompt and execute immediately.') do
      options[:yes] = true
    end
  end.parse!

  ExternalSkillsImportRunner.new(**options).run
end
