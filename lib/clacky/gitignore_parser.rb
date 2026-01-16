# frozen_string_literal: true

module Clacky
  # Parser for .gitignore files to determine which files should be ignored
  class GitignoreParser
    attr_reader :patterns

    def initialize(gitignore_path = nil)
      @patterns = []
      @negation_patterns = []
      
      if gitignore_path && File.exist?(gitignore_path)
        parse_gitignore(gitignore_path)
      end
    end

    # Check if a file path should be ignored
    def ignored?(path)
      relative_path = path.start_with?('./') ? path[2..] : path
      
      # Check negation patterns first (! prefix in .gitignore)
      @negation_patterns.each do |pattern|
        return false if match_pattern?(relative_path, pattern)
      end
      
      # Then check ignore patterns
      @patterns.each do |pattern|
        return true if match_pattern?(relative_path, pattern)
      end
      
      false
    end

    private

    def parse_gitignore(path)
      File.readlines(path, chomp: true).each do |line|
        # Skip comments and empty lines
        next if line.strip.empty? || line.start_with?('#')
        
        # Handle negation patterns (lines starting with !)
        if line.start_with?('!')
          @negation_patterns << normalize_pattern(line[1..])
        else
          @patterns << normalize_pattern(line)
        end
      end
    rescue StandardError => e
      # If we can't parse .gitignore, just continue with empty patterns
      warn "Warning: Failed to parse .gitignore: #{e.message}"
    end

    def normalize_pattern(pattern)
      pattern = pattern.strip
      
      # Remove trailing whitespace
      pattern = pattern.rstrip
      
      # Store original for directory detection
      is_directory = pattern.end_with?('/')
      pattern = pattern.chomp('/')
      
      {
        pattern: pattern,
        is_directory: is_directory,
        is_absolute: pattern.start_with?('/'),
        has_wildcard: pattern.include?('*') || pattern.include?('?'),
        has_double_star: pattern.include?('**')
      }
    end

    def match_pattern?(path, pattern_info)
      pattern = pattern_info[:pattern]
      
      # Remove leading slash for absolute patterns
      pattern = pattern[1..] if pattern_info[:is_absolute]
      
      # Handle directory patterns
      if pattern_info[:is_directory]
        return false unless File.directory?(path)
      end
      
      # Handle different wildcard patterns
      if pattern_info[:has_double_star]
        # Convert ** to match any number of directories
        regex_pattern = pattern
          .gsub('**/', '(.*/)?')  # **/ matches zero or more directories
          .gsub('**', '.*')        # ** at end matches anything
          .gsub('*', '[^/]*')      # * matches anything except /
          .gsub('?', '[^/]')       # ? matches single character except /
        
        regex = Regexp.new("^#{regex_pattern}$")
        return true if path.match?(regex)
        return true if path.split('/').any? { |part| part.match?(regex) }
      elsif pattern_info[:has_wildcard]
        # Convert glob pattern to regex
        regex_pattern = pattern
          .gsub('*', '[^/]*')
          .gsub('?', '[^/]')
        
        regex = Regexp.new("^#{regex_pattern}$")
        return true if path.match?(regex)
        return true if File.basename(path).match?(regex)
      else
        # Exact match
        return true if path == pattern
        return true if path.start_with?("#{pattern}/")
        return true if File.basename(path) == pattern
      end
      
      false
    end
  end
end
