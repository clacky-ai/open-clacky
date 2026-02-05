# frozen_string_literal: true

require "tmpdir"

RSpec.describe Clacky::Utils::FileProcessor do
  describe ".image_path_to_data_url" do
    it "converts PNG image to data URL" do
      Dir.mktmpdir do |dir|
        png_file = File.join(dir, "test.png")
        png_data = "\x89PNG\r\n\x1a\n".b
        File.binwrite(png_file, png_data)

        data_url = described_class.image_path_to_data_url(png_file)

        expect(data_url).to start_with("data:image/png;base64,")
      end
    end

    it "converts JPEG image to data URL" do
      Dir.mktmpdir do |dir|
        jpeg_file = File.join(dir, "test.jpg")
        jpeg_data = "\xFF\xD8\xFF".b
        File.binwrite(jpeg_file, jpeg_data)

        data_url = described_class.image_path_to_data_url(jpeg_file)

        expect(data_url).to start_with("data:image/jpeg;base64,")
      end
    end

    it "raises error for non-existent file" do
      expect {
        described_class.image_path_to_data_url("/nonexistent/file.png")
      }.to raise_error(ArgumentError, /Image file not found/)
    end

    it "raises error for unsupported format" do
      Dir.mktmpdir do |dir|
        pdf_file = File.join(dir, "test.pdf")
        pdf_data = "%PDF-1.4".b
        File.binwrite(pdf_file, pdf_data)

        expect {
          described_class.image_path_to_data_url(pdf_file)
        }.to raise_error(ArgumentError, /Unsupported image format/)
      end
    end

    it "raises error for file too large" do
      Dir.mktmpdir do |dir|
        large_file = File.join(dir, "large.png")
        # Create a file larger than MAX_FILE_SIZE
        File.binwrite(large_file, "\x89PNG\r\n\x1a\n".b + "x" * (6 * 1024 * 1024))

        expect {
          described_class.image_path_to_data_url(large_file)
        }.to raise_error(ArgumentError, /File too large/)
      end
    end
  end

  describe ".file_to_base64" do
    it "converts PNG to base64 with metadata" do
      Dir.mktmpdir do |dir|
        png_file = File.join(dir, "test.png")
        png_data = "\x89PNG\r\n\x1a\n".b
        File.binwrite(png_file, png_data)

        result = described_class.file_to_base64(png_file)

        expect(result[:format]).to eq("png")
        expect(result[:mime_type]).to eq("image/png")
        expect(result[:base64_data]).to be_a(String)
        expect(result[:size_bytes]).to eq(png_data.size)
      end
    end

    it "converts PDF to base64 with metadata" do
      Dir.mktmpdir do |dir|
        pdf_file = File.join(dir, "test.pdf")
        pdf_data = "%PDF-1.4".b
        File.binwrite(pdf_file, pdf_data)

        result = described_class.file_to_base64(pdf_file)

        expect(result[:format]).to eq("pdf")
        expect(result[:mime_type]).to eq("application/pdf")
        expect(result[:base64_data]).to be_a(String)
        expect(result[:size_bytes]).to eq(pdf_data.size)
      end
    end

    it "raises error for file too large" do
      Dir.mktmpdir do |dir|
        large_file = File.join(dir, "large.pdf")
        File.binwrite(large_file, "%PDF".b + "x" * (6 * 1024 * 1024))

        expect {
          described_class.file_to_base64(large_file)
        }.to raise_error(ArgumentError, /File too large/)
      end
    end
  end

  describe ".detect_format" do
    it "detects PNG from extension" do
      Dir.mktmpdir do |dir|
        png_file = File.join(dir, "test.png")
        File.binwrite(png_file, "")

        format = described_class.detect_format(png_file, "")
        expect(format).to eq("png")
      end
    end

    it "detects PNG from magic bytes" do
      data = "\x89PNG\r\n\x1a\n".b
      format = described_class.detect_format("unknown", data)
      expect(format).to eq("png")
    end

    it "detects JPEG from magic bytes" do
      data = "\xFF\xD8\xFF".b
      format = described_class.detect_format("unknown", data)
      expect(format).to eq("jpg")
    end

    it "detects PDF from magic bytes" do
      data = "%PDF-1.4".b
      format = described_class.detect_format("unknown", data)
      expect(format).to eq("pdf")
    end

    it "detects WebP from magic bytes" do
      data = "RIFF\x00\x00\x00\x00WEBP".b
      format = described_class.detect_format("unknown", data)
      expect(format).to eq("webp")
    end

    it "returns nil for unknown format" do
      data = "unknown data".b
      format = described_class.detect_format("unknown", data)
      expect(format).to be_nil
    end
  end

  describe ".detect_mime_type" do
    it "detects PNG MIME type" do
      data = "\x89PNG\r\n\x1a\n".b
      mime_type = described_class.detect_mime_type("test.png", data)
      expect(mime_type).to eq("image/png")
    end

    it "detects JPEG MIME type" do
      data = "\xFF\xD8\xFF".b
      mime_type = described_class.detect_mime_type("test.jpg", data)
      expect(mime_type).to eq("image/jpeg")
    end

    it "detects PDF MIME type" do
      data = "%PDF-1.4".b
      mime_type = described_class.detect_mime_type("test.pdf", data)
      expect(mime_type).to eq("application/pdf")
    end

    it "returns octet-stream for unknown format" do
      data = "unknown".b
      mime_type = described_class.detect_mime_type("unknown", data)
      expect(mime_type).to eq("application/octet-stream")
    end
  end

  describe ".supported_binary_file?" do
    it "returns true for PNG files" do
      Dir.mktmpdir do |dir|
        png_file = File.join(dir, "test.png")
        File.binwrite(png_file, "")

        expect(described_class.supported_binary_file?(png_file)).to be true
      end
    end

    it "returns true for PDF files" do
      Dir.mktmpdir do |dir|
        pdf_file = File.join(dir, "test.pdf")
        File.binwrite(pdf_file, "")

        expect(described_class.supported_binary_file?(pdf_file)).to be true
      end
    end

    it "returns false for unsupported files" do
      Dir.mktmpdir do |dir|
        bin_file = File.join(dir, "test.bin")
        File.binwrite(bin_file, "")

        expect(described_class.supported_binary_file?(bin_file)).to be false
      end
    end

    it "returns false for non-existent files" do
      expect(described_class.supported_binary_file?("/nonexistent/file.png")).to be false
    end
  end

  describe ".image_file?" do
    it "returns true for PNG files" do
      Dir.mktmpdir do |dir|
        png_file = File.join(dir, "test.png")
        File.binwrite(png_file, "")

        expect(described_class.image_file?(png_file)).to be true
      end
    end

    it "returns false for PDF files" do
      Dir.mktmpdir do |dir|
        pdf_file = File.join(dir, "test.pdf")
        File.binwrite(pdf_file, "")

        expect(described_class.image_file?(pdf_file)).to be false
      end
    end

    it "returns false for non-existent files" do
      expect(described_class.image_file?("/nonexistent/file.png")).to be false
    end
  end

  describe ".pdf_file?" do
    it "returns true for PDF files" do
      Dir.mktmpdir do |dir|
        pdf_file = File.join(dir, "test.pdf")
        File.binwrite(pdf_file, "")

        expect(described_class.pdf_file?(pdf_file)).to be true
      end
    end

    it "returns false for image files" do
      Dir.mktmpdir do |dir|
        png_file = File.join(dir, "test.png")
        File.binwrite(png_file, "")

        expect(described_class.pdf_file?(png_file)).to be false
      end
    end
  end

  describe ".binary_file?" do
    it "detects binary file with high ratio of non-printable characters (>= 512 bytes)" do
      # Create data >= 512 bytes with high ratio of non-printable characters
      data = "\x00\x01\x02\x03\x04\x05" * 100
      expect(described_class.binary_file?(data)).to be true
    end

    it "returns false for short text files (below min length threshold)" do
      data = "This is plain text content\nwith multiple lines\n"
      expect(described_class.binary_file?(data)).to be false
    end

    it "returns false for short data with non-printable characters" do
      data = "text\x00binary".b
      expect(described_class.binary_file?(data)).to be false
    end

    it "handles empty data" do
      data = ""
      expect(described_class.binary_file?(data)).to be false
    end
  end
end
