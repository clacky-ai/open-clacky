# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::SkillLoader do
  let(:temp_dir) { Dir.mktmpdir }
  let(:working_dir) { temp_dir }

  after do
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  describe "#initialize" do
    it "initializes with working directory" do
      loader = described_class.new(working_dir: working_dir, brand_config: nil)

      expect(loader).to be_a(described_class)
    end

    it "uses current directory when no working_dir given" do
      original_dir = Dir.pwd
      loader = described_class.new(working_dir: nil, brand_config: nil)
      expect(loader).to be_a(described_class)
    ensure
      Dir.chdir(original_dir)
    end
  end

  describe "#load_all" do
    context "with no skills directories" do
      it "returns default skills" do
        loader = described_class.new(working_dir: working_dir, brand_config: nil)
        skills = loader.load_all

        # User may have global skills in ~/.clacky/skills/
        # so we just verify that default skill is included
        expect(skills.size).to be >= 1
        expect(skills.map(&:identifier)).to include("skill-add")
      end
    end

    context "with skills in project .clacky/skills/" do
      it "loads skills from .clacky/skills/" do
        # Create skill in .clacky/skills/
        skills_dir = File.join(working_dir, ".clacky", "skills")
        FileUtils.mkdir_p(skills_dir)

        skill_dir = File.join(skills_dir, "project-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: project-skill
          description: A project skill
          ---
          Project skill content.
        CONTENT

        loader = described_class.new(working_dir: working_dir, brand_config: nil)
        skills = loader.load_all

        skill_identifiers = skills.map(&:identifier)
        expect(skill_identifiers).to include("project-skill")
      end

      it "does NOT load project skills when working_dir is nil" do
        # Create a separate temp directory to avoid touching any real .clacky/skills/
        test_temp_dir = Dir.mktmpdir("skill-loader-test")
        
        begin
          skills_dir = File.join(test_temp_dir, ".clacky", "skills")
          FileUtils.mkdir_p(skills_dir)

          skill_dir = File.join(skills_dir, "temp-test-skill")
          FileUtils.mkdir_p(skill_dir)
          File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
            ---
            name: temp-test-skill
            description: A skill in temp directory
            ---
            This skill should NOT be loaded when working_dir is nil.
          CONTENT

          # Temporarily change to test directory to simulate project context
          original_dir = Dir.pwd
          Dir.chdir(test_temp_dir)

          begin
            # WebUI server mode: working_dir: nil means project-agnostic
            loader = described_class.new(working_dir: nil, brand_config: nil)
            skills = loader.load_all

            skill_identifiers = skills.map(&:identifier)
            # Should only include global and default skills, NOT project-level skills
            expect(skill_identifiers).not_to include("temp-test-skill")
          ensure
            Dir.chdir(original_dir)
          end
        ensure
          # Clean up temp directory
          FileUtils.rm_rf(test_temp_dir) if File.exist?(test_temp_dir)
        end
      end
    end

    context "with multiple skills" do
      it "loads multiple skills from same directory" do
        skills_dir = File.join(working_dir, ".clacky", "skills")
        FileUtils.mkdir_p(skills_dir)

        skill_names = %w[skill-one skill-two skill-three]
        skill_names.each do |name|
          skill_dir = File.join(skills_dir, name)
          FileUtils.mkdir_p(skill_dir)
          File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
            ---
            name: #{name}
            description: Skill #{name}
            ---
            Content for #{name}.
          CONTENT
        end

        loader = described_class.new(working_dir: working_dir, brand_config: nil)
        skills = loader.load_all

        skill_identifiers = skills.map(&:identifier)
        expect(skill_identifiers).to include(*skill_names)
      end
    end
  end

  describe "#find_by_command" do
    it "finds skill by slash command" do
      skills_dir = File.join(working_dir, ".clacky", "skills")
      FileUtils.mkdir_p(skills_dir)

      skill_dir = File.join(skills_dir, "find-me")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: find-me
        description: Find this skill
        ---
        Content here.
      CONTENT

      loader = described_class.new(working_dir: working_dir, brand_config: nil)
      loader.load_all

      skill = loader.find_by_command("/find-me")

      expect(skill).not_to be_nil
      expect(skill.identifier).to eq("find-me")
    end

    it "returns nil for non-existent command" do
      loader = described_class.new(working_dir: working_dir, brand_config: nil)
      loader.load_all

      skill = loader.find_by_command("/nonexistent")

      expect(skill).to be_nil
    end
  end

  describe "#errors" do
    it "returns empty array when no errors" do
      loader = described_class.new(working_dir: working_dir, brand_config: nil)
      loader.load_all

      expect(loader.errors).to be_empty
    end

    it "loads skill with unclosed frontmatter as plain content (with a warning, no error)" do
      skills_dir = File.join(working_dir, ".clacky", "skills")
      FileUtils.mkdir_p(skills_dir)

      skill_dir = File.join(skills_dir, "my-skill")
      FileUtils.mkdir_p(skill_dir)
      # Frontmatter block is never closed — should fall back to treating whole file as content
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: my-skill
        description: A skill
        This frontmatter is not closed properly
      CONTENT

      loader = described_class.new(working_dir: working_dir, brand_config: nil)
      loader.load_all

      # No errors — skill loaded successfully
      expect(loader.errors).to be_empty

      skill = loader.all_skills.find { |s| s.identifier == "my-skill" }
      expect(skill).not_to be_nil
      # It falls back to treating whole file as plain content, and directory name as identifier
      expect(skill.warnings).not_to be_empty
      expect(skill.warnings.first).to match(/frontmatter.*plain content/i)
    end

    it "loads a plain-markdown skill (no frontmatter at all)" do
      skills_dir = File.join(working_dir, ".clacky", "skills")
      FileUtils.mkdir_p(skills_dir)

      skill_dir = File.join(skills_dir, "plain-guide")
      FileUtils.mkdir_p(skill_dir)
      # Pure markdown, no YAML frontmatter
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        # Plain Guide

        This skill has no frontmatter at all.
        Just plain markdown instructions.
      CONTENT

      loader = described_class.new(working_dir: working_dir, brand_config: nil)
      loader.load_all

      # No errors, no warnings
      expect(loader.errors).to be_empty

      skill = loader.all_skills.find { |s| s.identifier == "plain-guide" }
      expect(skill).not_to be_nil
      expect(skill.warnings).to be_empty
      expect(skill.invalid?).to be false
      # Directory name is used as identifier since there's no frontmatter name
      expect(skill.identifier).to eq("plain-guide")
      # Full markdown content is preserved
      expect(skill.content).to include("Plain Guide")
      expect(skill.content).to include("no frontmatter at all")
    end
  end

  describe "#create_skill" do
    context "with project location" do
      it "creates skill in project .clacky/skills/" do
        loader = described_class.new(working_dir: working_dir, brand_config: nil)
        skill = loader.create_skill("new-project-skill", "Project skill content", "A project skill", location: :project)

        expect(skill.identifier).to eq("new-project-skill")
        expect(skill.content).to include("Project skill content")

        project_skills_dir = File.join(working_dir, ".clacky", "skills")
        expect(File.exist?(File.join(project_skills_dir, "new-project-skill", "SKILL.md"))).to be true
      end
    end

    it "validates skill name format" do
      loader = described_class.new(working_dir: working_dir, brand_config: nil)

      expect do
        loader.create_skill("Invalid Name!", "content", "desc")
      end.to raise_error(Clacky::AgentError, /Invalid skill name/)
    end
  end

  describe "#toggle_skill" do
    let(:loader) { described_class.new(working_dir: working_dir, brand_config: nil) }

    before do
      loader.create_skill("my-skill", "Skill content", "A toggleable skill", location: :project)
    end

    let(:skill_file) do
      File.join(working_dir, ".clacky", "skills", "my-skill", "SKILL.md")
    end

    it "writes disable-model-invocation: false when enabling" do
      loader.toggle_skill("my-skill", enabled: true)
      content = File.read(skill_file)
      expect(content).to include("disable-model-invocation: false")
    end

    it "writes disable-model-invocation: true when disabling" do
      loader.toggle_skill("my-skill", enabled: false)
      content = File.read(skill_file)
      expect(content).to include("disable-model-invocation: true")
    end

    it "can toggle back to enabled after disabling" do
      loader.toggle_skill("my-skill", enabled: false)
      loader.toggle_skill("my-skill", enabled: true)
      content = File.read(skill_file)
      expect(content).to include("disable-model-invocation: false")
    end

    it "raises error for system skills" do
      expect do
        loader.toggle_skill("skill-add", enabled: false)
      end.to raise_error(Clacky::AgentError, /Cannot toggle system skill/)
    end

    it "raises error for unknown skill" do
      expect do
        loader.toggle_skill("nonexistent", enabled: true)
      end.to raise_error(Clacky::AgentError, /Skill not found/)
    end
  end

  describe "#delete_skill" do
    it "deletes an existing skill" do
      # First create a skill
      loader = described_class.new(working_dir: working_dir, brand_config: nil)
      loader.create_skill("to-delete", "Content to delete", "Delete me", location: :project)

      skill_dir = File.join(working_dir, ".clacky", "skills", "to-delete")
      expect(File.exist?(skill_dir)).to be true

      # Delete it
      loader.delete_skill("to-delete")

      expect(File.exist?(skill_dir)).to be false
    end

    it "does not error for non-existent skill" do
      loader = described_class.new(working_dir: working_dir, brand_config: nil)

      expect do
        loader.delete_skill("nonexistent-skill")
      end.not_to raise_error
    end
  end

  describe "skill loading (no global cap)" do
    it "loads all skills regardless of count — verified with 65+ total skills" do
      skills_dir = File.join(working_dir, ".clacky", "skills")
      FileUtils.mkdir_p(skills_dir)

      # Create 60 project skills on top of ~12 default skills → ~72 total.
      # Before the MAX_SKILLS removal, the 60th project skill onward would be
      # silently dropped (cap was 50).
      60.times do |i|
        skill_dir = File.join(skills_dir, "proj-skill-#{i}")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: proj-skill-#{i}
          description: Project skill #{i}
          ---
          Content #{i}.
        CONTENT
      end

      loader = described_class.new(working_dir: working_dir, brand_config: nil)

      # All 60 project skills must be loaded
      loaded = loader.all_skills.select { |s| s.identifier.start_with?("proj-skill-") }
      expect(loaded.size).to eq(60)

      # Total skills must be > 60 (includes defaults) — proves no cap at 50
      expect(loader.count).to be > 60

      # No skill-limit warnings
      expect(loader.errors.grep(/Skill limit reached/)).to be_empty
    end
  end
end
