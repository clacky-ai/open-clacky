# frozen_string_literal: true

require "tempfile"
require "tmpdir"
require "json"

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

      it "expands ~ to home directory" do
        Dir.mktmpdir do |dir|
          # Create a test file in temp directory
          file_path = File.join(dir, "test.txt")
          content = "Test content\n"
          File.write(file_path, content)

          # Get the home directory path
          home_dir = Dir.home

          # Test with a path that uses ~
          # We'll use ENV to temporarily change HOME for testing
          original_home = ENV["HOME"]
          begin
            ENV["HOME"] = dir
            result = tool.execute(path: "~/test.txt")

            expect(result[:error]).to be_nil
            expect(result[:content]).to eq(content)
            expect(result[:path]).to eq(file_path)
          ensure
            ENV["HOME"] = original_home
          end
        end
      end

      context "when reading with line range" do
        it "reads lines within valid range" do
          Dir.mktmpdir do |dir|
            file_path = File.join(dir, "test.txt")
            content = (1..20).map { |i| "Line #{i}\n" }.join
            File.write(file_path, content)

            result = tool.execute(path: file_path, start_line: 5, end_line: 10)

            expect(result[:error]).to be_nil
            expect(result[:content]).to eq("Line 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\n")
            expect(result[:lines_read]).to eq(6)
            expect(result[:start_line]).to eq(5)
            expect(result[:end_line]).to eq(10)
          end
        end

        it "clamps end_line to file length" do
          Dir.mktmpdir do |dir|
            file_path = File.join(dir, "test.txt")
            content = (1..10).map { |i| "Line #{i}\n" }.join
            File.write(file_path, content)

            result = tool.execute(path: file_path, start_line: 5, end_line: 100)

            expect(result[:error]).to be_nil
            expect(result[:content]).to eq("Line 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\n")
            expect(result[:lines_read]).to eq(6)
          end
        end

        it "returns error when start_line exceeds total lines" do
          Dir.mktmpdir do |dir|
            file_path = File.join(dir, "test.txt")
            content = (1..10).map { |i| "Line #{i}\n" }.join
            File.write(file_path, content)

            result = tool.execute(path: file_path, start_line: 100, end_line: 200)

            expect(result[:error]).to include("exceeds total lines")
            expect(result[:content]).to be_nil
          end
        end

        it "returns error when start_line is greater than end_line" do
          Dir.mktmpdir do |dir|
            file_path = File.join(dir, "test.txt")
            content = (1..10).map { |i| "Line #{i}\n" }.join
            File.write(file_path, content)

            result = tool.execute(path: file_path, start_line: 8, end_line: 5)

            expect(result[:error]).to include("start_line 8 > end_line 5")
            expect(result[:content]).to be_nil
          end
        end

        it "reads from start_line to end of file when end_line not specified" do
          Dir.mktmpdir do |dir|
            file_path = File.join(dir, "test.txt")
            content = (1..50).map { |i| "Line #{i}\n" }.join
            File.write(file_path, content)

            result = tool.execute(path: file_path, start_line: 45)

            expect(result[:error]).to be_nil
            expect(result[:lines_read]).to eq(6)
            expect(result[:content]).to eq("Line 45\nLine 46\nLine 47\nLine 48\nLine 49\nLine 50\n")
          end
        end

        it "handles start_line at file boundary" do
          Dir.mktmpdir do |dir|
            file_path = File.join(dir, "test.txt")
            content = (1..10).map { |i| "Line #{i}\n" }.join
            File.write(file_path, content)

            result = tool.execute(path: file_path, start_line: 10, end_line: 15)

            expect(result[:error]).to be_nil
            expect(result[:content]).to eq("Line 10\n")
            expect(result[:lines_read]).to eq(1)
          end
        end

        it "reads from start_line with max_lines limit (start_line + max_lines)" do
          Dir.mktmpdir do |dir|
            file_path = File.join(dir, "test.txt")
            content = (1..50).map { |i| "Line #{i}\n" }.join
            File.write(file_path, content)

            result = tool.execute(path: file_path, start_line: 10, max_lines: 5)

            expect(result[:error]).to be_nil
            expect(result[:lines_read]).to eq(5)
            expect(result[:content]).to eq("Line 10\nLine 11\nLine 12\nLine 13\nLine 14\n")
          end
        end

        it "clamps to file end when start_line + max_lines exceeds file length" do
          Dir.mktmpdir do |dir|
            file_path = File.join(dir, "test.txt")
            content = (1..20).map { |i| "Line #{i}\n" }.join
            File.write(file_path, content)

            result = tool.execute(path: file_path, start_line: 15, max_lines: 10)

            expect(result[:error]).to be_nil
            expect(result[:lines_read]).to eq(6)
            expect(result[:content]).to eq("Line 15\nLine 16\nLine 17\nLine 18\nLine 19\nLine 20\n")
          end
        end

        it "returns error when start_line + max_lines would exceed file but still valid" do
          Dir.mktmpdir do |dir|
            file_path = File.join(dir, "test.txt")
            content = (1..20).map { |i| "Line #{i}\n" }.join
            File.write(file_path, content)

            # This should NOT error - start_line 15 with max_lines 10 should just read to end (line 20)
            result = tool.execute(path: file_path, start_line: 15, max_lines: 10)

            expect(result[:error]).to be_nil
            expect(result[:lines_read]).to eq(6)
          end
        end
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

  describe "binary file detection" do
    context "when reading binary files" do
      it "detects PNG images" do
        Dir.mktmpdir do |dir|
          png_file = File.join(dir, "test.png")
          png_data = "\x89PNG\r\n\x1a\n".b
          File.binwrite(png_file, png_data)

          result = tool.execute(path: png_file)

          expect(result[:binary]).to be true
          expect(result[:format]).to eq("png")
          expect(result[:mime_type]).to eq("image/png")
          expect(result[:base64_data]).to be_a(String)
        end
      end

      it "detects JPEG images" do
        Dir.mktmpdir do |dir|
          jpeg_file = File.join(dir, "test.jpg")
          jpeg_data = "\xFF\xD8\xFF".b
          File.binwrite(jpeg_file, jpeg_data)

          result = tool.execute(path: jpeg_file)

          expect(result[:binary]).to be true
          expect(result[:format]).to eq("jpg")
          expect(result[:mime_type]).to eq("image/jpeg")
        end
      end

      it "delegates PDF files to parser (auto-extracts text, no base64)" do
        Dir.mktmpdir do |dir|
          pdf_file = File.join(dir, "test.pdf")
          # A fake PDF payload — the parser will fail to extract text from it,
          # but that failure is handled gracefully: we get a parser-failure hash,
          # NOT a base64 binary blob. This is the behaviour we want post-refactor.
          pdf_data = "%PDF-1.4\n% fake".b
          File.binwrite(pdf_file, pdf_data)

          result = tool.execute(path: pdf_file)

          # Parser fails on this fake PDF → we should get a parser-failure result
          # carrying the parser_path so the LLM knows how to fix/retry.
          expect(result[:binary]).to be true
          expect(result[:format]).to eq("pdf")
          expect(result[:content]).to be_nil
          expect(result[:error]).to include("Failed to extract text")
          expect(result[:parser_path]).to be_a(String).and include("pdf_parser.rb")
          # Critically: no base64 payload (old behaviour sent the whole PDF as base64).
          expect(result[:base64_data]).to be_nil
        end
      end

      it "returns a text result when parser succeeds on a PDF" do
        # Simulate a successful parse by stubbing FileProcessor.process_path to
        # return a FileRef with a real preview_path. This isolates FileReader
        # from the actual pdftotext binary, keeping the spec fast and portable.
        Dir.mktmpdir do |dir|
          pdf_file = File.join(dir, "real.pdf")
          File.binwrite(pdf_file, "%PDF-1.4\n%%EOF".b)

          preview_path = File.join(dir, "real.pdf.preview.md")
          File.write(preview_path, "Extracted line 1\nExtracted line 2\n")

          fake_ref = Clacky::Utils::FileProcessor::FileRef.new(
            name: "real.pdf", type: :pdf,
            original_path: pdf_file, preview_path: preview_path
          )
          allow(Clacky::Utils::FileProcessor).to receive(:process_path).and_return(fake_ref)

          result = tool.execute(path: pdf_file)

          expect(result[:error]).to be_nil
          expect(result[:content]).to include("Extracted line 1")
          expect(result[:content]).to include("Extracted line 2")
          expect(result[:parsed_from]).to eq("pdf")
          expect(result[:source_path]).to eq(preview_path)
          expect(result[:total_lines]).to eq(2)
          expect(result[:binary]).to be_nil
        end
      end

      it "truncates oversized parser output (no token blow-up)" do
        Dir.mktmpdir do |dir|
          pdf_file = File.join(dir, "huge.pdf")
          File.binwrite(pdf_file, "%PDF-1.4".b)

          # Produce a preview larger than MAX_CONTENT_CHARS worth of text.
          preview_path = File.join(dir, "huge.pdf.preview.md")
          big = ("x" * 200 + "\n") * 1000  # ~200k chars, well over MAX_CONTENT_CHARS
          File.write(preview_path, big)

          fake_ref = Clacky::Utils::FileProcessor::FileRef.new(
            name: "huge.pdf", type: :pdf,
            original_path: pdf_file, preview_path: preview_path
          )
          allow(Clacky::Utils::FileProcessor).to receive(:process_path).and_return(fake_ref)

          result = tool.execute(path: pdf_file)

          expect(result[:error]).to be_nil
          expect(result[:truncated]).to be true
          # Content must be bounded — this is the whole point of the refactor.
          expect(result[:content].length).to be <= (described_class::MAX_CONTENT_CHARS + 500)
        end
      end

      it "returns error for unsupported binary files" do
        Dir.mktmpdir do |dir|
          bin_file = File.join(dir, "test.bin")
          # Use JPEG magic bytes to trigger binary detection
          File.binwrite(bin_file, "\xFF\xD8\xFF".b + "\x00".b * 200)

          result = tool.execute(path: bin_file)

          expect(result[:binary]).to be true
          expect(result[:error]).to include("Binary file detected")
          expect(result[:base64_data]).to be_nil
        end
      end
    end
  end

  describe "#format_result_for_llm" do
    it "formats image file for LLM with image_inject sidecar (not inline Array)" do
      result = {
        binary: true,
        path: "/path/to/image.png",
        format: "png",
        size_bytes: 1024,
        mime_type: "image/png",
        base64_data: "iVBORw0KG..."
      }

      formatted = tool.format_result_for_llm(result)

      # Should return a Hash with plain text + image_inject sidecar,
      # NOT an Array — images must be delivered via a follow-up user message,
      # not inside a tool message (OpenAI-compatible APIs reject image_url in tool role).
      expect(formatted).to be_a(Hash)
      expect(formatted[:type]).to eq("text")
      expect(formatted[:text]).to include("image.png")

      inject = formatted[:image_inject]
      expect(inject).to be_a(Hash)
      expect(inject[:mime_type]).to eq("image/png")
      expect(inject[:base64_data]).to eq("iVBORw0KG...")
      expect(inject[:path]).to eq("/path/to/image.png")
    end

    it "returns a plain string for non-binary files (avoids JSON double-escaping)" do
      result = { path: "/tmp/foo.rb", content: "text content", lines_read: 10, total_lines: 10, truncated: false, start_line: nil, end_line: nil }
      formatted = tool.format_result_for_llm(result)
      expect(formatted).to be_a(String)
      expect(formatted).to include("text content")
      expect(formatted).to include("/tmp/foo.rb")
    end
  end

  describe "UTF-8 safety" do
    it "scrubs invalid UTF-8 bytes in file content (e.g. GBK-encoded files)" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "gbk.txt")
        # GBK bytes for "你好" — illegal as UTF-8
        File.binwrite(file_path, "\xC4\xE3\xBA\xC3\n")

        result = tool.execute(path: file_path)

        expect(result[:error]).to be_nil
        content = result[:content]
        expect(content.encoding).to eq(Encoding::UTF_8)
        expect(content.valid_encoding?).to be(true)
        # JSON.generate must not raise — this is the exact downstream failure
        # that produced "500: source sequence is illegal/malformed utf-8".
        expect { JSON.generate(data: content) }.not_to raise_error
      end
    end

    it "scrubs invalid UTF-8 bytes in directory entry names" do
      # macOS APFS/HFS+ enforce UTF-8 filenames, so we can't create a bad
      # filename on disk portably. Stub Dir.entries to simulate Linux filesystems
      # where non-UTF-8 names are possible.
      Dir.mktmpdir do |dir|
        bad_name = "\xC4\xE3\xBA\xC3.txt".b  # BINARY encoding, invalid UTF-8
        allow(Dir).to receive(:entries).with(dir).and_return([".", "..", bad_name])
        # File.directory? should still work for "." check and return false for the fake name
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with(File.join(dir, bad_name).encode("UTF-8", invalid: :replace, undef: :replace, replace: "\u{FFFD}")).and_return(false)

        result = tool.execute(path: dir)

        expect(result[:is_directory]).to be(true)
        expect(result[:content].encoding).to eq(Encoding::UTF_8)
        expect(result[:content].valid_encoding?).to be(true)
        expect { JSON.generate(data: result[:content]) }.not_to raise_error
      end
    end
  end
end
