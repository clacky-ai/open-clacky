# frozen_string_literal: true

module Clacky
  module Utils
    # Centralised UTF-8 encoding helpers used throughout the codebase.
    #
    # Three distinct use-cases exist:
    #
    #   1. to_utf8       – binary/unknown bytes → valid UTF-8 String.
    #                      Used when reading shell output, HTTP response bodies,
    #                      or any raw byte stream that is *expected* to be UTF-8
    #                      but arrives with ASCII-8BIT (binary) encoding.
    #                      Strategy: force_encoding("UTF-8") then scrub invalid
    #                      sequences with U+FFFD so multibyte characters (CJK,
    #                      emoji, …) are preserved as-is.
    #
    #   2. sanitize_utf8 – UTF-8 String → clean UTF-8 String.
    #                      Used for UI rendering (terminal output, screen
    #                      buffers) where the string is already nominally UTF-8
    #                      but may still contain isolated invalid bytes.
    #                      Strategy: encode UTF-8→UTF-8 replacing invalid /
    #                      undefined codepoints with an empty string so the
    #                      rendered output never contains replacement characters.
    #
    #   3. safe_check    – any String → ASCII-safe UTF-8 String for regex.
    #                      Used only for security pattern matching (safe_shell).
    #                      Multibyte bytes are replaced with '?' so that Ruby's
    #                      regex engine operates on a plain ASCII-compatible
    #                      string without raising Encoding errors.
    #
    module Encoding
      # Convert a binary (or unknown-encoding) byte string to a valid UTF-8
      # String.  Multibyte sequences that are already valid UTF-8 (e.g. CJK
      # characters) are preserved unchanged; only genuinely invalid byte
      # sequences are replaced with U+FFFD (the Unicode replacement character).
      #
      # @param data [String, nil] raw bytes, typically from a pipe or HTTP body
      # @return [String] valid UTF-8 string
      def self.to_utf8(data)
        return "" if data.nil? || data.empty?

        data.dup.force_encoding("UTF-8").scrub("\u{FFFD}")
      end

      # Clean an already-UTF-8 string by removing (not replacing) any invalid
      # or undefined byte sequences.  Suitable for terminal / UI rendering where
      # replacement characters would appear as visual noise.
      #
      # @param str [String, nil] nominally UTF-8 string
      # @return [String] clean UTF-8 string (invalid bytes silently dropped)
      def self.sanitize_utf8(str)
        return "" if str.nil? || str.empty?

        str.encode("UTF-8", "UTF-8", invalid: :replace, undef: :replace, replace: "")
      end

      # Return an ASCII-safe UTF-8 copy of *str* suitable for security regex
      # pattern matching.  Any byte that is not valid in the source encoding, or
      # that cannot be represented in UTF-8, is replaced with '?'.  The
      # original string is never mutated.
      #
      # @param str [String, nil]
      # @return [String] UTF-8 string safe for regex matching
      def self.safe_check(str)
        return "" if str.nil? || str.empty?

        str.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
      end
    end
  end
end
