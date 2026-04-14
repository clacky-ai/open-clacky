#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Clacky DOC Parser — CLI interface
#
# Usage:
#   ruby doc_parser.rb <file_path>
#
# Output:
#   stdout — extracted text content (UTF-8)
#   stderr — error messages
#   exit 0 — success
#   exit 1 — failure
#
# This file lives in ~/.clacky/parsers/ and can be modified by the LLM
# to add new capabilities (e.g. antiword, libreoffice conversion).
#
# VERSION: 1

require "open3"

MIN_CONTENT_BYTES = 20

# Use macOS textutil to convert .doc → txt
def try_textutil(path)
  stdout, _stderr, status = Open3.capture3("textutil", "-convert", "txt", "-stdout", path)
  return nil unless status.success?
  text = stdout.strip
  return nil if text.bytesize < MIN_CONTENT_BYTES
  text
rescue Errno::ENOENT
  nil # textutil not available (non-macOS)
end

# Use antiword to extract text from .doc files (Linux/WSL)
def try_antiword(path)
  stdout, _stderr, status = Open3.capture3("antiword", path)
  return nil unless status.success?
  text = stdout.strip
  return nil if text.bytesize < MIN_CONTENT_BYTES
  text
rescue Errno::ENOENT
  nil # antiword not installed
end

# --- main ---

path = ARGV[0]

if path.nil? || path.empty?
  warn "Usage: ruby doc_parser.rb <file_path>"
  exit 1
end

unless File.exist?(path)
  warn "File not found: #{path}"
  exit 1
end

text = try_textutil(path) || try_antiword(path)

if text
  print text
  exit 0
else
  warn "Could not extract text from .doc file."
  warn "Tip: install antiword for best results:"
  warn "  macOS:      brew install antiword"
  warn "  Linux/WSL:  apt install antiword"
  exit 1
end
