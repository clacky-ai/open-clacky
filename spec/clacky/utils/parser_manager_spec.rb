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

    it "does not overwrite existing parsers" do
      parser = File.join(tmp_parsers_dir, "pdf_parser.rb")
      File.write(parser, "# my custom version")

      described_class.setup!

      expect(File.read(parser)).to eq("# my custom version")
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
