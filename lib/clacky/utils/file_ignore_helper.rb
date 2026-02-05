# frozen_string_literal: true

module Clacky
  module Utils
    # Helper module for file ignoring functionality shared between tools
    module FileIgnoreHelper
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

      # Config file patterns that should always be searchable/visible
      CONFIG_FILE_PATTERNS = [
        /\.env/,
        /\.ya?ml$/,
        /\.json$/,
        /\.toml$/,
        /\.ini$/,
        /\.conf$/,
        /\.config$/,
      ].freeze

      # Find .gitignore file in the search path or parent directories
      # Only searches within the search path and up to the current working directory
      def self.find_gitignore(path)
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
      def self.should_ignore_file?(file, base_path, gitignore)
        # Always calculate path relative to base_path for consistency
        # Expand both paths to handle symlinks and relative paths correctly
        expanded_file = File.expand_path(file)
        expanded_base = File.expand_path(base_path)

        # For files, use the directory as base
        expanded_base = File.dirname(expanded_base) if File.file?(expanded_base)

        # Calculate relative path
        if expanded_file.start_with?(expanded_base)
          relative_path = expanded_file[(expanded_base.length + 1)..-1] || File.basename(expanded_file)
        else
          # File is outside base path - use just the filename
          relative_path = File.basename(expanded_file)
        end

        # Clean up relative path
        relative_path = relative_path.sub(/^\.\//, '') if relative_path

        if gitignore
          # Use .gitignore rules
          gitignore.ignored?(relative_path)
        else
          # Use default ignore patterns - only match against relative path components
          DEFAULT_IGNORED_PATTERNS.any? do |pattern|
            if pattern.include?('*')
              File.fnmatch(pattern, relative_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
            else
              # Match pattern as a path component (not substring of absolute path)
              relative_path.start_with?("#{pattern}/") ||
              relative_path.include?("/#{pattern}/") ||
              relative_path == pattern ||
              File.basename(relative_path) == pattern
            end
          end
        end
      end

      # Check if file is a config file (should not be ignored even if in .gitignore)
      def self.is_config_file?(file)
        CONFIG_FILE_PATTERNS.any? { |pattern| file.match?(pattern) }
      end

    end
  end
end
