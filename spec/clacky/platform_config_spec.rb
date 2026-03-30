# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Clacky::PlatformConfig do
  # Run every test with a fresh temp file so tests are fully isolated
  around do |example|
    Dir.mktmpdir do |tmpdir|
      @config_file = File.join(tmpdir, "platform.yml")
      example.run
    end
  end

  # ── .load ─────────────────────────────────────────────────────────────────

  describe ".load" do
    context "when the config file does not exist" do
      it "returns an unconfigured instance" do
        cfg = described_class.load(@config_file)
        expect(cfg.configured?).to be false
      end

      it "uses the default base_url" do
        cfg = described_class.load(@config_file)
        expect(cfg.base_url).to eq(described_class::DEFAULT_BASE_URL)
      end
    end

    context "when the config file exists with valid data" do
      before do
        File.write(@config_file, <<~YAML)
          workspace_key: clacky_ak_abc123xyz
          base_url: https://my.company.example.com
        YAML
      end

      it "loads the workspace_key" do
        cfg = described_class.load(@config_file)
        expect(cfg.workspace_key).to eq("clacky_ak_abc123xyz")
      end

      it "loads the base_url" do
        cfg = described_class.load(@config_file)
        expect(cfg.base_url).to eq("https://my.company.example.com")
      end

      it "is configured?" do
        cfg = described_class.load(@config_file)
        expect(cfg.configured?).to be true
      end
    end

    context "when the config file exists but has no workspace_key" do
      before do
        File.write(@config_file, "base_url: https://api.clacky.ai\n")
      end

      it "is not configured?" do
        cfg = described_class.load(@config_file)
        expect(cfg.configured?).to be false
      end

      it "still has the persisted base_url" do
        cfg = described_class.load(@config_file)
        expect(cfg.base_url).to eq("https://api.clacky.ai")
      end
    end

    context "when the config file is corrupt YAML" do
      before { File.write(@config_file, ":\nfoo:\n  - [\n") }

      it "returns an empty default instance rather than raising" do
        expect { described_class.load(@config_file) }.not_to raise_error
        cfg = described_class.load(@config_file)
        expect(cfg.configured?).to be false
      end
    end
  end

  # ── #save ──────────────────────────────────────────────────────────────────

  describe "#save" do
    it "creates the config file" do
      cfg = described_class.new(workspace_key: "clacky_ak_test", base_url: "https://api.clacky.ai")
      cfg.save(@config_file)
      expect(File.exist?(@config_file)).to be true
    end

    it "persists workspace_key and base_url" do
      cfg = described_class.new(workspace_key: "clacky_ak_saved", base_url: "https://example.com")
      cfg.save(@config_file)

      reloaded = described_class.load(@config_file)
      expect(reloaded.workspace_key).to eq("clacky_ak_saved")
      expect(reloaded.base_url).to eq("https://example.com")
    end

    it "does NOT persist a nil workspace_key key in the YAML" do
      cfg = described_class.new(base_url: "https://api.clacky.ai")
      cfg.save(@config_file)

      raw = File.read(@config_file)
      expect(raw).not_to include("workspace_key")
    end

    it "strips trailing slashes from base_url on load" do
      cfg = described_class.new(workspace_key: "clacky_ak_x", base_url: "https://api.clacky.ai///")
      cfg.save(@config_file)

      reloaded = described_class.load(@config_file)
      expect(reloaded.base_url).to eq("https://api.clacky.ai")
    end

    it "sets file permissions to 0600" do
      cfg = described_class.new(workspace_key: "clacky_ak_perm")
      cfg.save(@config_file)
      perms = File.stat(@config_file).mode & 0o777
      expect(perms).to eq(0o600)
    end

    it "returns self (fluent interface)" do
      cfg = described_class.new(workspace_key: "clacky_ak_fluent")
      expect(cfg.save(@config_file)).to be cfg
    end
  end

  # ── attribute mutation ─────────────────────────────────────────────────────

  describe "attribute setters" do
    it "allows updating workspace_key and persisting" do
      cfg = described_class.load(@config_file)
      cfg.workspace_key = "clacky_ak_new"
      cfg.save(@config_file)

      reloaded = described_class.load(@config_file)
      expect(reloaded.workspace_key).to eq("clacky_ak_new")
    end
  end

  # ── .clear! ───────────────────────────────────────────────────────────────

  describe ".clear!" do
    it "removes the config file if it exists" do
      described_class.new(workspace_key: "clacky_ak_del").save(@config_file)
      described_class.clear!(@config_file)
      expect(File.exist?(@config_file)).to be false
    end

    it "does not raise if the file does not exist" do
      expect { described_class.clear!(@config_file) }.not_to raise_error
    end
  end
end
