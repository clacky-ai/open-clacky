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

        # User may have global skills in ~/.claude/skills/ or ~/.clacky/skills/
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

    it "collects errors from invalid skills" do
      skills_dir = File.join(working_dir, ".clacky", "skills")
      FileUtils.mkdir_p(skills_dir)

      skill_dir = File.join(skills_dir, "invalid-skill")
      FileUtils.mkdir_p(skill_dir)
      # Create invalid skill with unclosed frontmatter
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: invalid-skill
        description: Invalid skill
        This frontmatter is not closed properly
      CONTENT

      loader = described_class.new(working_dir: working_dir, brand_config: nil)
      loader.load_all

      expect(loader.errors).not_to be_empty
      expect(loader.errors.first).to include("invalid-skill")
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

  describe "MAX_SKILLS limit" do
    it "has MAX_SKILLS constant set to 50" do
      expect(described_class::MAX_SKILLS).to eq(50)
    end

    it "stops loading skills once MAX_SKILLS is reached and records a warning" do
      skills_dir = File.join(working_dir, ".clacky", "skills")
      FileUtils.mkdir_p(skills_dir)

      # There are 7 default skills built into the gem.
      # Stub MAX_SKILLS to 9 so we have room for 2 project skills before hitting the cap.
      # Then create 5 project skills — only 2 should be loaded, the rest skipped.
      stub_const("Clacky::SkillLoader::MAX_SKILLS", 9)

      5.times do |i|
        skill_dir = File.join(skills_dir, "overflow-skill-#{i}")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: overflow-skill-#{i}
          description: Overflow skill #{i}
          ---
          Content #{i}.
        CONTENT
      end

      loader = described_class.new(working_dir: working_dir, brand_config: nil)

      # Total skills must not exceed MAX_SKILLS
      expect(loader.count).to be <= 9

      # At least one warning should mention the limit
      expect(loader.errors).to include(a_string_matching(/Skill limit reached/))
    end
  end
end
