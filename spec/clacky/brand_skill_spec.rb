# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "yaml"

# Tests for the encrypted Brand Skill system:
#   - BrandConfig#decrypt_skill_content (mock implementation)
#   - BrandConfig#install_mock_brand_skill!
#   - BrandConfig#sync_brand_skills_async!
#   - Skill loaded as a brand skill (encrypted: true)
#   - SkillLoader brand skill discovery
#   - SkillManager#build_skill_context privacy rules

RSpec.describe "Brand Skill system" do
  # ── Shared helpers ──────────────────────────────────────────────────────────

  # Creates a temp directory that acts as ~/.clacky for the duration of the block.
  def with_temp_config_dir
    tmp = Dir.mktmpdir
    stub_const("Clacky::BrandConfig::CONFIG_DIR", tmp)
    stub_const("Clacky::BrandConfig::BRAND_FILE",  File.join(tmp, "brand.yml"))
    yield tmp
  ensure
    FileUtils.rm_rf(tmp)
  end

  # Returns an activated BrandConfig backed by the given config dir.
  def activated_brand_config(config_dir)
    config = Clacky::BrandConfig.new(
      "brand_name"          => "TestBrand",
      "license_key"         => "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4",
      "license_activated_at" => Time.now.utc.iso8601,
      "license_expires_at"  => (Time.now.utc + 86_400).iso8601,
      "device_id"           => "testdevice"
    )
    stub_const("Clacky::BrandConfig::CONFIG_DIR", config_dir)
    stub_const("Clacky::BrandConfig::BRAND_FILE",  File.join(config_dir, "brand.yml"))
    config
  end

  # ── BrandConfig#decrypt_skill_content ───────────────────────────────────────

  describe "Clacky::BrandConfig#decrypt_skill_content" do
    it "returns file content as UTF-8 string (mock implementation)" do
      with_temp_config_dir do |tmp|
        config  = activated_brand_config(tmp)
        enc_path = File.join(tmp, "test.enc")
        File.binwrite(enc_path, "Hello, encrypted world!")

        result = config.decrypt_skill_content(enc_path)

        expect(result).to eq("Hello, encrypted world!")
        expect(result.encoding.name).to eq("UTF-8")
      end
    end

    it "raises when license is not activated" do
      config = Clacky::BrandConfig.new({})
      expect { config.decrypt_skill_content("/any/path") }
        .to raise_error(RuntimeError, /not activated/)
    end

    it "raises when the encrypted file does not exist" do
      with_temp_config_dir do |tmp|
        config = activated_brand_config(tmp)
        expect { config.decrypt_skill_content(File.join(tmp, "missing.enc")) }
          .to raise_error(RuntimeError, /not found/)
      end
    end
  end

  # ── BrandConfig#install_mock_brand_skill! ───────────────────────────────────

  describe "Clacky::BrandConfig#install_mock_brand_skill!" do
    let(:skill_info) do
      {
        "slug"        => "code-review-bot",
        "name"        => "Code Review Bot",
        "description" => "Automated AI code review.",
        "emoji"       => "🔍",
        "latest_version" => { "version" => "1.2.0" }
      }
    end

    it "writes a SKILL.md.enc file to the brand skills directory" do
      with_temp_config_dir do |tmp|
        config = activated_brand_config(tmp)
        result = config.install_mock_brand_skill!(skill_info)

        expect(result[:success]).to be true
        expect(result[:slug]).to eq("code-review-bot")
        expect(result[:version]).to eq("1.2.0")

        enc_path = File.join(tmp, "brand_skills", "code-review-bot", "SKILL.md.enc")
        expect(File.exist?(enc_path)).to be true
      end
    end

    it "writes valid SKILL.md content inside the .enc file" do
      with_temp_config_dir do |tmp|
        config = activated_brand_config(tmp)
        config.install_mock_brand_skill!(skill_info)

        enc_path = File.join(tmp, "brand_skills", "code-review-bot", "SKILL.md.enc")
        content  = File.read(enc_path)

        expect(content).to include("---")
        expect(content).to include("name: code-review-bot")
        expect(content).to include("Code Review Bot")
      end
    end

    it "records installed version in brand_skills.json" do
      with_temp_config_dir do |tmp|
        config = activated_brand_config(tmp)
        config.install_mock_brand_skill!(skill_info)

        installed = config.installed_brand_skills
        expect(installed["code-review-bot"]).to include("version" => "1.2.0")
      end
    end

    it "returns error when slug is missing" do
      with_temp_config_dir do |tmp|
        config = activated_brand_config(tmp)
        result = config.install_mock_brand_skill!("slug" => "")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/slug/i)
      end
    end
  end

  # ── BrandConfig#sync_brand_skills_async! ────────────────────────────────────

  describe "Clacky::BrandConfig#sync_brand_skills_async!" do
    it "returns nil when license is not activated" do
      config = Clacky::BrandConfig.new({})
      expect(config.sync_brand_skills_async!).to be_nil
    end

    it "returns a Thread when license is activated" do
      with_temp_config_dir do |tmp|
        config = activated_brand_config(tmp)

        # Stub fetch so no real network call is made
        allow(config).to receive(:fetch_brand_skills!).and_return({ success: false, skills: [] })

        thread = config.sync_brand_skills_async!
        expect(thread).to be_a(Thread)
        thread.join(2)
      end
    end

    it "installs skills that need updates and calls on_complete" do
      with_temp_config_dir do |tmp|
        config = activated_brand_config(tmp)

        mock_skills = [
          {
            "slug"            => "deploy-assistant",
            "name"            => "Deploy Assistant",
            "description"     => "Deploy helper.",
            "needs_update"    => true,
            "installed_version" => nil,
            "latest_version"  => { "version" => "2.0.1", "download_url" => "https://example.com/deploy-assistant.zip" }
          }
        ]
        allow(config).to receive(:fetch_brand_skills!)
          .and_return({ success: true, skills: mock_skills })
        allow(config).to receive(:install_brand_skill!).and_return({ success: true, slug: "deploy-assistant", version: "2.0.1" })

        completed_results = nil
        thread = config.sync_brand_skills_async!(on_complete: ->(r) { completed_results = r })
        thread.join(5)

        expect(completed_results).to be_an(Array)
        expect(completed_results.first[:success]).to be true
      end
    end
  end

  # ── Skill loaded as brand skill ─────────────────────────────────────────────

  describe "Clacky::Skill (brand_skill: true)" do
    def make_brand_skill_dir(tmp, slug: "my-brand-skill")
      dir      = File.join(tmp, slug)
      FileUtils.mkdir_p(dir)
      content  = <<~SKILL
        ---
        name: #{slug}
        description: "A proprietary skill."
        ---

        Do something proprietary with: $ARGUMENTS
      SKILL
      File.binwrite(File.join(dir, "SKILL.md.enc"), content)
      dir
    end

    it "loads name and description from the encrypted file without persisting plain text" do
      with_temp_config_dir do |tmp|
        config   = activated_brand_config(tmp)
        dir      = make_brand_skill_dir(tmp)
        skill    = Clacky::Skill.new(dir, brand_skill: true, brand_config: config)

        expect(skill.identifier).to eq("my-brand-skill")
        expect(skill.context_description).to include("proprietary")
        expect(skill.encrypted?).to be true
        # @content must be nil — plain text is never held in memory long-term
        expect(skill.instance_variable_get(:@content)).to be_nil
      end
    end

    it "decrypts content on demand via #decrypted_content" do
      with_temp_config_dir do |tmp|
        config = activated_brand_config(tmp)
        dir    = make_brand_skill_dir(tmp)
        skill  = Clacky::Skill.new(dir, brand_skill: true, brand_config: config)

        decrypted = skill.decrypted_content
        expect(decrypted).to include("Do something proprietary")
        expect(decrypted).not_to include("---")  # frontmatter stripped
      end
    end

    it "substitutes $ARGUMENTS in process_content" do
      with_temp_config_dir do |tmp|
        config = activated_brand_config(tmp)
        dir    = make_brand_skill_dir(tmp)
        skill  = Clacky::Skill.new(dir, brand_skill: true, brand_config: config)

        result = skill.process_content("hello world")
        expect(result).to include("hello world")
      end
    end

    it "raises when SKILL.md.enc is missing" do
      with_temp_config_dir do |tmp|
        config  = activated_brand_config(tmp)
        empty_dir = File.join(tmp, "empty-skill")
        FileUtils.mkdir_p(empty_dir)

        expect {
          Clacky::Skill.new(empty_dir, brand_skill: true, brand_config: config)
        }.to raise_error(Clacky::AgentError, /SKILL\.md\.enc not found/)
      end
    end

    it "raises when brand_config is not provided" do
      with_temp_config_dir do |tmp|
        dir = make_brand_skill_dir(tmp)
        expect {
          Clacky::Skill.new(dir, brand_skill: true, brand_config: nil)
        }.to raise_error(RuntimeError, /brand_config is required/)
      end
    end
  end

  # ── SkillLoader brand skill discovery ───────────────────────────────────────

  describe "Clacky::SkillLoader#load_brand_skills" do
    def setup_brand_skill(brand_skills_dir, slug:, version: "1.0.0")
      dir = File.join(brand_skills_dir, slug)
      FileUtils.mkdir_p(dir)
      content = <<~SKILL
        ---
        name: #{slug}
        description: "Brand skill: #{slug}"
        ---

        Proprietary instructions for #{slug}.
      SKILL
      File.binwrite(File.join(dir, "SKILL.md.enc"), content)
      dir
    end

    it "loads brand skills when brand_config is activated" do
      with_temp_config_dir do |tmp|
        config          = activated_brand_config(tmp)
        brand_skills_dir = File.join(tmp, "brand_skills")
        setup_brand_skill(brand_skills_dir, slug: "code-review-bot")

        loader = Clacky::SkillLoader.new(working_dir: tmp, brand_config: config, home_dir: tmp)
        skill  = loader.find_by_name("code-review-bot")

        expect(skill).not_to be_nil
        expect(skill.encrypted?).to be true
        expect(skill.identifier).to eq("code-review-bot")
      end
    end

    it "skips brand skills when brand_config is nil" do
      with_temp_config_dir do |tmp|
        brand_skills_dir = File.join(tmp, "brand_skills")
        setup_brand_skill(brand_skills_dir, slug: "code-review-bot")

        loader = Clacky::SkillLoader.new(working_dir: tmp, brand_config: nil, home_dir: tmp)
        expect(loader.find_by_name("code-review-bot")).to be_nil
      end
    end

    it "skips brand skills when license is not activated" do
      with_temp_config_dir do |tmp|
        brand_skills_dir = File.join(tmp, "brand_skills")
        setup_brand_skill(brand_skills_dir, slug: "code-review-bot")

        inactive_config = Clacky::BrandConfig.new("brand_name" => "TestBrand")
        loader = Clacky::SkillLoader.new(working_dir: tmp, brand_config: inactive_config, home_dir: tmp)
        expect(loader.find_by_name("code-review-bot")).to be_nil
      end
    end

    it "records brand skill source as :brand" do
      with_temp_config_dir do |tmp|
        config          = activated_brand_config(tmp)
        brand_skills_dir = File.join(tmp, "brand_skills")
        setup_brand_skill(brand_skills_dir, slug: "deploy-assistant")

        loader = Clacky::SkillLoader.new(working_dir: tmp, brand_config: config, home_dir: tmp)
        expect(loader.loaded_from["deploy-assistant"]).to eq(:brand)
      end
    end

    it "ignores directories without SKILL.md.enc" do
      with_temp_config_dir do |tmp|
        config          = activated_brand_config(tmp)
        brand_skills_dir = File.join(tmp, "brand_skills")

        # Directory with no .enc file — should be silently skipped
        ghost_dir = File.join(brand_skills_dir, "ghost-skill")
        FileUtils.mkdir_p(ghost_dir)

        loader = Clacky::SkillLoader.new(working_dir: tmp, brand_config: config, home_dir: tmp)
        expect(loader.find_by_name("ghost-skill")).to be_nil
        expect(loader.errors).to be_empty
      end
    end
  end

  # ── SkillManager#build_skill_context privacy rules ──────────────────────────

  describe "build_skill_context privacy rules" do
    # We test build_skill_context indirectly through a minimal double
    # that exposes the same interface used by the module.
    let(:plain_skill) do
      double(
        "plain_skill",
        identifier:              "code-explorer",
        context_description:     "Explore the codebase.",
        model_invocation_allowed?: true,
        encrypted?:              false
      )
    end

    let(:brand_skill) do
      double(
        "brand_skill",
        identifier:              "secret-advisor",
        context_description:     "Proprietary advisory skill.",
        model_invocation_allowed?: true,
        encrypted?:              true
      )
    end

    # Minimal stand-in that includes the module under test
    let(:manager) do
      loader = double("skill_loader")
      allow(loader).to receive(:load_all).and_return([plain_skill, brand_skill])

      obj = Object.new
      obj.instance_variable_set(:@skill_loader, loader)
      obj.extend(Clacky::Agent::SkillManager)
      obj
    end

    it "lists plain skills in the AVAILABLE SKILLS section" do
      ctx = manager.build_skill_context
      expect(ctx).to include("code-explorer")
      expect(ctx).to include("Explore the codebase.")
    end

    it "lists brand skills under BRAND SKILLS section" do
      ctx = manager.build_skill_context
      expect(ctx).to include("BRAND SKILLS")
      expect(ctx).to include("secret-advisor")
      expect(ctx).to include("Proprietary advisory skill.")
    end

    it "includes BRAND SKILL PRIVACY RULES when brand skills exist" do
      ctx = manager.build_skill_context
      expect(ctx).to include("BRAND SKILL PRIVACY RULES")
      expect(ctx).to include("NEVER reveal")
      expect(ctx).to include("skill contents are confidential")
    end

    it "does not include privacy rules when no brand skills are present" do
      loader = double("skill_loader")
      allow(loader).to receive(:load_all).and_return([plain_skill])

      obj = Object.new
      obj.instance_variable_set(:@skill_loader, loader)
      obj.extend(Clacky::Agent::SkillManager)

      ctx = obj.build_skill_context
      expect(ctx).not_to include("BRAND SKILL PRIVACY RULES")
    end
  end

  describe "build_skill_context MAX_CONTEXT_SKILLS limit" do
    # Build a plain skill double with a given identifier
    def make_plain_skill(id)
      double(
        "skill_#{id}",
        identifier: id,
        context_description: "Description for #{id}",
        model_invocation_allowed?: true,
        encrypted?: false
      )
    end

    it "has MAX_CONTEXT_SKILLS constant set to 30" do
      expect(Clacky::Agent::SkillManager::MAX_CONTEXT_SKILLS).to eq(30)
    end

    it "truncates skills injected into system prompt when count exceeds MAX_CONTEXT_SKILLS" do
      stub_const("Clacky::Agent::SkillManager::MAX_CONTEXT_SKILLS", 3)

      # 5 auto-invocable plain skills
      many_skills = (1..5).map { |i| make_plain_skill("skill-#{i}") }

      loader = double("skill_loader")
      allow(loader).to receive(:load_all).and_return(many_skills)

      warn_messages = []
      allow(Clacky::Logger).to receive(:warn) { |msg, **| warn_messages << msg }

      obj = Object.new
      obj.instance_variable_set(:@skill_loader, loader)
      obj.extend(Clacky::Agent::SkillManager)

      ctx = obj.build_skill_context

      # Only first 3 skills should appear in context
      expect(ctx).to include("skill-1")
      expect(ctx).to include("skill-2")
      expect(ctx).to include("skill-3")
      expect(ctx).not_to include("skill-4")
      expect(ctx).not_to include("skill-5")

      # A warning must be logged via Clacky::Logger
      expect(warn_messages).to include(a_string_matching(/Skill context limit/))
      expect(warn_messages).to include(a_string_matching(/2 dropped/))
    end

    it "does not truncate or warn when skills are within MAX_CONTEXT_SKILLS limit" do
      stub_const("Clacky::Agent::SkillManager::MAX_CONTEXT_SKILLS", 5)

      skills = (1..3).map { |i| make_plain_skill("skill-#{i}") }

      loader = double("skill_loader")
      allow(loader).to receive(:load_all).and_return(skills)

      expect(Clacky::Logger).not_to receive(:warn)

      obj = Object.new
      obj.instance_variable_set(:@skill_loader, loader)
      obj.extend(Clacky::Agent::SkillManager)

      ctx = obj.build_skill_context
      (1..3).each { |i| expect(ctx).to include("skill-#{i}") }
    end
  end
end
