# frozen_string_literal: true

require "pathname"

module Clacky
  module Tools
    class Glob < Base
      self.tool_name = "glob"
      self.tool_description = "Find files matching a glob pattern (e.g., '**/*.rb', 'src/**/*.js'). " \
                              "Returns file paths sorted by modification time."
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          pattern: {
            type: "string",
            description: "The glob pattern to match files (e.g., '**/*.rb', 'lib/**/*.rb', '*.txt')"
          },
          base_path: {
            type: "string",
            description: "The base directory to search in (defaults to current directory)",
            default: "."
          },
          limit: {
            type: "integer",
            description: "Maximum number of results to return (default: 100)",
            default: 100
          }
        },
        required: %w[pattern]
      }

      def execute(pattern:, base_path: ".", limit: 100)
        # Validate pattern
        if pattern.nil? || pattern.strip.empty?
          return { error: "Pattern cannot be empty" }
        end

        # Validate base_path
        unless Dir.exist?(base_path)
          return { error: "Base path does not exist: #{base_path}" }
        end

        begin
          # Change to base path and find matches
          full_pattern = File.join(base_path, pattern)
          matches = Dir.glob(full_pattern, File::FNM_DOTMATCH)
                       .reject { |path| File.directory?(path) }
                       .reject { |path| path.end_with?(".", "..") }

          # Sort by modification time (most recent first)
          matches = matches.sort_by { |path| -File.mtime(path).to_i }

          # Apply limit
          total_matches = matches.length
          matches = matches.take(limit)

          # Convert to relative or absolute paths
          matches = matches.map { |path| File.expand_path(path) }

          {
            matches: matches,
            total_matches: total_matches,
            returned: matches.length,
            truncated: total_matches > limit,
            error: nil
          }
        rescue StandardError => e
          { error: "Failed to glob files: #{e.message}" }
        end
      end
    end
  end
end
