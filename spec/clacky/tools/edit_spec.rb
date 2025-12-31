# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Tools::Edit do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "replaces string in file" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "Hello, World!")

        result = tool.execute(
          path: file_path,
          old_string: "World",
          new_string: "Ruby"
        )

        expect(result[:error]).to be_nil
        expect(result[:replacements]).to eq(1)
        expect(File.read(file_path)).to eq("Hello, Ruby!")
      end
    end

    it "replaces all occurrences when replace_all is true" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "foo bar foo baz foo")

        result = tool.execute(
          path: file_path,
          old_string: "foo",
          new_string: "qux",
          replace_all: true
        )

        expect(result[:error]).to be_nil
        expect(result[:replacements]).to eq(3)
        expect(File.read(file_path)).to eq("qux bar qux baz qux")
      end
    end

    it "returns error when string not found" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "Hello, World!")

        result = tool.execute(
          path: file_path,
          old_string: "notfound",
          new_string: "replacement"
        )

        expect(result[:error]).to include("not found")
      end
    end

    it "returns error for file not found" do
      result = tool.execute(
        path: "/nonexistent/file.txt",
        old_string: "foo",
        new_string: "bar"
      )

      expect(result[:error]).to include("not found")
    end

    it "returns error for ambiguous replacement without replace_all" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "foo foo foo")

        result = tool.execute(
          path: file_path,
          old_string: "foo",
          new_string: "bar",
          replace_all: false
        )

        expect(result[:error]).to include("appears 3 times")
      end
    end

    it "preserves whitespace and indentation" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        original = "  def hello\n    puts 'world'\n  end"
        File.write(file_path, original)

        result = tool.execute(
          path: file_path,
          old_string: "    puts 'world'",
          new_string: "    puts 'Ruby'"
        )

        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq("  def hello\n    puts 'Ruby'\n  end")
      end
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("edit")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("path")
      expect(definition[:function][:parameters][:required]).to include("old_string")
      expect(definition[:function][:parameters][:required]).to include("new_string")
    end
  end
end
