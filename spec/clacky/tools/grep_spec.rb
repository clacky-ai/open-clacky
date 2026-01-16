# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Tools::Grep do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "finds matching lines in a file" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "foo\nbar\nbaz\nfoo again")

        result = tool.execute(pattern: "foo", path: file_path)

        expect(result[:error]).to be_nil
        expect(result[:files_with_matches]).to eq(1)
        expect(result[:results].first[:matches].length).to eq(2)
      end
    end

    it "searches multiple files in directory" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "file1.txt"), "hello world")
        File.write(File.join(dir, "file2.txt"), "hello ruby")
        File.write(File.join(dir, "file3.txt"), "goodbye")

        result = tool.execute(pattern: "hello", path: dir, file_pattern: "*.txt")

        expect(result[:error]).to be_nil
        expect(result[:files_with_matches]).to eq(2)
      end
    end

    it "supports case insensitive search" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "Hello\nHELLO\nhello")

        result = tool.execute(pattern: "hello", path: file_path, case_insensitive: true)

        expect(result[:error]).to be_nil
        expect(result[:results].first[:matches].length).to eq(3)
      end
    end

    it "includes context lines when requested" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "line1\nline2\nmatch\nline4\nline5")

        result = tool.execute(pattern: "match", path: file_path, context_lines: 1)

        expect(result[:error]).to be_nil
        match = result[:results].first[:matches].first
        expect(match[:context]).not_to be_nil
        expect(match[:context].length).to eq(3) # 1 before + match + 1 after
      end
    end

    it "respects max_files limit" do
      Dir.mktmpdir do |dir|
        # Create many files with matches
        10.times do |i|
          File.write(File.join(dir, "file#{i}.txt"), "match")
        end

        result = tool.execute(pattern: "match", path: dir, max_files: 5)

        expect(result[:error]).to be_nil
        expect(result[:files_with_matches]).to eq(5)
        expect(result[:truncated]).to be true
      end
    end

    it "returns error for invalid regex" do
      result = tool.execute(pattern: "[invalid(", path: ".")

      expect(result[:error]).to include("Invalid regex")
    end

    it "returns error for non-existent path" do
      result = tool.execute(pattern: "test", path: "/nonexistent/path")

      expect(result[:error]).to include("does not exist")
    end

    it "skips binary files" do
      Dir.mktmpdir do |dir|
        # Create a text file
        File.write(File.join(dir, "text.txt"), "hello")
        # Create a binary file (with null bytes)
        File.write(File.join(dir, "binary.bin"), "hello\x00world")

        result = tool.execute(pattern: "hello", path: dir, file_pattern: "*")

        expect(result[:error]).to be_nil
        # Should only find the text file
        expect(result[:files_with_matches]).to eq(1)
        expect(result[:results].first[:file]).to end_with("text.txt")
      end
    end

    it "supports regex patterns" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "test123\ntest\ntest456")

        result = tool.execute(pattern: 'test\d+', path: file_path)

        expect(result[:error]).to be_nil
        expect(result[:results].first[:matches].length).to eq(2)
      end
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("grep")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("pattern")
    end
  end
end
