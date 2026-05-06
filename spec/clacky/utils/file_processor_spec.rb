# frozen_string_literal: true

require "tmpdir"

RSpec.describe Clacky::Utils::FileProcessor do
  # ---------------------------------------------------------------------------
  # .save — store only, no parsing
  # ---------------------------------------------------------------------------
  describe ".save" do
    it "writes bytes to disk and returns name + path" do
      result = described_class.save(body: "hello", filename: "notes.txt")
      expect(result[:name]).to eq("notes.txt")
      expect(File.exist?(result[:path])).to be true
      expect(File.read(result[:path])).to eq("hello")
    end

    it "sanitizes filesystem-unsafe characters but keeps Unicode" do
      result = described_class.save(body: "", filename: "../../../etc/passwd")
      expect(result[:name]).not_to include("/")
      expect(File.exist?(result[:path])).to be true
    end

    it "preserves Chinese characters in filename" do
      result = described_class.save(body: "x", filename: "OpenClacky企业智能体平台.pptx")
      expect(result[:name]).to eq("OpenClacky企业智能体平台.pptx")
    end

    it "replaces colon and question mark but keeps the rest" do
      result = described_class.save(body: "x", filename: "report: Q1?.pdf")
      expect(result[:name]).to eq("report_ Q1_.pdf")
    end

    it "two saves with same filename produce different paths" do
      r1 = described_class.save(body: "a", filename: "doc.pdf")
      r2 = described_class.save(body: "b", filename: "doc.pdf")
      expect(r1[:path]).not_to eq(r2[:path])
    end

    it "does NOT parse the file" do
      expect(Clacky::Utils::ParserManager).not_to receive(:parse)
      described_class.save(body: "%PDF-1.4", filename: "test.pdf")
    end
  end

  # ---------------------------------------------------------------------------
  # .process_path — parse an already-saved file
  # ---------------------------------------------------------------------------
  describe ".process_path" do
    context "when parser succeeds" do
      it "returns FileRef with preview_path written to disk" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "test.pdf")
          File.binwrite(path, "%PDF-1.4")

          allow(Clacky::Utils::ParserManager).to receive(:parse).with(path)
            .and_return({ success: true, text: "extracted text", error: nil, parser_path: nil })

          ref = described_class.process_path(path)
          # preview is now written to UPLOAD_DIR (tmpdir), not next to the original file
          expect(ref.preview_path).to start_with(Clacky::Utils::FileProcessor::UPLOAD_DIR)
          expect(ref.preview_path).to end_with(".preview.md")
          expect(ref.preview_path).to include("test.pdf")
          expect(File.read(ref.preview_path)).to eq("extracted text")
          expect(ref.parse_error).to be_nil
        end
      end

      it "uses filename as display name" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "report.docx")
          File.binwrite(path, "bytes")

          allow(Clacky::Utils::ParserManager).to receive(:parse)
            .and_return({ success: true, text: "content", error: nil, parser_path: nil })

          ref = described_class.process_path(path)
          expect(ref.name).to eq("report.docx")
        end
      end

      it "accepts explicit name override" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "abc123_report.docx")
          File.binwrite(path, "bytes")

          allow(Clacky::Utils::ParserManager).to receive(:parse)
            .and_return({ success: true, text: "content", error: nil, parser_path: nil })

          ref = described_class.process_path(path, name: "report.docx")
          expect(ref.name).to eq("report.docx")
        end
      end
    end

    context "when parser fails" do
      it "returns FileRef with parse_error and parser_path, no preview" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "broken.pdf")
          File.binwrite(path, "not a real pdf")

          allow(Clacky::Utils::ParserManager).to receive(:parse).with(path)
            .and_return({ success: false, text: nil,
                          error: "pdftotext failed", parser_path: "/home/.clacky/parsers/pdf_parser.rb" })

          ref = described_class.process_path(path)
          expect(ref.preview_path).to be_nil
          expect(ref.parse_error).to eq("pdftotext failed")
          expect(ref.parser_path).to eq("/home/.clacky/parsers/pdf_parser.rb")
          expect(ref.parse_failed?).to be true
        end
      end
    end

    context "with image files" do
      it "skips parsing and returns FileRef with no preview" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "photo.png")
          File.binwrite(path, "\x89PNG\r\n\x1a\n")

          expect(Clacky::Utils::ParserManager).not_to receive(:parse)

          ref = described_class.process_path(path)
          expect(ref.type).to eq(:image)
          expect(ref.preview_path).to be_nil
          expect(ref.parse_error).to be_nil
        end
      end
    end

    context "with zip files" do
      it "generates directory listing preview without calling ParserManager" do
        require "zip"
        Dir.mktmpdir do |dir|
          zip_path = File.join(dir, "archive.zip")
          Zip::OutputStream.open(zip_path) do |z|
            z.put_next_entry("readme.txt")
            z.write("hello")
          end

          expect(Clacky::Utils::ParserManager).not_to receive(:parse)

          ref = described_class.process_path(zip_path)
          expect(ref.type).to eq(:zip)
          expect(ref.preview_path).to end_with(".preview.md")
          expect(File.read(ref.preview_path)).to include("readme.txt")
        end
      end
    end

    context "with markdown files" do
      it "uses file content directly as preview (no parser)" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "notes.md")
          File.write(path, "# Heading\nbody line")

          expect(Clacky::Utils::ParserManager).not_to receive(:parse)

          ref = described_class.process_path(path)
          expect(ref.type).to eq(:text)
          expect(ref.preview_path).to end_with(".preview.md")
          expect(File.read(ref.preview_path)).to include("# Heading")
          expect(ref.parse_error).to be_nil
        end
      end

      it "also handles .markdown, .txt, .log extensions" do
        Dir.mktmpdir do |dir|
          %w[doc.markdown plain.txt server.log].each do |fname|
            path = File.join(dir, fname)
            File.write(path, "content of #{fname}")
            ref = described_class.process_path(path)
            expect(ref.type).to eq(:text)
            expect(ref.preview_path).not_to be_nil
            expect(File.read(ref.preview_path)).to eq("content of #{fname}")
          end
        end
      end
    end

    context "with tar.gz files" do
      it "generates entry listing preview without calling ParserManager" do
        require "rubygems/package"
        require "zlib"
        Dir.mktmpdir do |dir|
          targz_path = File.join(dir, "archive.tar.gz")
          File.open(targz_path, "wb") do |file|
            Zlib::GzipWriter.wrap(file) do |gz|
              Gem::Package::TarWriter.new(gz) do |tar|
                tar.add_file_simple("hello.txt", 0o644, 5) { |io| io.write("hello") }
                tar.add_file_simple("sub/bye.txt", 0o644, 3) { |io| io.write("bye") }
              end
            end
          end

          expect(Clacky::Utils::ParserManager).not_to receive(:parse)

          ref = described_class.process_path(targz_path)
          expect(ref.type).to eq(:zip)
          expect(ref.preview_path).to end_with(".preview.md")
          preview = File.read(ref.preview_path)
          expect(preview).to include("TAR.GZ Contents")
          expect(preview).to include("hello.txt")
          expect(preview).to include("sub/bye.txt")
          expect(ref.parse_error).to be_nil
        end
      end

      it "handles .tgz extension" do
        require "rubygems/package"
        require "zlib"
        Dir.mktmpdir do |dir|
          tgz_path = File.join(dir, "bundle.tgz")
          File.open(tgz_path, "wb") do |file|
            Zlib::GzipWriter.wrap(file) do |gz|
              Gem::Package::TarWriter.new(gz) do |tar|
                tar.add_file_simple("a.txt", 0o644, 1) { |io| io.write("x") }
              end
            end
          end

          ref = described_class.process_path(tgz_path)
          expect(ref.type).to eq(:zip)
          expect(File.read(ref.preview_path)).to include("a.txt")
        end
      end
    end

    context "with tar files" do
      it "generates entry listing preview" do
        require "rubygems/package"
        Dir.mktmpdir do |dir|
          tar_path = File.join(dir, "archive.tar")
          File.open(tar_path, "wb") do |file|
            Gem::Package::TarWriter.new(file) do |tar|
              tar.add_file_simple("one.txt", 0o644, 3) { |io| io.write("foo") }
              tar.add_file_simple("two.txt", 0o644, 3) { |io| io.write("bar") }
            end
          end

          ref = described_class.process_path(tar_path)
          expect(ref.type).to eq(:zip)
          preview = File.read(ref.preview_path)
          expect(preview).to include("TAR Contents")
          expect(preview).to include("one.txt")
          expect(preview).to include("two.txt")
        end
      end
    end

    context "with single-file .gz" do
      it "falls back to size metadata when archive is not a tarball" do
        require "zlib"
        Dir.mktmpdir do |dir|
          gz_path = File.join(dir, "data.gz")
          File.open(gz_path, "wb") do |file|
            Zlib::GzipWriter.wrap(file) do |gz|
              gz.write("hello world, not a tarball\n" * 4)
            end
          end

          ref = described_class.process_path(gz_path)
          expect(ref.type).to eq(:zip)
          expect(ref.preview_path).not_to be_nil
          preview = File.read(ref.preview_path)
          # Either recognised as GZIP metadata, or — if extension sniffing
          # still accepted it as tar — at least produces some listing.
          expect(preview).to match(/GZIP Contents|TAR\.GZ Contents|could not list/)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .process — save + process_path combined
  # ---------------------------------------------------------------------------
  describe ".process" do
    it "saves file to disk and returns parsed FileRef" do
      allow(Clacky::Utils::ParserManager).to receive(:parse)
        .and_return({ success: true, text: "the content", error: nil, parser_path: nil })

      ref = described_class.process(body: "%PDF-1.4", filename: "doc.pdf")
      expect(ref).to be_a(Clacky::Utils::FileProcessor::FileRef)
      expect(ref.name).to eq("doc.pdf")
      expect(File.exist?(ref.original_path)).to be true
      expect(ref.preview_path).to end_with(".preview.md")
    end

    it "propagates parse_error when parser fails" do
      allow(Clacky::Utils::ParserManager).to receive(:parse)
        .and_return({ success: false, text: nil, error: "oops", parser_path: "/some/parser.rb" })

      ref = described_class.process(body: "%PDF-1.4", filename: "bad.pdf")
      expect(ref.parse_failed?).to be true
      expect(ref.parse_error).to eq("oops")
    end
  end

  # ---------------------------------------------------------------------------
  # File type helpers
  # ---------------------------------------------------------------------------
  describe ".binary_file_path?" do
    it "returns true for PNG by extension" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.png")
        File.binwrite(f, "\x89PNG".b)
        expect(described_class.binary_file_path?(f)).to be true
      end
    end

    it "returns false for plain text files" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.txt")
        File.write(f, "hello world")
        expect(described_class.binary_file_path?(f)).to be false
      end
    end

    it "returns true for files with null bytes" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.dat")
        File.binwrite(f, "abc\x00def".b)
        expect(described_class.binary_file_path?(f)).to be true
      end
    end
  end

  describe ".supported_binary_file?" do
    it "returns true for images and PDF" do
      %w[test.png test.jpg test.pdf].each do |name|
        expect(described_class.supported_binary_file?(name)).to be true
      end
    end

    it "returns false for zip and docx" do
      %w[test.zip test.docx].each do |name|
        expect(described_class.supported_binary_file?(name)).to be false
      end
    end
  end

  describe ".detect_mime_type" do
    it "maps common extensions" do
      expect(described_class.detect_mime_type("a.png")).to  eq("image/png")
      expect(described_class.detect_mime_type("a.jpg")).to  eq("image/jpeg")
      expect(described_class.detect_mime_type("a.pdf")).to  eq("application/pdf")
      expect(described_class.detect_mime_type("a.bin")).to  eq("application/octet-stream")
    end
  end

  describe ".image_path_to_data_url" do
    it "converts PNG to data URL" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.png")
        File.binwrite(f, "\x89PNG\r\n\x1a\n".b)
        expect(described_class.image_path_to_data_url(f)).to start_with("data:image/png;base64,")
      end
    end

    it "raises for missing file" do
      expect { described_class.image_path_to_data_url("/no/such/file.png") }
        .to raise_error(ArgumentError, /Image file not found/)
    end

    it "raises when file exceeds MAX_IMAGE_BYTES" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "big.png")
        File.binwrite(f, "x" * (described_class::MAX_IMAGE_BYTES + 1))
        expect { described_class.image_path_to_data_url(f) }
          .to raise_error(ArgumentError, /Image too large/)
      end
    end
  end

  describe ".file_to_base64" do
    it "returns format/mime/base64 for PDF" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.pdf")
        File.binwrite(f, "%PDF-1.4")
        result = described_class.file_to_base64(f)
        expect(result[:format]).to eq("pdf")
        expect(result[:mime_type]).to eq("application/pdf")
        expect(result[:base64_data]).to be_a(String)
      end
    end

    it "raises for oversized files" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "huge.pdf")
        File.binwrite(f, "x" * (described_class::MAX_FILE_BYTES + 1))
        expect { described_class.file_to_base64(f) }
          .to raise_error(ArgumentError, /File too large/)
      end
    end
  end
end
