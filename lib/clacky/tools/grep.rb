# frozen_string_literal: true

module Clacky
  module Tools
    class Grep < Base
      self.tool_name = "grep"
      self.tool_description = "Search file contents using regular expressions. Returns matching lines with context."
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          pattern: {
            type: "string",
            description: "The regular expression pattern to search for"
          },
          path: {
            type: "string",
            description: "File or directory to search in (defaults to current directory)",
            default: "."
          },
          file_pattern: {
            type: "string",
            description: "Glob pattern to filter files (e.g., '*.rb', '**/*.js')",
            default: "**/*"
          },
          case_insensitive: {
            type: "boolean",
            description: "Perform case-insensitive search",
            default: false
          },
          context_lines: {
            type: "integer",
            description: "Number of context lines to show before and after each match",
            default: 0
          },
          max_matches: {
            type: "integer",
            description: "Maximum number of matching files to return",
            default: 50
          }
        },
        required: %w[pattern]
      }

      def execute(pattern:, path: ".", file_pattern: "**/*", case_insensitive: false, context_lines: 0, max_matches: 50)
        # Validate pattern
        if pattern.nil? || pattern.strip.empty?
          return { error: "Pattern cannot be empty" }
        end

        # Validate path
        unless File.exist?(path)
          return { error: "Path does not exist: #{path}" }
        end

        begin
          # Compile regex
          regex_options = case_insensitive ? Regexp::IGNORECASE : 0
          regex = Regexp.new(pattern, regex_options)

          results = []
          total_matches = 0

          # Get files to search
          files = if File.file?(path)
                    [path]
                  else
                    Dir.glob(File.join(path, file_pattern))
                       .select { |f| File.file?(f) }
                       .reject { |f| binary_file?(f) }
                  end

          # Search each file
          files.each do |file|
            break if results.length >= max_matches

            matches = search_file(file, regex, context_lines)
            next if matches.empty?

            results << {
              file: File.expand_path(file),
              matches: matches
            }
            total_matches += matches.length
          end

          {
            results: results,
            total_matches: total_matches,
            files_searched: files.length,
            files_with_matches: results.length,
            truncated: results.length >= max_matches,
            error: nil
          }
        rescue RegexpError => e
          { error: "Invalid regex pattern: #{e.message}" }
        rescue StandardError => e
          { error: "Failed to search files: #{e.message}" }
        end
      end

      private

      def search_file(file, regex, context_lines)
        matches = []
        lines = File.readlines(file, chomp: true)

        lines.each_with_index do |line, index|
          next unless line.match?(regex)

          # Get context
          start_line = [0, index - context_lines].max
          end_line = [lines.length - 1, index + context_lines].min

          context = []
          (start_line..end_line).each do |i|
            context << {
              line_number: i + 1,
              content: lines[i],
              is_match: i == index
            }
          end

          matches << {
            line_number: index + 1,
            line: line,
            context: context_lines > 0 ? context : nil
          }
        end

        matches
      rescue StandardError
        []
      end

      def binary_file?(file)
        # Simple heuristic: check if file contains null bytes in first 8KB
        return false unless File.exist?(file)
        return false if File.size(file).zero?

        sample = File.read(file, 8192, encoding: "ASCII-8BIT")
        sample.include?("\x00")
      rescue StandardError
        true
      end
    end
  end
end
