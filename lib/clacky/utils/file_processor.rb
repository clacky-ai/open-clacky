# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "securerandom"
require "stringio"

require_relative "file_parser/doc_parser"
require_relative "file_parser/docx_parser"
require_relative "file_parser/pdf_parser"
require_relative "file_parser/xlsx_parser"
require_relative "file_parser/pptx_parser"
require_relative "file_parser/zip_parser"

module Clacky
  module Utils
  # Unified file processing pipeline.
  #
  # For every uploaded file we:
  #   1. Save the original to disk (so the agent can always access the raw bytes).
  #   2. Generate a structured preview (Markdown) where possible.
  #   3. Return a FileRef struct describing both paths.
  #
  # The agent prompt receives a concise block like:
  #
  #   [File: contract.docx]
  #   Type: document
  #   Original: /tmp/clacky-uploads/abc123.docx
  #   Preview (Markdown): /tmp/clacky-uploads/abc123.docx.preview.md
  #
  # This gives the LLM structure-aware content immediately while keeping the
  # original available for deeper processing via shell tools.
  module FileProcessor
    UPLOAD_DIR      = File.join(Dir.tmpdir, "clacky-uploads").freeze
    MAX_FILE_BYTES  = 32 * 1024 * 1024  # 32 MB
    MAX_IMAGE_BYTES = 512 * 1024         # 512 KB

    # Alias used by FileReader tool
    MAX_FILE_SIZE = MAX_FILE_BYTES

    BINARY_EXTENSIONS = %w[
      .png .jpg .jpeg .gif .webp .bmp .tiff .ico .svg
      .pdf
      .zip .gz .tar .rar .7z
      .exe .dll .so .dylib
      .mp3 .mp4 .avi .mov .mkv .wav .flac
      .ttf .otf .woff .woff2
      .db .sqlite .bin .dat
    ].freeze

    # Binary files that glob should still return (useful as file references even if unreadable)
    GLOB_ALLOWED_BINARY_EXTENSIONS = %w[
      .pdf .doc .docx .ppt .pptx .xls .xlsx .odt .odp .ods
    ].freeze

    # Extensions that can be sent to LLM as base64 (images + PDF for native-support models)
    LLM_BINARY_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .pdf].freeze

    MIME_TYPES = {
      ".png"  => "image/png",
      ".jpg"  => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".gif"  => "image/gif",
      ".webp" => "image/webp",
      ".pdf"  => "application/pdf"
    }.freeze

    # Result struct returned by .process
    FileRef = Struct.new(:name, :type, :original_path, :preview_path, keyword_init: true) do
      # Returns a formatted string to inject into the agent prompt.
      def to_prompt
        lines = ["[File: #{name}]", "Type: #{type}"]
        lines << "Original: #{original_path}" if original_path
        lines << "Preview (Markdown): #{preview_path}" if preview_path
        lines.join("\n")
      end
    end

    # Process an uploaded file.
    #
    # @param body      [String] Raw file bytes
    # @param filename  [String] Original filename (used for extension detection + display)
    # @return [FileRef]
    def self.process(body:, filename:)
      FileUtils.mkdir_p(UPLOAD_DIR)

      ext       = File.extname(filename.to_s).downcase
      safe_name = sanitize_filename(filename)
      file_id   = SecureRandom.hex(8)

      case ext
      when ".docx"
        process_office(body, file_id, safe_name, :document) { FileParser::DocxParser.parse(body) }

      when ".doc"
        process_office(body, file_id, safe_name, :document) { FileParser::DocParser.parse(body) }

      when ".xlsx", ".xls"
        process_office(body, file_id, safe_name, :spreadsheet) { FileParser::XlsxParser.parse(body) }

      when ".pptx", ".ppt"
        process_office(body, file_id, safe_name, :presentation) { FileParser::PptxParser.parse(body) }

      when ".zip"
        process_zip(body, file_id, safe_name)

      when ".pdf"
        process_office(body, file_id, safe_name, :pdf) { FileParser::PdfParser.parse(body) }

      when ".png", ".jpg", ".jpeg", ".gif", ".webp"
        process_binary(body, file_id, safe_name, :image)

      else
        process_binary(body, file_id, safe_name, :file)
      end
    end

    # --- private ---

    # Save original + generate markdown preview via the given block.
    def self.process_office(body, file_id, safe_name, type)
      original_path = save_original(body, file_id, safe_name)

      preview_content = yield
      preview_path    = save_preview(preview_content, file_id, safe_name)

      FileRef.new(name: safe_name, type: type, original_path: original_path, preview_path: preview_path)
    rescue => e
      # If preview generation fails, still return the original path
      FileRef.new(name: safe_name, type: type, original_path: original_path,
                  preview_path: nil)
    end

    # ZIP: save original + generate directory listing as preview.
    def self.process_zip(body, file_id, safe_name)
      original_path   = save_original(body, file_id, safe_name)
      preview_content = FileParser::ZipParser.parse(body)
      preview_path    = save_preview(preview_content, file_id, safe_name)

      FileRef.new(name: safe_name, type: :zip, original_path: original_path, preview_path: preview_path)
    end

    # Binary files (PDF, images, unknown): save original only.
    def self.process_binary(body, file_id, safe_name, type)
      original_path = save_original(body, file_id, safe_name)
      FileRef.new(name: safe_name, type: type, original_path: original_path, preview_path: nil)
    end

    def self.save_original(body, file_id, safe_name)
      dest = File.join(UPLOAD_DIR, "#{file_id}_#{safe_name}")
      File.binwrite(dest, body)
      dest
    end

    def self.save_preview(content, file_id, safe_name)
      dest = File.join(UPLOAD_DIR, "#{file_id}_#{safe_name}.preview.md")
      File.write(dest, content, encoding: "UTF-8")
      dest
    end

    def self.sanitize_filename(name)
      base = File.basename(name.to_s).gsub(/[^\w.\-]/, "_")
      base.empty? ? "upload" : base
    end

    # Returns true if the file is binary (non-text).
    def self.binary_file_path?(path)
      ext = File.extname(path).downcase
      return true if BINARY_EXTENSIONS.include?(ext)

      # Fallback: sniff first 512 bytes for null bytes
      sample = File.binread(path, 512).to_s
      sample.include?("\x00")
    rescue
      false
    end

    # Returns true if the file is binary but should still appear in glob results.
    # (e.g. PDF, Office docs — useful as file references even if content is unreadable)
    def self.glob_allowed_binary?(path)
      ext = File.extname(path).downcase
      GLOB_ALLOWED_BINARY_EXTENSIONS.include?(ext)
    end

    # Returns true if the binary file can be sent to LLM as base64.
    def self.supported_binary_file?(path)
      ext = File.extname(path).downcase
      LLM_BINARY_EXTENSIONS.include?(ext)
    end

    # Save raw image bytes to disk and return a FileRef.
    # Used by agent when an image exceeds MAX_IMAGE_BYTES and must be downgraded to a file.
    # @param body      [String] Raw image bytes
    # @param mime_type [String] e.g. "image/jpeg"
    # @param filename  [String] Suggested filename
    # @return [FileRef]
    def self.save_image_to_disk(body:, mime_type:, filename: "image.jpg")
      FileUtils.mkdir_p(UPLOAD_DIR)
      ext       = File.extname(filename).downcase
      ext       = ".#{mime_type.split('/').last}" if ext.empty? && mime_type.to_s.start_with?("image/")
      ext       = ".jpg" if ext.empty?
      safe_name = sanitize_filename(filename)
      file_id   = SecureRandom.hex(8)
      process_binary(body, file_id, safe_name, :image)
    end

    # Convert a binary file (image/PDF) to base64 for LLM consumption.
    # @return [Hash] { format:, mime_type:, size_bytes:, base64_data: }
    def self.file_to_base64(path)
      require "base64"
      ext  = File.extname(path).downcase
      size = File.size(path)

      raise ArgumentError, "File too large: #{path}" if size > MAX_FILE_BYTES

      mime = MIME_TYPES[ext] || "application/octet-stream"
      data = Base64.strict_encode64(File.binread(path))

      { format: ext[1..], mime_type: mime, size_bytes: size, base64_data: data }
    end

    # Detect MIME type from file extension (and optionally data bytes).
    def self.detect_mime_type(path, _data = nil)
      MIME_TYPES[File.extname(path).downcase] || "application/octet-stream"
    end

    # Convert a local image file path to a data: URL for vision APIs.
    # Used by CLI --image flag path → agent format_user_content.
    #
    # @param path [String] Local image file path
    # @return [String] "data:<mime>;base64,<encoded>"
    def self.image_path_to_data_url(path)
      raise ArgumentError, "Image file not found: #{path}" unless File.exist?(path)

      size = File.size(path)
      if size > MAX_IMAGE_BYTES
        raise ArgumentError, "Image too large (#{size / 1024 / 1024}MB > #{MAX_IMAGE_BYTES / 1024 / 1024}MB): #{path}"
      end

      require "base64"
      ext  = File.extname(path).downcase.delete(".")
      mime = case ext
             when "jpg", "jpeg" then "image/jpeg"
             when "png"         then "image/png"
             when "gif"         then "image/gif"
             when "webp"        then "image/webp"
             else "image/#{ext}"
             end

      "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
    end

    private_class_method :process_office, :process_zip, :process_binary,
                         :save_original, :save_preview, :sanitize_filename
  end
  end
end
