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
    MAX_IMAGE_BYTES = 5 * 1024 * 1024    # 5 MB

    # Alias used by FileReader tool
    MAX_FILE_SIZE = MAX_FILE_BYTES

    # Images wider than this will be downscaled before sending to LLM (pixels)
    IMAGE_MAX_WIDTH = 800
    # Hard limit for images that can't be resized: Anthropic/Bedrock vision API supports up to 5MB
    IMAGE_MAX_BASE64_BYTES = 5_000_000

    BINARY_EXTENSIONS = %w[
      .png .jpg .jpeg .gif .webp .bmp .tiff .ico .svg
      .pdf
      .zip .gz .tgz .tar .rar .7z
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
      ".zip"  => :zip, ".gz" => :zip, ".tgz" => :zip, ".tar" => :zip, ".rar" => :zip, ".7z" => :zip,
      ".png"  => :image, ".jpg" => :image, ".jpeg" => :image,
      ".gif"  => :image, ".webp" => :image,
      ".csv"  => :csv,
      ".md"   => :text, ".markdown" => :text, ".txt" => :text, ".log" => :text
    }.freeze

    # Plain-text extensions whose raw content can be embedded directly as the
    # preview (no external parser needed). Kept conservative to avoid pulling
    # in huge source files by mistake.
    TEXT_PREVIEW_EXTENSIONS = %w[.md .markdown .txt .log].freeze

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
      # Use compound extension for .tar.gz so it's treated as a tarball, not gzip.
      basename_lower = name.to_s.downcase
      ext =
        if basename_lower.end_with?(".tar.gz")
          ".tar.gz"
        else
          File.extname(path.to_s).downcase
        end
      type  = FILE_TYPES[ext] || :file

      case ext
      when ".zip"
        body            = File.binread(path)
        preview_content = parse_zip_listing(body)
        preview_path    = save_preview(preview_content, path)
        FileRef.new(name: name, type: :zip, original_path: path, preview_path: preview_path)

      when ".tar", ".tar.gz", ".tgz", ".gz"
        # Archive listing for tarballs and gzip'd files. Provides the LLM a
        # file-tree preview so it can decide whether to ask the user to
        # extract them (via the shell tool).
        begin
          preview_content = parse_tar_listing(path, ext)
          preview_path    = save_preview(preview_content, path)
          FileRef.new(name: name, type: :zip, original_path: path, preview_path: preview_path)
        rescue => e
          FileRef.new(name: name, type: :zip, original_path: path, parse_error: e.message)
        end

      when ".png", ".jpg", ".jpeg", ".gif", ".webp"
        FileRef.new(name: name, type: :image, original_path: path)

      when ".csv"
        # CSV is plain text — read directly, no external parser needed.
        # Try UTF-8 first, then GBK (common in Chinese-origin CSV), then binary with replacement.
        begin
          text         = read_text_with_encoding_fallback(path)
          preview_path = save_preview(text, path)
          FileRef.new(name: name, type: :csv, original_path: path, preview_path: preview_path)
        rescue => e
          FileRef.new(name: name, type: :csv, original_path: path, parse_error: e.message)
        end

      when *TEXT_PREVIEW_EXTENSIONS
        # Markdown / plain text: the file itself IS the preview.
        # No parser needed — just copy through (with encoding normalisation).
        begin
          text         = read_text_with_encoding_fallback(path)
          preview_path = save_preview(text, path)
          FileRef.new(name: name, type: :text, original_path: path, preview_path: preview_path)
        rescue => e
          FileRef.new(name: name, type: :text, original_path: path, parse_error: e.message)
        end

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

    # Downscale a base64-encoded image so its width is at most max_width pixels.
    #
    # Strategy:
    #   PNG  → chunky_png (pure Ruby, always available as gem dependency)
    #   other formats (JPG/WEBP/GIF) → sips on macOS, `convert` (ImageMagick) on Linux
    #   fallback (no CLI tool) → return as-is, but raise if larger than IMAGE_MAX_BASE64_BYTES
    #
    # @param b64       [String]  base64-encoded image data
    # @param mime_type [String]  e.g. "image/png", "image/jpeg", "image/webp"
    # @param max_width [Integer] maximum output width in pixels (default: IMAGE_MAX_WIDTH)
    # @return [String] base64-encoded (possibly downscaled) image data
    def self.downscale_image_base64(b64, mime_type, max_width: IMAGE_MAX_WIDTH)
      require "base64"

      result = if mime_type == "image/png"
                 downscale_png_chunky(b64, max_width)
               else
                 downscale_via_cli(b64, mime_type, max_width)
               end

      return result if result

      # No resize tool available — enforce API hard size limit (5MB)
      if b64.bytesize > IMAGE_MAX_BASE64_BYTES
        size_kb = b64.bytesize / 1024
        limit_mb = IMAGE_MAX_BASE64_BYTES / 1_000_000
        raise ArgumentError,
          "Image too large to send (#{size_kb}KB > #{limit_mb}MB). " \
          "Install ImageMagick (`brew install imagemagick`) to enable automatic resizing."
      end
      b64
    end

    def self.file_to_base64(path)
      require "base64"
      ext  = File.extname(path).downcase
      size = File.size(path)
      raise ArgumentError, "File too large: #{path}" if size > MAX_FILE_BYTES
      ext_mime = MIME_TYPES[ext] || "application/octet-stream"
      raw_data = File.binread(path)
      # Detect actual image format from magic bytes (ignore misleading extensions)
      mime = ext_mime.start_with?("image/") ? detect_image_mime_type(raw_data, ext_mime) : ext_mime
      data = Base64.strict_encode64(raw_data)
      # Downscale images before sending to LLM to reduce token cost
      data = downscale_image_base64(data, mime) if mime.start_with?("image/")
      { format: ext[1..], mime_type: mime, size_bytes: size, base64_data: data }
    end

    def self.image_path_to_data_url(path)
      raise ArgumentError, "Image file not found: #{path}" unless File.exist?(path)
      size = File.size(path)
      if size > MAX_IMAGE_BYTES
        raise ArgumentError, "Image too large (#{size / 1024}KB > #{MAX_IMAGE_BYTES / 1024}KB): #{path}"
      end
      require "base64"
      # Extension-based guess as fallback only
      ext  = File.extname(path).downcase.delete(".")
      ext_mime = case ext
                 when "jpg", "jpeg" then "image/jpeg"
                 when "png"         then "image/png"
                 when "gif"         then "image/gif"
                 when "webp"        then "image/webp"
                 else "image/#{ext}"
                 end
      raw_data = File.binread(path)
      # Detect actual image format from magic bytes (ignore misleading extensions)
      mime = detect_image_mime_type(raw_data, ext_mime)
      b64 = Base64.strict_encode64(raw_data)
      # Downscale images before sending to LLM to reduce token cost
      b64 = downscale_image_base64(b64, mime)
      "data:#{mime};base64,#{b64}"
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

    # List entries in a tarball or gzip file.
    #
    # Handles:
    #   .tar        → raw tar reader
    #   .tar.gz/.tgz → gunzip stream + tar reader
    #   .gz         → single gzipped file → show original filename + uncompressed size
    def self.parse_tar_listing(path, ext)
      require "rubygems/package"
      require "zlib"

      case ext
      when ".tar"
        lines = ["# TAR Contents\n"]
        File.open(path, "rb") do |file|
          Gem::Package::TarReader.new(file) do |tar|
            tar.each do |entry|
              kind = entry.directory? ? "[dir] " : ""
              size = entry.header.size ? " (#{entry.header.size} bytes)" : ""
              lines << "- #{kind}#{entry.full_name}#{size}"
            end
          end
        end
        lines.join("\n")

      when ".tar.gz", ".tgz"
        lines = ["# TAR.GZ Contents\n"]
        File.open(path, "rb") do |file|
          Zlib::GzipReader.wrap(file) do |gz|
            Gem::Package::TarReader.new(gz) do |tar|
              tar.each do |entry|
                kind = entry.directory? ? "[dir] " : ""
                size = entry.header.size ? " (#{entry.header.size} bytes)" : ""
                lines << "- #{kind}#{entry.full_name}#{size}"
              end
            end
          end
        end
        lines.join("\n")

      when ".gz"
        # Could be gzipped-tar with a misleading extension, or a single-file gzip.
        # Try tar first; on failure, fall back to single-file metadata.
        begin
          lines = ["# TAR.GZ Contents\n"]
          found_tar = false
          File.open(path, "rb") do |file|
            Zlib::GzipReader.wrap(file) do |gz|
              Gem::Package::TarReader.new(gz) do |tar|
                tar.each do |entry|
                  found_tar = true
                  kind = entry.directory? ? "[dir] " : ""
                  size = entry.header.size ? " (#{entry.header.size} bytes)" : ""
                  lines << "- #{kind}#{entry.full_name}#{size}"
                end
              end
            end
          end
          return lines.join("\n") if found_tar
        rescue StandardError
          # fall through to single-file gzip handling
        end

        # Single-file gzip: report the original filename (if recorded) and compressed/uncompressed sizes.
        original_name = nil
        uncompressed  = nil
        File.open(path, "rb") do |file|
          Zlib::GzipReader.wrap(file) do |gz|
            original_name = gz.orig_name
            # Read fully to get the uncompressed size. Guarded: stop after 64MB
            # to avoid blowing memory on pathological inputs — the preview only
            # needs a size estimate, not the content.
            limit   = 64 * 1024 * 1024
            total   = 0
            while (chunk = gz.read(1024 * 1024))
              total += chunk.bytesize
              break if total > limit
            end
            uncompressed = total
          end
        end
        lines = ["# GZIP Contents\n"]
        lines << "- Original filename: #{original_name || "(not recorded)"}"
        lines << "- Compressed size:   #{File.size(path)} bytes"
        lines << "- Uncompressed size: #{uncompressed} bytes#{uncompressed && uncompressed > 64 * 1024 * 1024 ? " (truncated)" : ""}"
        lines.join("\n")
      end
    rescue => e
      "# Archive Contents\n(could not list entries: #{e.message})"
    end

    def self.save_preview(content, original_path)
      # Always write previews to a tmpdir-based path to avoid polluting the
      # user's working directory with .preview.md sidecar files.
      # Use the same UPLOAD_DIR that uploaded files live in; for on-disk files
      # outside that dir (e.g. project files opened by file_reader), we still
      # land in UPLOAD_DIR so the user's tree stays clean.
      FileUtils.mkdir_p(UPLOAD_DIR)
      safe_name = File.basename(original_path.to_s).gsub(/[\/\:\*?"<>|\x00]/, "_")
      dest = File.join(UPLOAD_DIR, "#{SecureRandom.hex(8)}_#{safe_name}.preview.md")
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

    # Read a text file with automatic encoding detection.
    # Tries UTF-8, then GBK (common for Chinese-origin CSV/text files), then
    # falls back to binary read with invalid byte replacement.
    def self.read_text_with_encoding_fallback(path)
      # Try UTF-8 first (most common, fastest path)
      raw = File.binread(path)
      utf8 = raw.dup.force_encoding("UTF-8")
      return utf8.encode("UTF-8") if utf8.valid_encoding?

      # Try GBK (GB2312 superset — common in Chinese Windows/Excel exports)
      begin
        return raw.encode("UTF-8", "GBK", invalid: :replace, undef: :replace, replace: "?")
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        # fall through
      end

      # Last resort: binary read with replacement characters
      raw.encode("UTF-8", "binary", invalid: :replace, undef: :replace, replace: "?")
    end

    # Detect the actual image MIME type from raw binary data by inspecting
    # magic bytes, ignoring the file extension. Falls back to extension-based
    # detection when magic bytes don't match any known format.
    #
    # Handles: PNG, JPEG, GIF, WEBP, BMP, TIFF
    #
    # @param data [String] raw binary data (first 12 bytes is sufficient)
    # @param fallback_mime [String] MIME type from extension, used as fallback
    # @return [String] detected MIME type (e.g. "image/png", "image/jpeg")
    def self.detect_image_mime_type(data, fallback_mime = "image/png")
      return fallback_mime if data.nil? || data.bytesize < 4

      bytes = data.bytes

      case
      # PNG: \x89 P N G \r \n \x1a \n
      when bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
        "image/png"
      # JPEG: \xFF \xD8 \xFF
      when bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
        "image/jpeg"
      # GIF: GIF87a or GIF89a
      when bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38
        "image/gif"
      # WEBP: RIFF .... WEBP
      when bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
           data.bytesize >= 12 && data[8, 4] == "WEBP"
        "image/webp"
      # BMP: BM
      when bytes[0] == 0x42 && bytes[1] == 0x4D
        "image/bmp"
      # TIFF: II*\x00 (little-endian) or MM\x00* (big-endian)
      when (bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00) ||
           (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)
        "image/tiff"
      else
        fallback_mime
      end
    end

    # ---------------------------------------------------------------------------
    # Image downscale helpers (private)
    # ---------------------------------------------------------------------------

    # Downscale a PNG using chunky_png (pure Ruby — always available).
    # Returns downscaled base64, or original base64 if already within max_width.
    def self.downscale_png_chunky(b64, max_width)
      require "chunky_png"
      require "base64"
      image = ChunkyPNG::Image.from_blob(Base64.strict_decode64(b64))
      return b64 if image.width <= max_width

      src_w, src_h = image.width, image.height
      dst_h = (src_h * max_width.to_f / src_w).round
      image.resample_nearest_neighbor!(max_width, dst_h)
      before_kb = b64.bytesize / 1024
      result    = Base64.strict_encode64(image.to_blob)
      after_kb  = result.bytesize / 1024
      Clacky::Logger.debug("image_downscaled",
        format: "png",
        from: "#{src_w}x#{src_h} (#{before_kb}KB)",
        to:   "#{max_width}x#{dst_h} (#{after_kb}KB)")
      result
    rescue => e
      Clacky::Logger.debug("image_downscale_skipped", format: "png", reason: e.message)
      nil
    end

    # Downscale a non-PNG image using CLI tools:
    #   macOS → sips (built-in, no extra deps)
    #   Linux → convert (ImageMagick, must be installed)
    # Returns downscaled base64, or nil if no tool is available.
    def self.downscale_via_cli(b64, mime_type, max_width)
      require "base64"
      require "tmpdir"

      ext = mime_type.split("/").last
      ext = "jpg" if ext == "jpeg"

      # Write input to a temp file
      Dir.mktmpdir("clacky-img") do |dir|
        input  = File.join(dir, "input.#{ext}")
        output = File.join(dir, "output.#{ext}")
        File.binwrite(input, Base64.strict_decode64(b64))

        before_kb = b64.bytesize / 1024
        success = false

        if RUBY_PLATFORM.include?("darwin")
          # macOS: sips is always available
          success = system("sips", "-Z", max_width.to_s, input, "--out", output,
                           out: File::NULL, err: File::NULL)
        else
          # Linux/other: try ImageMagick convert
          if system("which convert > /dev/null 2>&1")
            success = system("convert", input, "-resize", "#{max_width}x>",
                             output, out: File::NULL, err: File::NULL)
          end
        end

        return nil unless success && File.exist?(output) && File.size(output) > 0

        result    = Base64.strict_encode64(File.binread(output))
        after_kb  = result.bytesize / 1024
        Clacky::Logger.debug("image_downscaled",
          format: ext,
          from: "#{before_kb}KB",
          to:   "#{after_kb}KB (max #{max_width}px wide)")
        result
      end
    rescue => e
      Clacky::Logger.debug("image_downscale_skipped", mime: mime_type, reason: e.message)
      nil
    end

    private_class_method :parse_zip_listing, :parse_tar_listing, :save_preview, :sanitize_filename,
                         :read_text_with_encoding_fallback,
                         :downscale_png_chunky, :downscale_via_cli
  end
  end
end
