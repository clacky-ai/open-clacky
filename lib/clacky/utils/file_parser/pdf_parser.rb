# frozen_string_literal: true

require "tempfile"
require "open3"

module Clacky
  module FileParser
    # Parses PDF files into plain text (Markdown-friendly).
    #
    # Strategy:
    #   1. pdftotext (poppler) — fastest, best layout preservation
    #   2. pdfplumber (Python)  — fallback, good for complex layouts
    #
    # Raises on failure so process_office sets preview_path: nil and lets
    # the agent fall back to its own tools if needed.
    module PdfParser
      MIN_CONTENT_BYTES = 20

      # @param body [String] Raw PDF bytes
      # @return [String] Extracted text
      # @raise [RuntimeError] if no converter available or extraction fails
      def self.parse(body)
        Tempfile.create(["clacky_pdf", ".pdf"], binmode: true) do |f|
          f.write(body)
          f.flush

          text = try_pdftotext(f.path) || try_pdfplumber(f.path)
          raise "Could not extract text from PDF — try installing poppler (brew install poppler)" unless text
          text
        end
      end

      # --- private ---

      def self.try_pdftotext(path)
        stdout, _stderr, status = Open3.capture3("pdftotext", "-layout", "-enc", "UTF-8", path, "-")
        return nil unless status.success?

        text = stdout.strip
        return nil if text.bytesize < MIN_CONTENT_BYTES
        text
      rescue Errno::ENOENT
        nil  # pdftotext not installed
      end

      def self.try_pdfplumber(path)
        script = <<~PYTHON
          import sys, pdfplumber
          with pdfplumber.open(sys.argv[1]) as pdf:
              pages = []
              for i, page in enumerate(pdf.pages, 1):
                  t = page.extract_text()
                  if t and t.strip():
                      pages.append(f"--- Page {i} ---\\n{t.strip()}")
              print("\\n\\n".join(pages))
        PYTHON

        stdout, _stderr, status = Open3.capture3("python3", "-c", script, path)
        return nil unless status.success?

        text = stdout.strip
        return nil if text.bytesize < MIN_CONTENT_BYTES
        text
      rescue Errno::ENOENT
        nil  # python3 not available
      end

      private_class_method :try_pdftotext, :try_pdfplumber
    end
  end
end
