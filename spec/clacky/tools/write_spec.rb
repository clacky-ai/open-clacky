# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Tools::Write do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "writes content to a new file" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        content = "Hello, World!"

        result = tool.execute(path: file_path, content: content)

        expect(result[:error]).to be_nil
        expect(result[:bytes_written]).to eq(content.bytesize)
        expect(File.read(file_path)).to eq(content)
      end
    end

    it "overwrites existing file" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "Old content")

        new_content = "New content"
        result = tool.execute(path: file_path, content: new_content)

        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq(new_content)
      end
    end

    it "creates parent directories if they don't exist" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "sub", "dir", "test.txt")
        content = "Test"

        result = tool.execute(path: file_path, content: content)

        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq(content)
      end
    end

    it "returns error for empty path" do
      result = tool.execute(path: "", content: "test")

      expect(result[:error]).to include("cannot be empty")
    end

    it "handles nil path" do
      result = tool.execute(path: nil, content: "test")

      expect(result[:error]).to include("cannot be empty")
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("write")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("path")
      expect(definition[:function][:parameters][:required]).to include("content")
    end
  end
end
