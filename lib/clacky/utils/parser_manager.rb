# frozen_string_literal: true

require "fileutils"
require "open3"

module Clacky
  module Utils
    # Manages user-space parsers in ~/.clacky/parsers/.
    #
    # On first use, default parser scripts are copied from the gem's
    # default_parsers/ directory into ~/.clacky/parsers/. After that,
    # the user-space version is always used — allowing the LLM to modify
    # or extend parsers without touching the gem itself.
    #
    # CLI interface contract (all parsers must follow):
    #   ruby <parser>.rb <file_path>
    #   stdout → extracted text (UTF-8)
    #   stderr → error messages
    #   exit 0 → success
    #   exit 1 → failure
    module ParserManager
      PARSERS_DIR         = File.expand_path("~/.clacky/parsers").freeze
      DEFAULT_PARSERS_DIR = File.expand_path("../default_parsers", __dir__).freeze

      PARSER_FOR = {
        ".pdf"  => "pdf_parser.rb",
        ".doc"  => "doc_parser.rb",
        ".docx" => "docx_parser.rb",
        ".xlsx" => "xlsx_parser.rb",
        ".xls"  => "xlsx_parser.rb",
        ".pptx" => "pptx_parser.rb",
        ".ppt"  => "pptx_parser.rb",
      }.freeze

      # Ensure ~/.clacky/parsers/ exists and all default parsers are present.
      # Called once at startup.
      def self.setup!
        FileUtils.mkdir_p(PARSERS_DIR)

        PARSER_FOR.values.uniq.each do |script|
          dest = File.join(PARSERS_DIR, script)
          next if File.exist?(dest)

          src = File.join(DEFAULT_PARSERS_DIR, script)
          if File.exist?(src)
            FileUtils.cp(src, dest)
          end
        end
      end

      # Run the appropriate parser for the given file path.
      #
      # @param file_path [String] path to the file to parse
      # @return [Hash] { success: bool, text: String, error: String, parser_path: String }
      def self.parse(file_path)
        ext = File.extname(file_path.to_s).downcase
        script = PARSER_FOR[ext]

        unless script
          return { success: false, text: nil,
                   error: "No parser available for #{ext} files",
                   parser_path: nil }
        end

        parser_path = File.join(PARSERS_DIR, script)

        unless File.exist?(parser_path)
          return { success: false, text: nil,
                   error: "Parser not found: #{parser_path}",
                   parser_path: parser_path }
        end

        raw_stdout, raw_stderr, status = Open3.capture3(RbConfig.ruby, parser_path, file_path)

        # capture3 returns ASCII-8BIT across the subprocess boundary on Ruby 2.6+.
        # Normalise both streams to UTF-8 immediately so all downstream code is clean.
        stdout = Clacky::Utils::Encoding.to_utf8(raw_stdout)
        stderr = Clacky::Utils::Encoding.to_utf8(raw_stderr)

        # Filter out Ruby/Bundler version warnings that pollute stderr
        clean_stderr = stderr.lines.reject { |l| l.match?(/warning:|already initialized constant/) }.join.strip

        if status.success? && stdout.strip.length > 0
          { success: true, text: stdout.strip, error: nil, parser_path: parser_path }
        else
          { success: false, text: nil,
            error: clean_stderr.empty? ? "Parser exited with code #{status.exitstatus}" : clean_stderr,
            parser_path: parser_path }
        end
      end

      # Returns the path to a parser script for a given extension.
      # Used by agent to tell LLM where to find/modify the parser.
      def self.parser_path_for(ext)
        script = PARSER_FOR[ext.downcase]
        return nil unless script
        File.join(PARSERS_DIR, script)
      end
    end
  end
end
