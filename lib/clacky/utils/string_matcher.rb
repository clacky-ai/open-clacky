# frozen_string_literal: true

module Clacky
  module Utils
    # Utilities for finding and matching strings in file content.
    # Used by the Edit tool and edit preview to apply a consistent
    # layered matching strategy: exact → trim → unescape → smart line match.
    module StringMatcher
      # Find a matching string in content using a layered strategy.
      #
      # Strategy (applied in order):
      #   1. Exact match (original old_string)
      #   2. Trimmed match (leading/trailing whitespace stripped)
      #   3. Unescaped match (over-escaped sequences normalised)
      #   4. Combined trim + unescape
      #   5. Smart line-by-line match (tolerates indent differences)
      #
      # @param content [String] File content to search in
      # @param old_string [String] String to locate
      # @return [Hash, nil] { matched_string: String, occurrences: Integer }
      #   or nil when nothing matches
      def self.find_match(content, old_string)
        # Defensive: if either side contains invalid UTF-8 bytes (binary files,
        # mixed-encoding content, etc.), Regexp#scan / String#include? with a
        # UTF-8-tagged candidate can raise `ArgumentError: invalid byte sequence
        # in UTF-8`. Scrub once at the entry point so every matching layer —
        # including callers like the edit preview — is safe.
        content    = Clacky::Utils::Encoding.to_utf8(content)    unless content.nil?
        old_string = Clacky::Utils::Encoding.to_utf8(old_string) unless old_string.nil?

        candidates = generate_candidates(old_string)

        # Simple string matching for each candidate
        candidates.each do |candidate|
          next if candidate.empty?

          if content.include?(candidate)
            return {
              matched_string: candidate,
              occurrences: count_occurrences(content, candidate)
            }
          end
        end

        # Fall back to smart line-by-line matching (tabs vs spaces, etc.)
        try_smart_match(content, old_string)
      end

      # Count non-overlapping occurrences of `needle` in `haystack` without
      # going through Regexp (safer on mixed-encoding strings and avoids an
      # extra escape step).
      def self.count_occurrences(haystack, needle)
        return 0 if needle.empty?
        count = 0
        offset = 0
        while (idx = haystack.index(needle, offset))
          count += 1
          offset = idx + needle.length
        end
        count
      end

      # Generate candidate strings by applying different transformations.
      #
      # @param old_string [String]
      # @return [Array<String>] Unique list of candidates
      def self.generate_candidates(old_string)
        trimmed           = old_string.strip
        unescaped         = unescape_over_escaped(old_string)
        unescaped_trimmed = unescape_over_escaped(trimmed)

        [
          old_string,        # Original
          trimmed,           # Trim leading/trailing whitespace
          unescaped,         # Unescape over-escaped sequences
          unescaped_trimmed  # Combined: trim + unescape
        ].uniq
      end

      # Convert over-escaped sequences back to their real characters.
      # This handles the common case where LLMs double-escape backslashes.
      #
      # @param str [String]
      # @return [String]
      def self.unescape_over_escaped(str)
        result = str.dup

        # Unicode escapes: \uXXXX → actual Unicode character
        result = result.gsub(/\\u([0-9a-fA-F]{4})/) { [$1.hex].pack("U") }

        # Common escape sequences
        result = result.gsub('\\n',  "\n")
        result = result.gsub('\\t',  "\t")
        result = result.gsub('\\r',  "\r")
        result = result.gsub('\\f',  "\f")
        result = result.gsub('\\b',  "\b")
        result = result.gsub('\\v',  "\v")
        result = result.gsub('\\"',  '"')
        result = result.gsub('\\\\', "\\")

        result
      end

      # Try smart line-by-line matching that tolerates leading whitespace differences.
      #
      # @param content [String]
      # @param old_string [String]
      # @return [Hash, nil]
      def self.try_smart_match(content, old_string)
        candidates = generate_candidates(old_string)

        candidates.each do |candidate|
          next if candidate.empty?

          candidate_lines = candidate.lines
          next if candidate_lines.empty?

          content_lines = content.lines
          matches = []

          (0..content_lines.length - candidate_lines.length).each do |start_idx|
            slice = content_lines[start_idx, candidate_lines.length]
            next unless slice

            if lines_match_normalized?(slice, candidate_lines)
              matches << { start: start_idx, matched_string: slice.join }
            end
          end

          unless matches.empty?
            return {
              matched_string: matches.first[:matched_string],
              occurrences: matches.length
            }
          end
        end

        nil
      end

      # Compare two arrays of lines after normalising leading whitespace.
      #
      # @param lines1 [Array<String>]
      # @param lines2 [Array<String>]
      # @return [Boolean]
      def self.lines_match_normalized?(lines1, lines2)
        return false unless lines1.length == lines2.length

        lines1.zip(lines2).all? do |line1, line2|
          norm1 = line1.sub(/^\s+/, " ").chomp
          norm2 = line2.sub(/^\s+/, " ").chomp

          norm1 == norm2 || norm1 == unescape_over_escaped(norm2)
        end
      end
    end
  end
end
