# frozen_string_literal: true

require "tempfile"
require "open3"

module Clacky
  module FileParser
    # Parses legacy .doc (OLE2/Word97) files into plain text.
    #
    # Strategy:
    #   1. textutil (macOS built-in) — best quality, preserves structure
    #   2. strings  (fallback)       — extracts printable bytes, lower quality
    #
    # Raises on failure so process_office can set preview_path: nil and let
    # the agent decide how to handle it.
    module DocParser
      MIN_CONTENT_BYTES = 20  # less than this → treat as empty/failed

      # Parse raw .doc bytes and return a plain-text string (as Markdown).
      # @param body [String] Raw file bytes
      # @return [String] Extracted text
      # @raise [RuntimeError] if no converter available or extraction fails
      def self.parse(body)
        Tempfile.create(["clacky_doc", ".doc"], binmode: true) do |f|
          f.write(body)
          f.flush

          text = try_textutil(f.path) || try_strings(f.path)
          raise "Could not extract text from .doc file — no supported converter available" unless text
          text
        end
      end

      # --- private ---

      # Use macOS textutil to convert .doc → txt
      def self.try_textutil(path)
        out_path = "#{path}.txt"
        stdout, stderr, status = Open3.capture3("textutil", "-convert", "txt", "-stdout", path)
        return nil unless status.success?

        text = stdout.strip
        return nil if text.bytesize < MIN_CONTENT_BYTES

        text
      rescue Errno::ENOENT
        nil  # textutil not available
      end

      # Fallback: strings command — extracts printable ASCII sequences
      def self.try_strings(path)
        stdout, _stderr, status = Open3.capture3("strings", path)
        return nil unless status.success?

        # Filter out junk: keep lines with at least 4 printable chars
        lines = stdout.lines.select { |l| l.strip.length >= 4 }
        return nil if lines.size < 3

        lines.join
      rescue Errno::ENOENT
        nil  # strings not available
      end

      private_class_method :try_textutil, :try_strings
    end
  end
end
