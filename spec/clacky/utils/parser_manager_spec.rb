# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Utils::ParserManager do
  # Use a temp dir as PARSERS_DIR so tests don't pollute ~/.clacky/parsers/
  let(:tmp_parsers_dir) { Dir.mktmpdir }

  before do
    stub_const("Clacky::Utils::ParserManager::PARSERS_DIR", tmp_parsers_dir)
  end

  after do
    FileUtils.rm_rf(tmp_parsers_dir)
  end

  describe ".parse" do
    context "when no parser exists for the extension" do
      it "returns failure with descriptive error" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "file.unknown_ext")
          File.write(path, "data")
          result = described_class.parse(path)
          expect(result[:success]).to be false
          expect(result[:error]).to match(/No parser available/)
          expect(result[:parser_path]).to be_nil
        end
      end
    end

    context "when parser script is missing from PARSERS_DIR" do
      it "returns failure with parser_path hint" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "doc.pdf")
          File.write(path, "%PDF")
          result = described_class.parse(path)
          expect(result[:success]).to be false
          expect(result[:error]).to match(/Parser not found/)
          expect(result[:parser_path]).to end_with("pdf_parser.rb")
        end
      end
    end

    context "when parser script succeeds" do
      it "returns success with extracted text" do
        # Write a trivial parser that echoes "extracted content"
        parser = File.join(tmp_parsers_dir, "pdf_parser.rb")
        File.write(parser, "puts 'extracted content'")

        Dir.mktmpdir do |dir|
          path = File.join(dir, "doc.pdf")
          File.write(path, "%PDF")
          result = described_class.parse(path)
          expect(result[:success]).to be true
          expect(result[:text]).to eq("extracted content")
          expect(result[:error]).to be_nil
        end
      end
    end

    context "when parser script fails (exit 1)" do
      it "returns failure with stderr as error" do
        parser = File.join(tmp_parsers_dir, "pdf_parser.rb")
        File.write(parser, "$stderr.puts 'something went wrong'; exit 1")

        Dir.mktmpdir do |dir|
          path = File.join(dir, "doc.pdf")
          File.write(path, "%PDF")
          result = described_class.parse(path)
          expect(result[:success]).to be false
          expect(result[:error]).to include("something went wrong")
          expect(result[:parser_path]).to end_with("pdf_parser.rb")
        end
      end
    end

    context "when parser exits 0 but produces empty output" do
      it "returns failure" do
        parser = File.join(tmp_parsers_dir, "pdf_parser.rb")
        File.write(parser, "# outputs nothing")

        Dir.mktmpdir do |dir|
          path = File.join(dir, "doc.pdf")
          File.write(path, "%PDF")
          result = described_class.parse(path)
          expect(result[:success]).to be false
          expect(result[:error]).to match(/Parser exited with code/)
        end
      end
    end
  end

  describe ".setup!" do
    it "copies default parsers into PARSERS_DIR if not already present" do
      # Only run if default_parsers exist in the gem
      default_dir = Clacky::Utils::ParserManager::DEFAULT_PARSERS_DIR
      skip "No default parsers found" unless Dir.exist?(default_dir) && !Dir.glob("#{default_dir}/*.rb").empty?

      described_class.setup!

      Clacky::Utils::ParserManager::PARSER_FOR.values.uniq.each do |script|
        src = File.join(default_dir, script)
        next unless File.exist?(src)
        expect(File.exist?(File.join(tmp_parsers_dir, script))).to be true
      end
    end

    it "does not overwrite existing parsers that have a VERSION >= bundled" do
      # Installed parser tagged with a very high VERSION — simulates a user
      # copy that is newer than anything bundled. Should be left alone.
      parser = File.join(tmp_parsers_dir, "pdf_parser.rb")
      File.write(parser, "# my custom version\n# VERSION: 9999\n")

      described_class.setup!

      expect(File.read(parser)).to include("my custom version")
      expect(File.read(parser)).to include("VERSION: 9999")
    end

    it "upgrades installed parser when bundled VERSION is newer, preserving old as .bak" do
      # Simulate a v1 user-installed parser.
      installed = File.join(tmp_parsers_dir, "pdf_parser.rb")
      File.write(installed, "# pdf_parser v1\n# VERSION: 1\nputs 'old'\n")

      # Stage a bundled v99 in a throwaway defaults dir so we don't depend on
      # the actual gem-shipped version number.
      fake_defaults = Dir.mktmpdir
      begin
        File.write(File.join(fake_defaults, "pdf_parser.rb"),
                   "# pdf_parser v99\n# VERSION: 99\nputs 'new'\n")
        stub_const("Clacky::Utils::ParserManager::DEFAULT_PARSERS_DIR", fake_defaults)

        described_class.setup!

        expect(File.read(installed)).to include("VERSION: 99")
        expect(File.exist?("#{installed}.v1.bak")).to be true
        expect(File.read("#{installed}.v1.bak")).to include("VERSION: 1")
      ensure
        FileUtils.rm_rf(fake_defaults)
      end
    end

    it "does not overwrite when installed VERSION is equal to bundled" do
      installed = File.join(tmp_parsers_dir, "pdf_parser.rb")
      File.write(installed, "# VERSION: 5\nputs 'same'\n")

      fake_defaults = Dir.mktmpdir
      begin
        File.write(File.join(fake_defaults, "pdf_parser.rb"),
                   "# VERSION: 5\nputs 'bundled'\n")
        stub_const("Clacky::Utils::ParserManager::DEFAULT_PARSERS_DIR", fake_defaults)

        described_class.setup!

        expect(File.read(installed)).to include("'same'")
        expect(File.exist?("#{installed}.v5.bak")).to be false
      ensure
        FileUtils.rm_rf(fake_defaults)
      end
    end

    it "upgrades an installed parser that has no VERSION marker (treated as v0, lenient mode)" do
      installed = File.join(tmp_parsers_dir, "pdf_parser.rb")
      File.write(installed, "# legacy parser, pre-VERSION scheme\nputs 'old'\n")

      fake_defaults = Dir.mktmpdir
      begin
        File.write(File.join(fake_defaults, "pdf_parser.rb"),
                   "# VERSION: 9\nputs 'new'\n")
        stub_const("Clacky::Utils::ParserManager::DEFAULT_PARSERS_DIR", fake_defaults)

        described_class.setup!

        expect(File.read(installed)).to include("VERSION: 9")
        expect(File.exist?("#{installed}.v0.bak")).to be true
        expect(File.read("#{installed}.v0.bak")).to include("'old'")
      ensure
        FileUtils.rm_rf(fake_defaults)
      end
    end

    it "does not touch an installed parser when the bundled version has no VERSION marker (opt-out)" do
      installed = File.join(tmp_parsers_dir, "pdf_parser.rb")
      File.write(installed, "# user's custom parser\nputs 'custom'\n")

      fake_defaults = Dir.mktmpdir
      begin
        # Bundled has no VERSION — signals "don't manage this file".
        File.write(File.join(fake_defaults, "pdf_parser.rb"),
                   "# untagged bundled parser\nputs 'bundled'\n")
        stub_const("Clacky::Utils::ParserManager::DEFAULT_PARSERS_DIR", fake_defaults)

        described_class.setup!

        expect(File.read(installed)).to include("'custom'")
        expect(Dir.glob("#{installed}.v*.bak")).to be_empty
      ensure
        FileUtils.rm_rf(fake_defaults)
      end
    end

    it "copies every file under default_parsers/ (including non-.rb sibling scripts)" do
      fake_defaults = Dir.mktmpdir
      begin
        File.write(File.join(fake_defaults, "pdf_parser.rb"),
                   "# VERSION: 1\nputs 'ruby'\n")
        File.write(File.join(fake_defaults, "pdf_parser_helper.py"),
                   "# VERSION: 1\nprint('python helper')\n")
        stub_const("Clacky::Utils::ParserManager::DEFAULT_PARSERS_DIR", fake_defaults)

        described_class.setup!

        expect(File.exist?(File.join(tmp_parsers_dir, "pdf_parser.rb"))).to be true
        expect(File.exist?(File.join(tmp_parsers_dir, "pdf_parser_helper.py"))).to be true
      ensure
        FileUtils.rm_rf(fake_defaults)
      end
    end

    it "preserves the executable bit when copying scripts" do
      fake_defaults = Dir.mktmpdir
      begin
        src = File.join(fake_defaults, "pdf_parser_helper.py")
        File.write(src, "#!/usr/bin/env python3\n# VERSION: 1\nprint('x')\n")
        File.chmod(0o755, src)
        stub_const("Clacky::Utils::ParserManager::DEFAULT_PARSERS_DIR", fake_defaults)

        described_class.setup!

        dest = File.join(tmp_parsers_dir, "pdf_parser_helper.py")
        expect(File.stat(dest).mode & 0o111).to_not eq(0)
      ensure
        FileUtils.rm_rf(fake_defaults)
      end
    end

    it "skips .bak files in the default_parsers directory" do
      fake_defaults = Dir.mktmpdir
      begin
        File.write(File.join(fake_defaults, "pdf_parser.rb"),
                   "# VERSION: 1\n")
        File.write(File.join(fake_defaults, "pdf_parser.rb.v0.bak"),
                   "# shouldn't be copied\n")
        stub_const("Clacky::Utils::ParserManager::DEFAULT_PARSERS_DIR", fake_defaults)

        described_class.setup!

        expect(File.exist?(File.join(tmp_parsers_dir, "pdf_parser.rb"))).to be true
        expect(File.exist?(File.join(tmp_parsers_dir, "pdf_parser.rb.v0.bak"))).to be false
      ensure
        FileUtils.rm_rf(fake_defaults)
      end
    end
  end

  describe ".parser_path_for" do
    it "returns path for known extension" do
      path = described_class.parser_path_for(".pdf")
      expect(path).to end_with("pdf_parser.rb")
    end

    it "returns nil for unknown extension" do
      expect(described_class.parser_path_for(".unknown")).to be_nil
    end
  end
end
