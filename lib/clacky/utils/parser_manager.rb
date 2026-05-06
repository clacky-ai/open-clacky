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
      # Called at Agent startup (idempotent — safe to run every time).
      #
      # Copies every file from default_parsers/ (not just the entry-point .rb
      # scripts listed in PARSER_FOR). A parser may ship companion helper
      # scripts — e.g. pdf_parser_ocr.py sits next to pdf_parser.rb and is
      # invoked by relative path — so those helpers must be distributed too.
      #
      # Version upgrade policy:
      #   Each bundled parser declares `VERSION: <n>` in a header comment
      #   (works for Ruby `# VERSION: 2` and Python `# VERSION: 2` alike,
      #   scanned in the first 40 lines of the file).
      #
      #   On startup, per-file:
      #     - If the file does NOT exist in ~/.clacky/parsers/ → copy it.
      #     - If it exists:
      #         * bundled has no VERSION → never touch (bundled file
      #           is opting out of managed upgrades).
      #         * installed has no VERSION → treat it as legacy v0 and
      #           upgrade (lenient mode — covers users who installed before
      #           the VERSION scheme existed). The old file is backed up.
      #         * both have VERSION, bundled > installed → upgrade, backing
      #           up the old copy as `<script>.v<old>.bak`.
      #         * bundled ≤ installed → leave the user's copy alone
      #           (preserves LLM/user modifications).
      #
      #   Backups live alongside the parser so the user can inspect
      #   their own edits after an upgrade. They are never removed
      #   automatically.
      def self.setup!
        FileUtils.mkdir_p(PARSERS_DIR)

        Dir.glob(File.join(DEFAULT_PARSERS_DIR, "**", "*")).each do |src|
          next unless File.file?(src)
          basename = File.basename(src)
          next if basename.start_with?(".") || basename.end_with?(".bak")

          rel  = src.sub(/^#{Regexp.escape(DEFAULT_PARSERS_DIR)}\/?/, "")
          dest = File.join(PARSERS_DIR, rel)

          if !File.exist?(dest)
            FileUtils.mkdir_p(File.dirname(dest))
            FileUtils.cp(src, dest)
            # Preserve executable bit so sibling scripts can be run directly.
            FileUtils.chmod(File.stat(src).mode, dest)
            next
          end

          bundled_version = extract_version(src)
          # Bundled file opts out of managed upgrades — never touch user copy.
          next unless bundled_version

          installed_version = extract_version(dest) || 0

          if bundled_version > installed_version
            backup = "#{dest}.v#{installed_version}.bak"
            FileUtils.cp(dest, backup) unless File.exist?(backup)
            FileUtils.cp(src, dest)
            FileUtils.chmod(File.stat(src).mode, dest)
          end
        end
      end

      # Read the VERSION marker from a parser script (e.g. "# VERSION: 2").
      # Works for any script language that uses `#` for comments
      # (Ruby, Python, shell). Returns Integer or nil.
      def self.extract_version(path)
        return nil unless File.exist?(path)
        # Only scan the first 40 lines — the marker lives in the header.
        File.foreach(path).with_index do |line, i|
          break if i >= 40
          if (m = line.match(/^\s*#\s*VERSION:\s*(\d+)/i))
            return m[1].to_i
          end
        end
        nil
      rescue StandardError
        nil
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
