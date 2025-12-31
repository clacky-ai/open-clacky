# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Tools::Glob do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "finds files matching pattern" do
      Dir.mktmpdir do |dir|
        # Create test files
        FileUtils.touch(File.join(dir, "test1.rb"))
        FileUtils.touch(File.join(dir, "test2.rb"))
        FileUtils.touch(File.join(dir, "test.txt"))

        result = tool.execute(pattern: "*.rb", base_path: dir)

        expect(result[:error]).to be_nil
        expect(result[:returned]).to eq(2)
        expect(result[:matches].all? { |m| m.end_with?(".rb") }).to be true
      end
    end

    it "finds files recursively with ** pattern" do
      Dir.mktmpdir do |dir|
        # Create nested structure
        FileUtils.mkdir_p(File.join(dir, "sub"))
        FileUtils.touch(File.join(dir, "test.rb"))
        FileUtils.touch(File.join(dir, "sub", "nested.rb"))

        result = tool.execute(pattern: "**/*.rb", base_path: dir)

        expect(result[:error]).to be_nil
        expect(result[:returned]).to eq(2)
      end
    end

    it "respects limit parameter" do
      Dir.mktmpdir do |dir|
        # Create many files
        10.times { |i| FileUtils.touch(File.join(dir, "file#{i}.txt")) }

        result = tool.execute(pattern: "*.txt", base_path: dir, limit: 5)

        expect(result[:error]).to be_nil
        expect(result[:returned]).to eq(5)
        expect(result[:total_matches]).to eq(10)
        expect(result[:truncated]).to be true
      end
    end

    it "returns empty array when no matches" do
      Dir.mktmpdir do |dir|
        result = tool.execute(pattern: "*.nonexistent", base_path: dir)

        expect(result[:error]).to be_nil
        expect(result[:matches]).to be_empty
        expect(result[:total_matches]).to eq(0)
      end
    end

    it "returns error for empty pattern" do
      result = tool.execute(pattern: "", base_path: ".")

      expect(result[:error]).to include("cannot be empty")
    end

    it "returns error for non-existent base path" do
      result = tool.execute(pattern: "*.rb", base_path: "/nonexistent/path")

      expect(result[:error]).to include("does not exist")
    end

    it "excludes directories from results" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir(File.join(dir, "subdir"))
        FileUtils.touch(File.join(dir, "file.txt"))

        result = tool.execute(pattern: "*", base_path: dir)

        expect(result[:error]).to be_nil
        # Should only find the file, not the directory
        expect(result[:returned]).to eq(1)
        expect(result[:matches].first).to end_with("file.txt")
      end
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("glob")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("pattern")
    end
  end
end
