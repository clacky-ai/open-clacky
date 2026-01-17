# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Tools::FileReader do
  let(:tool) { described_class.new }

  describe "#execute" do
    context "when reading a file" do
      it "reads file contents" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.txt")
          content = "Line 1\nLine 2\nLine 3\n"
          File.write(file_path, content)

          result = tool.execute(path: file_path)

          expect(result[:error]).to be_nil
          expect(result[:content]).to eq(content)
          expect(result[:lines_read]).to eq(3)
          expect(result[:truncated]).to be false
        end
      end

      it "truncates content when exceeding max_lines" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.txt")
          content = (1..100).map { |i| "Line #{i}\n" }.join
          File.write(file_path, content)

          result = tool.execute(path: file_path, max_lines: 10)

          expect(result[:error]).to be_nil
          expect(result[:lines_read]).to eq(10)
          expect(result[:truncated]).to be true
        end
      end

      it "returns error for non-existent file" do
        result = tool.execute(path: "/nonexistent/file.txt")

        expect(result[:error]).to include("File not found")
        expect(result[:content]).to be_nil
      end
    end

    context "when reading a directory" do
      it "lists first-level files and directories" do
        Dir.mktmpdir do |dir|
          # Create some files and directories
          File.write(File.join(dir, "file1.txt"), "content")
          File.write(File.join(dir, "file2.rb"), "code")
          Dir.mkdir(File.join(dir, "subdir1"))
          Dir.mkdir(File.join(dir, "subdir2"))

          result = tool.execute(path: dir)

          expect(result[:error]).to be_nil
          expect(result[:is_directory]).to be true
          expect(result[:entries_count]).to eq(4)
          expect(result[:directories_count]).to eq(2)
          expect(result[:files_count]).to eq(2)
          expect(result[:content]).to include("Directory listing:")
          expect(result[:content]).to include("subdir1/")
          expect(result[:content]).to include("subdir2/")
          expect(result[:content]).to include("file1.txt")
          expect(result[:content]).to include("file2.rb")
        end
      end

      it "lists directories before files" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "aaa.txt"), "content")
          Dir.mkdir(File.join(dir, "zzz"))

          result = tool.execute(path: dir)

          expect(result[:error]).to be_nil
          lines = result[:content].split("\n")
          # First line is "Directory listing:", second is directory, third is file
          expect(lines[1]).to include("zzz/")
          expect(lines[2]).to include("aaa.txt")
        end
      end

      it "sorts entries alphabetically within their type" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "zebra.txt"), "content")
          File.write(File.join(dir, "apple.txt"), "content")
          Dir.mkdir(File.join(dir, "zoo"))
          Dir.mkdir(File.join(dir, "ant"))

          result = tool.execute(path: dir)

          expect(result[:error]).to be_nil
          lines = result[:content].split("\n")
          # Check directories are sorted (ant before zoo)
          dir_lines = lines.select { |l| l.include?("/") }
          expect(dir_lines[0]).to include("ant/")
          expect(dir_lines[1]).to include("zoo/")
          # Check files are sorted (apple before zebra)
          file_lines = lines.reject { |l| l.include?("/") || l.include?("Directory listing:") }
          expect(file_lines[0]).to include("apple.txt")
          expect(file_lines[1]).to include("zebra.txt")
        end
      end

      it "handles empty directory" do
        Dir.mktmpdir do |dir|
          result = tool.execute(path: dir)

          expect(result[:error]).to be_nil
          expect(result[:is_directory]).to be true
          expect(result[:entries_count]).to eq(0)
          expect(result[:directories_count]).to eq(0)
          expect(result[:files_count]).to eq(0)
        end
      end
    end
  end

  describe "#format_call" do
    it "formats file path" do
      formatted = tool.format_call(path: "/path/to/file.txt")
      expect(formatted).to eq("Read(file.txt)")
    end
  end

  describe "#format_result" do
    it "formats file reading result" do
      result = { lines_read: 10, truncated: false }
      formatted = tool.format_result(result)
      expect(formatted).to eq("Read 10 lines")
    end

    it "formats truncated file reading result" do
      result = { lines_read: 100, truncated: true }
      formatted = tool.format_result(result)
      expect(formatted).to eq("Read 100 lines (truncated)")
    end

    it "formats directory listing result" do
      result = { is_directory: true, entries_count: 10, directories_count: 3, files_count: 7 }
      formatted = tool.format_result(result)
      expect(formatted).to eq("Listed 10 entries (3 directories, 7 files)")
    end

    it "formats error result" do
      result = { error: "File not found" }
      formatted = tool.format_result(result)
      expect(formatted).to eq("File not found")
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("file_reader")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:description]).to include("directory")
      expect(definition[:function][:parameters][:required]).to include("path")
    end
  end
end
