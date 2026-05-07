# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Skill do
  let(:temp_dir) { Dir.mktmpdir }
  let(:skill_content) do
    <<~CONTENT
      ---
      name: test-skill
      description: A test skill for testing purposes
      user_invocable: true
      ---

      This is the skill content.
      It should be processed by the skill.
    CONTENT
  end

  after do
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  describe ".new" do
    context "with valid SKILL.md" do
      it "creates a skill instance" do
        skill_dir = File.join(temp_dir, "test-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), skill_content)

        skill = described_class.new(skill_dir)

        expect(skill.identifier).to eq("test-skill")
        expect(skill.context_description).to eq("A test skill for testing purposes")
        expect(skill.user_invocable?).to be true
        expect(skill.model_invocation_allowed?).to be true
        expect(skill.fork_agent?).to be false
      end
    end

    context "with minimal frontmatter" do
      it "creates a skill with defaults" do
        skill_dir = File.join(temp_dir, "minimal-skill")
        FileUtils.mkdir_p(skill_dir)
        minimal_content = <<~CONTENT
          ---
          name: minimal-skill
          ---

          Minimal skill content.
        CONTENT
        File.write(File.join(skill_dir, "SKILL.md"), minimal_content)

        skill = described_class.new(skill_dir)

        expect(skill.identifier).to eq("minimal-skill")
        # Default: user_invocable is true by default (unless explicitly set to false)
        expect(skill.user_invocable?).to be true
        expect(skill.model_invocation_allowed?).to be true
        expect(skill.fork_agent?).to be false
      end
    end

    context "with empty content" do
      it "creates skill with empty content gracefully" do
        skill_dir = File.join(temp_dir, "empty-skill")
        FileUtils.mkdir_p(skill_dir)
        empty_content = <<~CONTENT
          ---
          name: empty-skill
          ---
        CONTENT
        File.write(File.join(skill_dir, "SKILL.md"), empty_content)

        skill = described_class.new(skill_dir)
        expect(skill.identifier).to eq("empty-skill")
        expect(skill.content).to eq("")
      end
    end

    # Note: Ruby's YAML library is very permissive, so truly invalid YAML
    # is rare. Most malformed YAML still parses successfully.
  end

  describe "#slash_command" do
    it "returns the slash command format" do
      skill_dir = File.join(temp_dir, "my-skill")
      FileUtils.mkdir_p(skill_dir)
      # Use different name to test that slash_command uses name from frontmatter
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: my-skill
        description: Skill with custom name
        ---
        Content here.
      CONTENT

      skill = described_class.new(skill_dir)

      expect(skill.slash_command).to eq("/my-skill")
    end
  end

  describe "#content" do
    it "returns the content after frontmatter" do
      skill_dir = File.join(temp_dir, "content-skill")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), skill_content)

      skill = described_class.new(skill_dir)

      expect(skill.content).to include("This is the skill content.")
      expect(skill.content).not_to include("name:")
      expect(skill.content).not_to include("description:")
    end
  end

  describe "#process_content" do
    it "expands <%= key %> templates via ERB with string values" do
      skill_dir = File.join(temp_dir, "erb-skill")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: erb-skill
        description: Skill with ERB templates
        ---
        Memory list:
        <%= memories_meta %>
        End.
      CONTENT

      skill = described_class.new(skill_dir)
      result = skill.process_content(template_context: { "memories_meta" => "- topic: foo" })

      expect(result).to include("- topic: foo")
      expect(result).to include("End.")
    end

    it "expands <%= key %> templates via ERB with Proc values (lazy evaluation)" do
      skill_dir = File.join(temp_dir, "erb-lazy-skill")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: erb-lazy-skill
        description: Skill with lazy ERB template
        ---
        Value: <%= computed %>
      CONTENT

      call_count = 0
      skill = described_class.new(skill_dir)
      result = skill.process_content(template_context: {
        "computed" => -> { call_count += 1; "lazy_result" }
      })

      expect(result).to include("Value: lazy_result")
      expect(call_count).to eq(1)
    end

    context "shell-style ${VAR} substitution from ENV" do
      it "substitutes known ENV variables" do
        skill_dir = File.join(temp_dir, "env-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: env-skill
          description: Skill with ENV vars
          ---
          Connect to http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api
        CONTENT

        orig_host = ENV["CLACKY_SERVER_HOST"]
        orig_port = ENV["CLACKY_SERVER_PORT"]
        ENV["CLACKY_SERVER_HOST"] = "127.0.0.1"
        ENV["CLACKY_SERVER_PORT"] = "7070"
        begin
          skill = described_class.new(skill_dir)
          result = skill.process_content
          expect(result).to include("http://127.0.0.1:7070/api")
          expect(result).not_to include("${CLACKY_SERVER_HOST}")
          expect(result).not_to include("${CLACKY_SERVER_PORT}")
        ensure
          ENV["CLACKY_SERVER_HOST"] = orig_host
          ENV["CLACKY_SERVER_PORT"] = orig_port
        end
      end

      it "leaves unknown ${VAR} unchanged" do
        skill_dir = File.join(temp_dir, "env-unknown-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: env-unknown-skill
          description: Skill with unknown ENV var
          ---
          Value: ${TOTALLY_UNKNOWN_VAR_XYZ}
        CONTENT

        skill = described_class.new(skill_dir)
        result = skill.process_content
        expect(result).to include("${TOTALLY_UNKNOWN_VAR_XYZ}")
      end

      it "substitutes ${VAR} even when template_context is empty" do
        skill_dir = File.join(temp_dir, "env-no-ctx-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: env-no-ctx-skill
          description: Skill
          ---
          Port: ${CLACKY_SERVER_PORT}
        CONTENT

        orig = ENV["CLACKY_SERVER_PORT"]
        ENV["CLACKY_SERVER_PORT"] = "9999"
        begin
          skill = described_class.new(skill_dir)
          result = skill.process_content(template_context: {})
          expect(result).to include("Port: 9999")
        ensure
          ENV["CLACKY_SERVER_PORT"] = orig
        end
      end

      it "appends an environment hint when ${CLACKY_SERVER_*} is referenced but not injected" do
        skill_dir = File.join(temp_dir, "env-missing-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: env-missing-skill
          description: Skill relying on server env
          ---
          Call http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/foo
        CONTENT

        orig_host = ENV.delete("CLACKY_SERVER_HOST")
        orig_port = ENV.delete("CLACKY_SERVER_PORT")
        begin
          skill = described_class.new(skill_dir)
          result = skill.process_content
          expect(result).to include("Environment note")
          expect(result).to include("clacky server")
          # Unexpanded placeholders survive verbatim so the hint's context is clear.
          expect(result).to include("${CLACKY_SERVER_HOST}")
        ensure
          ENV["CLACKY_SERVER_HOST"] = orig_host if orig_host
          ENV["CLACKY_SERVER_PORT"] = orig_port if orig_port
        end
      end

      it "does NOT append the environment hint when ${CLACKY_SERVER_*} is fully expanded" do
        skill_dir = File.join(temp_dir, "env-present-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: env-present-skill
          description: Skill relying on server env
          ---
          Call http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/foo
        CONTENT

        orig_host = ENV["CLACKY_SERVER_HOST"]
        orig_port = ENV["CLACKY_SERVER_PORT"]
        ENV["CLACKY_SERVER_HOST"] = "127.0.0.1"
        ENV["CLACKY_SERVER_PORT"] = "8080"
        begin
          skill = described_class.new(skill_dir)
          result = skill.process_content
          expect(result).not_to include("Environment note")
          expect(result).to include("http://127.0.0.1:8080/api/foo")
        ensure
          ENV["CLACKY_SERVER_HOST"] = orig_host
          ENV["CLACKY_SERVER_PORT"] = orig_port
        end
      end
    end

    it "leaves unknown <%= key %> placeholders as empty string" do
      skill_dir = File.join(temp_dir, "erb-unknown-skill")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: erb-unknown-skill
        description: Skill with unknown ERB key
        ---
        Before.<%= unknown_key %>After.
      CONTENT

      skill = described_class.new(skill_dir)
      # ERB will raise NameError for unknown variable; expand_templates rescues and returns content as-is
      result = skill.process_content(template_context: {})

      # Should not crash; content returned in some form
      expect(result).to be_a(String)
    end

    context "Supporting Files injection (plain skill)" do
      def make_skill_with_scripts(base_dir, name: "script-skill")
        dir = File.join(base_dir, name)
        FileUtils.mkdir_p(File.join(dir, "scripts"))
        File.write(File.join(dir, "SKILL.md"), <<~MD)
          ---
          name: #{name}
          description: Skill with supporting scripts
          ---
          Do the thing.
        MD
        File.write(File.join(dir, "scripts", "run.rb"), "puts 'hello'")
        File.write(File.join(dir, "scripts", "helper.rb"), "def help; end")
        dir
      end

      it "appends Supporting Files block with directory path and relative filenames" do
        dir = make_skill_with_scripts(temp_dir)
        skill = described_class.new(dir)

        result = skill.process_content

        expect(result).to include("## Supporting Files")
        expect(result).to include("`#{dir}`")
        # supporting_files is recursive — individual files, not directories
        expect(result).to include("- `scripts/helper.rb`")
        expect(result).to include("- `scripts/run.rb`")
      end

      it "excludes .git and other ignored directories from Supporting Files" do
        dir = make_skill_with_scripts(temp_dir)
        skill = described_class.new(dir)

        # Simulate user accidentally placing .git, node_modules, tmp inside skill dir
        FileUtils.mkdir_p(File.join(dir, ".git", "objects"))
        File.write(File.join(dir, ".git", "HEAD"), "ref: refs/heads/main")
        FileUtils.mkdir_p(File.join(dir, "node_modules", "lodash"))
        File.write(File.join(dir, "node_modules", "lodash", "index.js"), "module.exports = {}")
        FileUtils.mkdir_p(File.join(dir, "tmp"))
        File.write(File.join(dir, "tmp", "cache.bin"), "junk")

        result = skill.process_content

        expect(result).to include("- `scripts/run.rb`")
        expect(result).not_to include(".git")
        expect(result).not_to include("node_modules")
        expect(result).not_to include("tmp/cache.bin")
      end

      it "does NOT append Supporting Files block when no supporting files exist" do
        dir = File.join(temp_dir, "bare-skill")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "SKILL.md"), <<~MD)
          ---
          name: bare-skill
          description: No scripts
          ---
          Just content.
        MD
        skill = described_class.new(dir)

        result = skill.process_content

        expect(result).not_to include("## Supporting Files")
      end

      it "uses script_dir path in Supporting Files block when script_dir is given" do
        dir = make_skill_with_scripts(temp_dir)
        skill = described_class.new(dir)

        Dir.mktmpdir("clacky-test-") do |tmpdir|
          # Simulate what SkillManager does: copy decrypted scripts to tmpdir
          FileUtils.mkdir_p(File.join(tmpdir, "scripts"))
          File.write(File.join(tmpdir, "scripts", "run.rb"), "puts 'decrypted'")

          result = skill.process_content(script_dir: tmpdir)

          # Directory label must be the tmpdir, not the original skill dir
          expect(result).to include("`#{tmpdir}`")
          expect(result).not_to include("`#{dir}`")
          # Filenames are relative to tmpdir
          expect(result).to include("- `scripts/run.rb`")
        end
      end

      it "falls back to supporting_files listing when script_dir does not exist" do
        dir = make_skill_with_scripts(temp_dir)
        skill = described_class.new(dir)

        # script_dir is set but doesn't exist — effective_dir still uses script_dir
        # but effective_files falls back to supporting_files (recursive)
        result = skill.process_content(script_dir: "/nonexistent/path")

        expect(result).to include("## Supporting Files")
        expect(result).to include("`/nonexistent/path`")
        expect(result).to include("- `scripts/run.rb`")
        expect(result).to include("- `scripts/helper.rb`")
      end
    end

    context "Supporting Files injection (encrypted brand skill)" do
      def activated_brand_config
        Clacky::BrandConfig.new(
          "brand_name"           => "TestBrand",
          "license_key"          => "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4",
          "license_activated_at" => Time.now.utc.iso8601,
          "license_expires_at"   => (Time.now.utc + 86_400).iso8601,
          "device_id"            => "testdevice"
        )
      end

      def make_encrypted_skill_dir(base_dir, slug: "enc-skill")
        dir = File.join(base_dir, slug)
        FileUtils.mkdir_p(dir)
        # SKILL.md.enc — "decrypted" by mock brand_config (just reads file as-is)
        File.binwrite(File.join(dir, "SKILL.md.enc"), <<~CONTENT)
          ---
          name: #{slug}
          description: Encrypted skill
          ---
          Secret instructions.
        CONTENT
        # Encrypted supporting scripts
        FileUtils.mkdir_p(File.join(dir, "scripts"))
        File.binwrite(File.join(dir, "scripts", "analyze.rb.enc"), "encrypted bytes")
        dir
      end

      it "has_supporting_files? returns true when .enc scripts exist" do
        dir = make_encrypted_skill_dir(temp_dir)
        config = activated_brand_config
        skill = Clacky::Skill.new(dir, brand_skill: true, brand_config: config)

        expect(skill.has_supporting_files?).to be true
      end

      it "has_supporting_files? returns false when only SKILL.md.enc exists" do
        dir = File.join(temp_dir, "enc-only")
        FileUtils.mkdir_p(dir)
        File.binwrite(File.join(dir, "SKILL.md.enc"), "---\nname: enc-only\ndescription: x\n---\ncontent")
        config = activated_brand_config
        skill = Clacky::Skill.new(dir, brand_skill: true, brand_config: config)

        expect(skill.has_supporting_files?).to be false
      end

      it "supporting_files returns [] for encrypted skills (never leak .enc paths)" do
        dir = make_encrypted_skill_dir(temp_dir)
        config = activated_brand_config
        skill = Clacky::Skill.new(dir, brand_skill: true, brand_config: config)

        expect(skill.supporting_files).to eq([])
      end

      it "process_content with script_dir shows tmpdir paths, not encrypted dir" do
        dir = make_encrypted_skill_dir(temp_dir)
        config = activated_brand_config
        skill = Clacky::Skill.new(dir, brand_skill: true, brand_config: config)

        Dir.mktmpdir("clacky-enc-test-") do |tmpdir|
          # Simulate SkillManager: decrypt scripts into tmpdir
          FileUtils.mkdir_p(File.join(tmpdir, "scripts"))
          File.write(File.join(tmpdir, "scripts", "analyze.rb"), "puts 'decrypted analyze'")

          result = skill.process_content(script_dir: tmpdir)

          expect(result).to include("## Supporting Files")
          expect(result).to include("`#{tmpdir}`")
          # Must NOT expose the original encrypted directory
          expect(result).not_to include(dir)
          expect(result).to include("- `scripts/analyze.rb`")
        end
      end

      it "process_content without script_dir does NOT append Supporting Files block" do
        dir = make_encrypted_skill_dir(temp_dir)
        config = activated_brand_config
        skill = Clacky::Skill.new(dir, brand_skill: true, brand_config: config)

        # No script_dir → script_dir is nil → effective_files falls back to
        # supporting_files which returns [] for encrypted skills
        result = skill.process_content

        expect(result).not_to include("## Supporting Files")
        # Encrypted dir path must never appear
        expect(result).not_to include(dir)
      end
    end
  end

  describe "#allowed_tools" do
    it "returns allowed tools list" do
      skill_dir = File.join(temp_dir, "tools-skill")
      FileUtils.mkdir_p(skill_dir)
      tools_content = <<~CONTENT
        ---
        name: tools-skill
        description: Skill with allowed tools
        allowed-tools:
          - file_reader
          - grep
        ---
        Content here.
      CONTENT
      File.write(File.join(skill_dir, "SKILL.md"), tools_content)

      skill = described_class.new(skill_dir)

      expect(skill.allowed_tools).to eq(["file_reader", "grep"])
    end
  end

  describe "#directory" do
    it "returns the skill directory path" do
      skill_dir = File.join(temp_dir, "dir-skill")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), skill_content)

      skill = described_class.new(skill_dir)

      expect(skill.directory).to eq(Pathname.new(skill_dir))
    end
  end

  describe "#source_path" do
    it "returns the source path for the skill" do
      skill_dir = File.join(temp_dir, "source-skill")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: source-skill
        description: Skill with source path
        ---
        Content here.
      CONTENT

      skill = described_class.new(skill_dir, source_path: "/some/project")

      expect(skill.source_path).to be_a(Pathname)
      expect(skill.source_path.to_s).to eq("/some/project")
    end
  end

  describe "subagent configuration" do
    context "with fork_agent enabled" do
      it "parses fork_agent configuration" do
        skill_dir = File.join(temp_dir, "subagent-skill")
        FileUtils.mkdir_p(skill_dir)
        subagent_content = <<~CONTENT
          ---
          name: subagent-skill
          description: A skill that forks a subagent
          fork_agent: true
          model: claude-haiku-3-5
          forbidden_tools:
            - write
            - edit
            - safe_shell
          auto_summarize: true
          ---

          You are a code explorer subagent.
        CONTENT
        File.write(File.join(skill_dir, "SKILL.md"), subagent_content)

        skill = described_class.new(skill_dir)

        expect(skill.fork_agent?).to be true
        expect(skill.subagent_model).to eq("claude-haiku-3-5")
        expect(skill.forbidden_tools_list).to contain_exactly("write", "edit", "safe_shell")
        expect(skill.auto_summarize?).to be true
      end
    end

    context "without fork_agent" do
      it "returns defaults" do
        skill_dir = File.join(temp_dir, "normal-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), skill_content)

        skill = described_class.new(skill_dir)

        expect(skill.fork_agent?).to be false
        expect(skill.subagent_model).to be_nil
        expect(skill.forbidden_tools_list).to eq([])
        expect(skill.auto_summarize?).to be true  # Default is true
      end
    end

    context "with auto_summarize disabled" do
      it "returns false for auto_summarize?" do
        skill_dir = File.join(temp_dir, "no-summary-skill")
        FileUtils.mkdir_p(skill_dir)
        no_summary_content = <<~CONTENT
          ---
          name: no-summary
          fork_agent: true
          auto_summarize: false
          ---

          Content
        CONTENT
        File.write(File.join(skill_dir, "SKILL.md"), no_summary_content)

        skill = described_class.new(skill_dir)

        expect(skill.auto_summarize?).to be false
      end
    end
  end
end
