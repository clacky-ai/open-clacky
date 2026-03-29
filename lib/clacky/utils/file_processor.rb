# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "securerandom"
require "stringio"

require_relative "parser_manager"
require "zip"

module Clacky
  module Utils
  # File processing pipeline.
  #
  # Two entry points:
  #   FileProcessor.save(body:, filename:)
  #     → Store raw bytes to disk only. Returns { name:, path: }.
  #       Used by http_server and channel adapters — no parsing here.
  #
  #   FileProcessor.process_path(path, name: nil)
  #     → Parse an already-saved file. Returns FileRef (with preview_path or parse_error).
  #       Used by agent.run when building the file prompt.
  #
  # (FileProcessor.process = save + process_path in one call, for convenience.)
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

    GLOB_ALLOWED_BINARY_EXTENSIONS = %w[
      .pdf .doc .docx .ppt .pptx .xls .xlsx .odt .odp .ods
    ].freeze

    LLM_BINARY_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .pdf].freeze

    MIME_TYPES = {
      ".png"  => "image/png",
      ".jpg"  => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".gif"  => "image/gif",
      ".webp" => "image/webp",
      ".pdf"  => "application/pdf"
    }.freeze

    FILE_TYPES = {
      ".docx" => :document,  ".doc"  => :document,
      ".xlsx" => :spreadsheet, ".xls" => :spreadsheet,
      ".pptx" => :presentation, ".ppt" => :presentation,
      ".pdf"  => :pdf,
      ".zip"  => :zip, ".gz" => :zip, ".tar" => :zip, ".rar" => :zip, ".7z" => :zip,
      ".png"  => :image, ".jpg" => :image, ".jpeg" => :image,
      ".gif"  => :image, ".webp" => :image
    }.freeze

    # FileRef: result of process / process_path.
    FileRef = Struct.new(:name, :type, :original_path, :preview_path, :parse_error, :parser_path, keyword_init: true) do
      def parse_failed?
        preview_path.nil? && !parse_error.nil?
      end
    end

    # ---------------------------------------------------------------------------
    # Public API
    # ---------------------------------------------------------------------------

    # Store raw bytes to disk — no parsing.
    # Used by http_server upload endpoint and channel adapters.
    #
    # @return [Hash] { name: String, path: String }
    def self.save(body:, filename:)
      FileUtils.mkdir_p(UPLOAD_DIR)
      safe_name = sanitize_filename(filename)
      dest      = File.join(UPLOAD_DIR, "#{SecureRandom.hex(8)}_#{safe_name}")
      File.binwrite(dest, body)
      { name: safe_name, path: dest }
    end

    # Parse an already-saved file and return a FileRef.
    # Called by agent.run for each disk file before building the prompt.
    #
    # @param path [String] Path to the file on disk
    # @param name [String] Display name (defaults to basename)
    # @return [FileRef]
    def self.process_path(path, name: nil)
      name ||= File.basename(path.to_s)
      ext   = File.extname(path.to_s).downcase
      type  = FILE_TYPES[ext] || :file

      case ext
      when ".zip"
        body            = File.binread(path)
        preview_content = parse_zip_listing(body)
        preview_path    = save_preview(preview_content, path)
        FileRef.new(name: name, type: :zip, original_path: path, preview_path: preview_path)

      when ".png", ".jpg", ".jpeg", ".gif", ".webp"
        FileRef.new(name: name, type: :image, original_path: path)

      else
        result = Utils::ParserManager.parse(path)
        if result[:success]
          preview_path = save_preview(result[:text], path)
          FileRef.new(name: name, type: type, original_path: path, preview_path: preview_path)
        else
          FileRef.new(name: name, type: type, original_path: path,
                      parse_error: result[:error], parser_path: result[:parser_path])
        end
      end
    end

    # Save + parse in one call (convenience method).
    #
    # @return [FileRef]
    def self.process(body:, filename:)
      saved = save(body: body, filename: filename)
      process_path(saved[:path], name: saved[:name])
    end

    # Save raw image bytes to disk and return a FileRef.
    # Used by agent when an image exceeds MAX_IMAGE_BYTES and must be downgraded to disk.
    def self.save_image_to_disk(body:, mime_type:, filename: "image.jpg")
      FileUtils.mkdir_p(UPLOAD_DIR)
      safe_name = sanitize_filename(filename)
      dest      = File.join(UPLOAD_DIR, "#{SecureRandom.hex(8)}_#{safe_name}")
      File.binwrite(dest, body)
      FileRef.new(name: safe_name, type: :image, original_path: dest)
    end

    # ---------------------------------------------------------------------------
    # File type helpers (used by tools and agent)
    # ---------------------------------------------------------------------------

    def self.binary_file_path?(path)
      ext = File.extname(path).downcase
      return true if BINARY_EXTENSIONS.include?(ext)
      File.binread(path, 512).to_s.include?("\x00")
    rescue
      false
    end

    def self.glob_allowed_binary?(path)
      GLOB_ALLOWED_BINARY_EXTENSIONS.include?(File.extname(path).downcase)
    end

    def self.supported_binary_file?(path)
      LLM_BINARY_EXTENSIONS.include?(File.extname(path).downcase)
    end

    def self.detect_mime_type(path, _data = nil)
      MIME_TYPES[File.extname(path).downcase] || "application/octet-stream"
    end

    def self.file_to_base64(path)
      require "base64"
      ext  = File.extname(path).downcase
      size = File.size(path)
      raise ArgumentError, "File too large: #{path}" if size > MAX_FILE_BYTES
      mime = MIME_TYPES[ext] || "application/octet-stream"
      data = Base64.strict_encode64(File.binread(path))
      { format: ext[1..], mime_type: mime, size_bytes: size, base64_data: data }
    end

    def self.image_path_to_data_url(path)
      raise ArgumentError, "Image file not found: #{path}" unless File.exist?(path)
      size = File.size(path)
      if size > MAX_IMAGE_BYTES
        raise ArgumentError, "Image too large (#{size / 1024}KB > #{MAX_IMAGE_BYTES / 1024}KB): #{path}"
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

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

    def self.parse_zip_listing(body)
      lines = ["# ZIP Contents\n"]
      Zip::InputStream.open(StringIO.new(body)) do |zis|
        while (entry = zis.get_next_entry)
          size = entry.size ? " (#{entry.size} bytes)" : ""
          lines << "- #{entry.name}#{size}"
        end
      end
      lines.join("\n")
    rescue => e
      "# ZIP Contents\n(could not list entries: #{e.message})"
    end

    def self.save_preview(content, original_path)
      dest = "#{original_path}.preview.md"
      File.write(dest, content)
      dest
    end

    def self.sanitize_filename(name)
      # Keep Unicode letters/digits (including CJK), ASCII word chars, dots, hyphens, spaces.
      # Only strip characters that are unsafe on common filesystems: / \ : * ? " < > | \0
      # to_utf8 first: HTTP multipart headers arrive as ASCII-8BIT on Ruby 2.6,
      # and regex matching against ASCII-8BIT raises "invalid byte sequence in UTF-8".
      base = File.basename(Clacky::Utils::Encoding.to_utf8(name.to_s))
               .gsub(/[\/\\:\*?"<>|\x00]/, '_')
               .strip
      base.empty? ? 'upload' : base
    end

    private_class_method :parse_zip_listing, :save_preview, :sanitize_filename
  end
  end
end
