# frozen_string_literal: true

module Clacky
  module Tools
    class Grep < Base
      # Default patterns to ignore when .gitignore is not available
      DEFAULT_IGNORED_PATTERNS = [
        'node_modules',
        'vendor/bundle',
        '.git',
        '.svn',
        'tmp',
        'log',
        'coverage',
        'dist',
        'build',
        '.bundle',
        '.sass-cache',
        '.DS_Store',
        '*.log'
      ].freeze

      # Config file patterns that should always be searchable
      CONFIG_FILE_PATTERNS = [
        /\.env/,
        /\.ya?ml$/,
        /\.json$/,
        /\.toml$/,
        /\.ini$/,
        /\.conf$/,
        /\.config$/,
        /config\//,
        /\.config\//
      ].freeze

      # Maximum file size to search (1MB)
      MAX_FILE_SIZE = 1_048_576

      # Maximum line length to display (to avoid huge outputs)
      MAX_LINE_LENGTH = 500

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
            description: "Number of context lines to show before and after each match (max: 10)",
            default: 0
          },
          max_files: {
            type: "integer",
            description: "Maximum number of matching files to return",
            default: 50
          },
          max_matches_per_file: {
            type: "integer",
            description: "Maximum number of matches to return per file",
            default: 50
          },
          max_total_matches: {
            type: "integer",
            description: "Maximum total number of matches to return across all files",
            default: 200
          },
          max_file_size: {
            type: "integer",
            description: "Maximum file size in bytes to search (default: 1MB)",
            default: MAX_FILE_SIZE
          },
          max_files_to_search: {
            type: "integer",
            description: "Maximum number of files to search",
            default: 500
          }
        },
        required: %w[pattern]
      }

      def execute(
        pattern:,
        path: ".",
        file_pattern: "**/*",
        case_insensitive: false,
        context_lines: 0,
        max_files: 50,
        max_matches_per_file: 50,
        max_total_matches: 200,
        max_file_size: MAX_FILE_SIZE,
        max_files_to_search: 500
      )
        # Validate pattern
        if pattern.nil? || pattern.strip.empty?
          return { error: "Pattern cannot be empty" }
        end

        # Validate and expand path
        begin
          expanded_path = File.expand_path(path)
        rescue StandardError => e
          return { error: "Invalid path: #{e.message}" }
        end

        unless File.exist?(expanded_path)
          return { error: "Path does not exist: #{path}" }
        end

        # Limit context_lines
        context_lines = [[context_lines, 0].max, 10].min

        begin
          # Compile regex
          regex_options = case_insensitive ? Regexp::IGNORECASE : 0
          regex = Regexp.new(pattern, regex_options)

          # Initialize gitignore parser
          gitignore_path = find_gitignore(expanded_path)
          gitignore = gitignore_path ? Clacky::GitignoreParser.new(gitignore_path) : nil

          results = []
          total_matches = 0
          files_searched = 0
          skipped = {
            binary: 0,
            too_large: 0,
            ignored: 0
          }
          truncation_reason = nil

          # Get files to search
          files = if File.file?(expanded_path)
                    [expanded_path]
                  else
                    Dir.glob(File.join(expanded_path, file_pattern))
                       .select { |f| File.file?(f) }
                  end

          # Search each file
          files.each do |file|
            # Check if we've searched enough files
            if files_searched >= max_files_to_search
              truncation_reason ||= "max_files_to_search limit reached"
              break
            end

            # Skip if file should be ignored (unless it's a config file)
            if should_ignore_file?(file, expanded_path, gitignore) && !is_config_file?(file)
              skipped[:ignored] += 1
              next
            end

            # Skip binary files
            if binary_file?(file)
              skipped[:binary] += 1
              next
            end

            # Skip files that are too large
            if File.size(file) > max_file_size
              skipped[:too_large] += 1
              next
            end

            files_searched += 1

            # Check if we've found enough matching files
            if results.length >= max_files
              truncation_reason ||= "max_files limit reached"
              break
            end

            # Check if we've found enough total matches
            if total_matches >= max_total_matches
              truncation_reason ||= "max_total_matches limit reached"
              break
            end

            # Search the file
            matches = search_file(file, regex, context_lines, max_matches_per_file)
            next if matches.empty?

            # Add remaining matches respecting max_total_matches
            remaining_matches = max_total_matches - total_matches
            matches = matches.take(remaining_matches) if remaining_matches < matches.length

            results << {
              file: File.expand_path(file),
              matches: matches
            }
            total_matches += matches.length
          end

          {
            results: results,
            total_matches: total_matches,
            files_searched: files_searched,
            files_with_matches: results.length,
            skipped_files: skipped,
            truncated: !truncation_reason.nil?,
            truncation_reason: truncation_reason,
            error: nil
          }
        rescue RegexpError => e
          { error: "Invalid regex pattern: #{e.message}" }
        rescue StandardError => e
          { error: "Failed to search files: #{e.message}" }
        end
      end

      def format_call(args)
        pattern = args[:pattern] || args['pattern'] || ''
        path = args[:path] || args['path'] || '.'

        # Truncate pattern if too long
        display_pattern = pattern.length > 30 ? "#{pattern[0..27]}..." : pattern
        display_path = path == '.' ? 'current dir' : (path.length > 20 ? "...#{path[-17..]}" : path)

        "grep(\"#{display_pattern}\" in #{display_path})"
      end

      def format_result(result)
        if result[:error]
          "✗ #{result[:error]}"
        else
          matches = result[:total_matches] || 0
          files = result[:files_with_matches] || 0
          msg = "✓ Found #{matches} matches in #{files} files"
          
          # Add truncation info if present
          if result[:truncated] && result[:truncation_reason]
            msg += " (truncated: #{result[:truncation_reason]})"
          end
          
          msg
        end
      end

      private

      # Find .gitignore file in the search path or parent directories
      # Only searches within the search path and up to the current working directory
      def find_gitignore(path)
        search_path = File.directory?(path) ? path : File.dirname(path)
        
        # Look for .gitignore in current and parent directories
        current = File.expand_path(search_path)
        cwd = File.expand_path(Dir.pwd)
        root = File.expand_path('/')
        
        # Limit search: only go up to current working directory
        # This prevents finding .gitignore files from unrelated parent directories
        # when searching in temporary directories (like /tmp in tests)
        search_limit = if current.start_with?(cwd)
                        cwd
                      else
                        current
                      end
        
        loop do
          gitignore = File.join(current, '.gitignore')
          return gitignore if File.exist?(gitignore)
          
          # Stop if we've reached the search limit or root
          break if current == search_limit || current == root
          current = File.dirname(current)
        end
        
        nil
      end

      # Check if file should be ignored based on .gitignore or default patterns
      def should_ignore_file?(file, base_path, gitignore)
        # Calculate relative path
        if file.start_with?(base_path)
          relative_path = file[base_path.length + 1..] || file
        else
          relative_path = file
        end
        relative_path = relative_path.sub(/^\.\//, '') if relative_path
        relative_path ||= file
        
        if gitignore
          # Use .gitignore rules
          gitignore.ignored?(relative_path)
        else
          # Use default ignore patterns
          DEFAULT_IGNORED_PATTERNS.any? do |pattern|
            if pattern.include?('*')
              File.fnmatch(pattern, relative_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
            else
              relative_path.start_with?("#{pattern}/") || 
              relative_path.include?("/#{pattern}/") ||
              relative_path == pattern ||
              File.basename(relative_path) == pattern
            end
          end
        end
      end

      # Check if file is a config file (should not be ignored even if in .gitignore)
      def is_config_file?(file)
        CONFIG_FILE_PATTERNS.any? { |pattern| file.match?(pattern) }
      end

      def search_file(file, regex, context_lines, max_matches)
        matches = []
        
        # Use File.foreach for memory-efficient line-by-line reading
        File.foreach(file, chomp: true).with_index do |line, index|
          # Stop if we have enough matches for this file
          break if matches.length >= max_matches
          
          next unless line.match?(regex)

          # Truncate long lines
          display_line = line.length > MAX_LINE_LENGTH ? "#{line[0...MAX_LINE_LENGTH]}..." : line

          # Get context if requested
          if context_lines > 0
            context = get_line_context(file, index, context_lines)
          else
            context = nil
          end

          matches << {
            line_number: index + 1,
            line: display_line,
            context: context
          }
        end

        matches
      rescue StandardError
        []
      end

      # Get context lines around a match
      def get_line_context(file, match_index, context_lines)
        lines = File.readlines(file, chomp: true)
        start_line = [0, match_index - context_lines].max
        end_line = [lines.length - 1, match_index + context_lines].min

        context = []
        (start_line..end_line).each do |i|
          line_content = lines[i]
          # Truncate long lines in context too
          display_content = line_content.length > MAX_LINE_LENGTH ? 
                          "#{line_content[0...MAX_LINE_LENGTH]}..." : 
                          line_content
          
          context << {
            line_number: i + 1,
            content: display_content,
            is_match: i == match_index
          }
        end

        context
      rescue StandardError
        nil
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
