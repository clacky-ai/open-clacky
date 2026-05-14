# frozen_string_literal: true

require 'fileutils'
require 'pathname'

# Import lark-cli's official Skills from ~/.agents/skills/lark-* into
# ~/.clacky/skills/lark-imports/<name>/.
#
# Background:
#   lark-cli ships ~24 SKILL.md files (lark-doc, lark-sheets, lark-base, ...)
#   that teach the agent how to use `lark-cli`. They are normally installed
#   under ~/.agents/skills/lark-*, which openclacky's SkillLoader does NOT
#   scan. This importer copies them into ~/.clacky/skills/lark-imports/ so
#   they become discoverable via the standard skill description-matching
#   mechanism.
#
# This is intentionally a small, dedicated importer (not a generic external
# skills tool) — it only handles the lark-cli case for the feishu channel
# setup flow. Failures are non-fatal: the bot itself remains functional even
# if Skills cannot be exposed.
#
# Usage:
#   importer = Clacky::ChannelSetup::LarkSkillsImporter.new
#   result = importer.run
#   # result => { copied: 24, skipped: 0, errors: [] }

module Clacky
  module ChannelSetup
    class LarkSkillsImporter
      DEFAULT_SOURCE_DIR = File.join(Dir.home, '.agents', 'skills')
      DEFAULT_TARGET_DIR = File.join(Dir.home, '.clacky', 'skills', 'lark-imports')
      SKILL_PREFIX       = 'lark-'

      # @param source_dir [String] directory containing lark-cli installed skills
      # @param target_dir [String] destination under ~/.clacky/skills/
      def initialize(source_dir: DEFAULT_SOURCE_DIR, target_dir: DEFAULT_TARGET_DIR)
        @source_dir = Pathname.new(source_dir).expand_path
        @target_dir = Pathname.new(target_dir).expand_path
      end

      # Run the import. Returns a result hash; never raises on per-skill errors.
      # @return [Hash] { copied: Integer, skipped: Integer, errors: Array<String> }
      def run
        return { copied: 0, skipped: 0, errors: ["source not found: #{@source_dir}"] } unless @source_dir.directory?

        skill_dirs = discover_lark_skills
        return { copied: 0, skipped: 0, errors: [] } if skill_dirs.empty?

        FileUtils.mkdir_p(@target_dir)

        copied = 0
        errors = []
        skill_dirs.each do |src|
          begin
            copy_skill(src)
            copied += 1
          rescue StandardError => e
            errors << "#{src.basename}: #{e.message}"
          end
        end

        { copied: copied, skipped: 0, errors: errors }
      end

      # Discover candidate lark-* skill directories under @source_dir.
      # A directory qualifies when it (a) starts with "lark-" and (b) contains a SKILL.md.
      # @return [Array<Pathname>]
      private def discover_lark_skills
        @source_dir.children
                   .select { |p| p.directory? && p.basename.to_s.start_with?(SKILL_PREFIX) }
                   .select { |p| p.join('SKILL.md').exist? }
                   .sort_by { |p| p.basename.to_s }
      end

      # Copy a single skill directory into @target_dir, replacing any existing copy
      # so re-runs always reflect the latest version.
      # @param src [Pathname]
      private def copy_skill(src)
        dst = @target_dir.join(src.basename.to_s)
        FileUtils.rm_rf(dst) if dst.exist?
        FileUtils.mkdir_p(dst)
        src.children.each { |child| FileUtils.cp_r(child, dst) }
      end
    end
  end
end

# CLI entry point — invoked by SKILL.md after the user opts in to lark-cli.
# Usage:
#   ruby import_lark_skills.rb
# Prints a one-line summary; exits 0 even when nothing to copy (treat empty
# source as a soft skip — the script may run before `npx skills add`).
if $PROGRAM_NAME == __FILE__
  result = Clacky::ChannelSetup::LarkSkillsImporter.new.run
  puts "[lark-import] copied=#{result[:copied]} errors=#{result[:errors].size}"
  result[:errors].each { |e| warn "[lark-import] #{e}" }
end
