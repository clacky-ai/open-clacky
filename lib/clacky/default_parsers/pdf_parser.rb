#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Clacky PDF Parser — CLI interface
#
# Usage:
#   ruby pdf_parser.rb <file_path>
#
# Output:
#   stdout — extracted text content (UTF-8)
#   stderr — error messages
#   exit 0 — success
#   exit 1 — failure
#
# This file lives in ~/.clacky/parsers/ and can be modified by the LLM.
#
# Extraction pipeline (first successful step wins):
#   1. pdftotext (poppler)     — fastest, text-based PDFs
#   2. pdfplumber (Python)     — handles more layouts
#                                (→ pdf_parser_plumber.py)
#   3. OCR (tesseract)         — scanned / image-only PDFs
#                                (→ pdf_parser_ocr.py)
#
# Each extractor is a plain, self-contained function. Python-backed steps
# shell out to a sibling .py script so the LLM can edit them directly
# (with proper syntax highlighting, linters, and per-file run/debug)
# instead of wrestling with embedded heredocs.
#
# VERSION: 3

require "open3"

# Minimum useful output (in bytes). Below this, a step is considered a
# miss and the next fallback is tried.
MIN_CONTENT_BYTES = 20

# Script directory — resolve sibling .py helpers relative to this file
# so it works both from the gem's default_parsers/ dir and from the
# copied-to-user ~/.clacky/parsers/ dir.
SCRIPT_DIR = File.dirname(File.expand_path(__FILE__))

def try_pdftotext(path)
  stdout, _stderr, status = Open3.capture3("pdftotext", "-layout", "-enc", "UTF-8", path, "-")
  return nil unless status.success?
  text = stdout.strip
  return nil if text.bytesize < MIN_CONTENT_BYTES
  text
rescue Errno::ENOENT
  nil # pdftotext not installed
end

def try_pdfplumber(path)
  script = File.join(SCRIPT_DIR, "pdf_parser_plumber.py")
  return nil unless File.exist?(script)

  stdout, _stderr, status = Open3.capture3("python3", script, path)
  return nil unless status.success?
  text = stdout.strip
  return nil if text.bytesize < MIN_CONTENT_BYTES
  text
rescue Errno::ENOENT
  nil # python3 not available
end

# OCR fallback for scanned/image-only PDFs.
# See pdf_parser_ocr.py for the actual extraction logic.
#
# Installation hints (also printed on final failure):
#   macOS:   brew install tesseract tesseract-lang poppler
#            pip3 install pytesseract pdf2image
#   Linux:   apt install tesseract-ocr tesseract-ocr-chi-sim poppler-utils
#            pip3 install pytesseract pdf2image
def try_ocr(path)
  # Quick capability check — avoid spawning python if tesseract is missing.
  _stdout, _stderr, status = Open3.capture3("tesseract", "--version")
  return nil unless status.success?

  script = File.join(SCRIPT_DIR, "pdf_parser_ocr.py")
  return nil unless File.exist?(script)

  stdout, stderr, status = Open3.capture3("python3", script, path)
  unless status.success?
    warn stderr.strip unless stderr.strip.empty?
    return nil
  end
  text = stdout.strip
  return nil if text.bytesize < MIN_CONTENT_BYTES
  text
rescue Errno::ENOENT
  nil # tesseract or python3 not available
end

# --- main ---

path = ARGV[0]

if path.nil? || path.empty?
  warn "Usage: ruby pdf_parser.rb <file_path>"
  exit 1
end

unless File.exist?(path)
  warn "File not found: #{path}"
  exit 1
end

# Try each extractor in order; first non-nil result wins.
text = try_pdftotext(path) || try_pdfplumber(path) || try_ocr(path)

if text
  print text
  exit 0
else
  warn "Could not extract text from PDF."
  warn "For text-based PDFs, install poppler: brew install poppler (macOS) / apt install poppler-utils (Linux)"
  warn "For scanned PDFs (OCR):"
  warn "  macOS: brew install tesseract tesseract-lang poppler && pip3 install pytesseract pdf2image"
  warn "  Linux: apt install tesseract-ocr tesseract-ocr-chi-sim poppler-utils && pip3 install pytesseract pdf2image"
  exit 1
end
