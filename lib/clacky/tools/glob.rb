# frozen_string_literal: true

require "pathname"

module Clacky
  module Tools
    class Glob < Base
      # Maximum file size to search (1MB)
      MAX_FILE_SIZE = 1_048_576

      self.tool_name = "glob"
      self.tool_description = "Find files matching a glob pattern (e.g., '**/*.rb', 'src/**/*.js'). " \
                              "Returns file paths sorted by modification time. Respects .gitignore patterns."
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
            description: "Maximum number of results to return (default: 10)",
            default: 10
          }
        },
        required: %w[pattern]
      }

      def execute(pattern:, base_path: ".", limit: 10, working_dir: nil)
        # Validate pattern
        if pattern.nil? || pattern.strip.empty?
          return { error: "Pattern cannot be empty" }
        end

        # Expand ~ to home directory in pattern and base_path
        pattern = expand_path(pattern)
        base_path = expand_path(base_path)

        # Validate base_path
        unless Dir.exist?(base_path)
          return { error: "Base path does not exist: #{base_path}" }
        end

        begin
          # Expand base path relative to working_dir when provided
          expanded_path = working_dir ? File.expand_path(base_path, working_dir) : File.expand_path(base_path)

          # Initialize gitignore parser
          gitignore_path = Clacky::Utils::FileIgnoreHelper.find_gitignore(expanded_path)
          gitignore = gitignore_path ? Clacky::GitignoreParser.new(gitignore_path) : nil

          # Track skipped files
          skipped = {
            binary: 0,
            too_large: 0,
            ignored: 0
          }

          # Auto-expand bare patterns (no slash, no **) to recursive search.
          # e.g. "*install*" -> "**/*install*", "*.rb" -> "**/*.rb"
          # This avoids surprising empty results when files are in subdirectories.
          effective_pattern = if !File.absolute_path?(pattern) &&
                                  !pattern.include?("/") &&
                                  !pattern.start_with?("**")
                                "**/#{pattern}"
                              else
                                pattern
                              end

          # Build full pattern - handle absolute paths correctly
          full_pattern = if File.absolute_path?(effective_pattern)
                          effective_pattern
                        else
                          File.join(base_path, effective_pattern)
                        end
          # Always-ignored directory names that should never appear in results
          always_ignored_dirs = Clacky::Utils::FileIgnoreHelper::ALWAYS_IGNORED_DIRS

          all_matches = Dir.glob(full_pattern, File::FNM_DOTMATCH)
                           .reject { |path| File.directory?(path) }
                           .reject { |path| path.end_with?(".", "..") }
                           .reject do |path|
                             # Fast path: reject files inside always-ignored dirs by path component
                             parts = path.split(File::SEPARATOR)
                             parts.any? { |part| always_ignored_dirs.include?(part) }
                           end

          # Filter out ignored, binary, and too large files
          matches = all_matches.select do |file|
            # Skip if file should be ignored (unless it's a config file)
            if Clacky::Utils::FileIgnoreHelper.should_ignore_file?(file, expanded_path, gitignore) && 
               !Clacky::Utils::FileIgnoreHelper.is_config_file?(file)
              skipped[:ignored] += 1
              next false
            end

            # Skip binary files
            if Clacky::Utils::FileProcessor.binary_file_path?(file)
              skipped[:binary] += 1
              next false
            end

            # Skip files that are too large
            if File.size(file) > MAX_FILE_SIZE
              skipped[:too_large] += 1
              next false
            end

            true
          end

          # Sort by modification time (most recent first)
          matches = matches.sort_by { |path| -File.mtime(path).to_i }

          # Apply limit
          total_matches = matches.length
          matches = matches.take(limit)

          # Convert to absolute paths
          matches = matches.map { |path| File.expand_path(path) }

          {
            matches: matches,
            total_matches: total_matches,
            returned: matches.length,
            truncated: total_matches > limit,
            skipped_files: skipped,
            error: nil
          }
        rescue StandardError => e
          { error: "Failed to glob files: #{e.message}" }
        end
      end

      def format_call(args)
        pattern = args[:pattern] || args['pattern'] || ''
        base_path = args[:base_path] || args['base_path'] || '.'
        
        display_base = base_path == '.' ? '' : " in #{base_path}"
        "glob(\"#{pattern}\"#{display_base})"
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error]}"
        else
          count = result[:returned] || 0
          total = result[:total_matches] || 0
          truncated = result[:truncated] ? " (truncated)" : ""
          
          msg = "[OK] Found #{count}/#{total} files#{truncated}"
          
          # Add skipped files info if present
          if result[:skipped_files]
            skipped = result[:skipped_files]
            skipped_parts = []
            skipped_parts << "#{skipped[:ignored]} ignored" if skipped[:ignored] > 0
            skipped_parts << "#{skipped[:binary]} binary" if skipped[:binary] > 0
            skipped_parts << "#{skipped[:too_large]} too large" if skipped[:too_large] > 0
            
            msg += " (skipped: #{skipped_parts.join(', ')})" unless skipped_parts.empty?
          end
          
          msg
        end
      end
    end
  end
end
