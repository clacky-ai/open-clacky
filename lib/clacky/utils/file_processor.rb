# frozen_string_literal: true

require "base64"

module Clacky
  module Utils
    # File processing utilities for binary files, images, and PDFs
    class FileProcessor
      # Maximum file size for binary files (5MB)
      MAX_FILE_SIZE = 5 * 1024 * 1024

      # Supported image formats
      IMAGE_FORMATS = {
        "png" => "image/png",
        "jpg" => "image/jpeg",
        "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp"
      }.freeze

      # Supported document formats
      DOCUMENT_FORMATS = {
        "pdf" => "application/pdf"
      }.freeze

      # All supported formats
      SUPPORTED_FORMATS = IMAGE_FORMATS.merge(DOCUMENT_FORMATS).freeze

      # File signatures (magic bytes) for format detection
      FILE_SIGNATURES = {
        "\x89PNG\r\n\x1a\n".b => "png",
        "\xFF\xD8\xFF".b => "jpg",
        "GIF87a".b => "gif",
        "GIF89a".b => "gif",
        "%PDF".b => "pdf"
      }.freeze

      class << self
        # Convert image file path to base64 data URL
        # @param path [String] File path to image
        # @return [String] base64 data URL (e.g., "data:image/png;base64,...")
        # @raise [ArgumentError] If file not found or unsupported format
        def image_path_to_data_url(path)
          unless File.exist?(path)
            raise ArgumentError, "Image file not found: #{path}"
          end

          # Check file size
          file_size = File.size(path)
          if file_size > MAX_FILE_SIZE
            raise ArgumentError, "File too large: #{file_size} bytes (max: #{MAX_FILE_SIZE} bytes)"
          end

          # Read file as binary
          image_data = File.binread(path)

          # Detect MIME type from file extension or content
          mime_type = detect_mime_type(path, image_data)

          # Verify it's an image format
          unless IMAGE_FORMATS.values.include?(mime_type)
            raise ArgumentError, "Unsupported image format: #{mime_type}"
          end

          # Encode to base64
          base64_data = Base64.strict_encode64(image_data)

          "data:#{mime_type};base64,#{base64_data}"
        end

        # Convert file to base64 with format detection
        # @param path [String] File path
        # @return [Hash] Hash with :format, :mime_type, :base64_data, :size_bytes
        # @raise [ArgumentError] If file not found or too large
        def file_to_base64(path)
          unless File.exist?(path)
            raise ArgumentError, "File not found: #{path}"
          end

          # Check file size
          file_size = File.size(path)
          if file_size > MAX_FILE_SIZE
            raise ArgumentError, "File too large: #{file_size} bytes (max: #{MAX_FILE_SIZE} bytes)"
          end

          # Read file as binary
          file_data = File.binread(path)

          # Detect format and MIME type
          format = detect_format(path, file_data)
          mime_type = detect_mime_type(path, file_data)

          # Encode to base64
          base64_data = Base64.strict_encode64(file_data)

          {
            format: format,
            mime_type: mime_type,
            base64_data: base64_data,
            size_bytes: file_size
          }
        end

        # Detect file format from path and content
        # @param path [String] File path
        # @param data [String] Binary file data
        # @return [String] Format (e.g., "png", "jpg", "pdf")
        def detect_format(path, data)
          # Try to detect from file extension first
          ext = File.extname(path).downcase.delete_prefix(".")
          return ext if SUPPORTED_FORMATS.key?(ext)

          # Try to detect from file signature (magic bytes)
          FILE_SIGNATURES.each do |signature, format|
            return format if data.start_with?(signature)
          end

          # Special case for WebP (RIFF format)
          if data.start_with?("RIFF".b) && data[8..11] == "WEBP".b
            return "webp"
          end

          nil
        end

        # Detect MIME type from file path and content
        # @param path [String] File path
        # @param data [String] Binary file data
        # @return [String] MIME type (e.g., "image/png")
        def detect_mime_type(path, data)
          format = detect_format(path, data)
          return SUPPORTED_FORMATS[format] if format && SUPPORTED_FORMATS[format]

          # Default to application/octet-stream for unknown formats
          "application/octet-stream"
        end

        # Check if file is a supported binary format
        # @param path [String] File path
        # @return [Boolean] True if supported binary format
        def supported_binary_file?(path)
          return false unless File.exist?(path)

          ext = File.extname(path).downcase.delete_prefix(".")
          SUPPORTED_FORMATS.key?(ext)
        end

        # Check if file is an image
        # @param path [String] File path
        # @return [Boolean] True if image format
        def image_file?(path)
          return false unless File.exist?(path)

          ext = File.extname(path).downcase.delete_prefix(".")
          IMAGE_FORMATS.key?(ext)
        end

        # Check if file is a PDF
        # @param path [String] File path
        # @return [Boolean] True if PDF format
        def pdf_file?(path)
          return false unless File.exist?(path)

          ext = File.extname(path).downcase.delete_prefix(".")
          ext == "pdf"
        end

        # Check if file is binary (not text)
        # @param data [String] File content
        # @param sample_size [Integer] Number of bytes to check (default: 8192)
        # @return [Boolean] True if file appears to be binary
        def binary_file?(data, sample_size: 8192, min_binary_length: 512)
          # Check first N bytes for binary content
          sample = data[0, sample_size] || ""
          return false if sample.empty?

          # Check for known binary signatures first
          FILE_SIGNATURES.each do |signature, _format|
            return true if sample.start_with?(signature)
          end

          # Check for WebP (RIFF format)
          if sample.start_with?("RIFF".b) && sample.length >= 12 && sample[8..11] == "WEBP".b
            return true
          end

          # Only check non-printable ratio for samples above minimum length
          # This prevents short outputs from being incorrectly flagged as binary
          return false if sample.size < min_binary_length

          # Count non-printable characters (excluding common whitespace)
          non_printable = sample.bytes.count do |byte|
            byte < 32 && ![9, 10, 13].include?(byte) || byte >= 127
          end

          # If more than 30% non-printable, consider it binary
          (non_printable.to_f / sample.size) > 0.3
        end

        # Check if a file at the given path is binary (not text)
        # @param path [String] File path
        # @return [Boolean] True if file appears to be binary
        def binary_file_path?(path)
          return false unless File.exist?(path)

          File.open(path, "rb") do |file|
            sample = file.read(8192) || ""
            binary_file?(sample)
          end
        rescue StandardError
          # If we can't read the file, assume it's not binary
          false
        end
      end
    end
  end
end
