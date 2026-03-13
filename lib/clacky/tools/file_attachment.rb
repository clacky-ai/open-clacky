# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "securerandom"
require "zip"
require "rexml/document"

module Clacky
  module Tools
    module FileAttachment
      UPLOAD_DIR      = File.join(Dir.tmpdir, "clacky-uploads").freeze
      MAX_FILE_BYTES  = 32 * 1024 * 1024  # 32MB, matches web frontend limit
      MAX_IMAGE_BYTES =  5 * 1024 * 1024  # 5MB, matches web frontend limit

      # Save file to temp dir and return a path-reference string for the agent.
      # docx/xlsx are extracted to plain text so the agent can Read them directly.
      # @param body [String] Raw file bytes
      # @param file_name [String] Original filename (for extension + display)
      # @return [String] e.g. "[File attached: report.docx — file path: /tmp/clacky-uploads/abc123.txt]"
      def self.save_and_reference(body, file_name)
        FileUtils.mkdir_p(UPLOAD_DIR)
        ext = File.extname(file_name).downcase

        case ext
        when ".docx", ".doc"
          text = extract_docx(body)
          save_as_text(text, file_name)
        when ".xlsx", ".xls"
          text = extract_xlsx(body)
          save_as_text(text, file_name)
        else
          file_id = "#{SecureRandom.hex(8)}#{ext}"
          dest    = File.join(UPLOAD_DIR, file_id)
          File.binwrite(dest, body)
          label = ext == ".pdf" ? "PDF attached" : "File attached"
          "[#{label}: #{file_name} — file path: #{dest}]"
        end
      end

      # --- private helpers ---

      def self.save_as_text(text, original_name)
        file_id = "#{SecureRandom.hex(8)}.txt"
        dest    = File.join(UPLOAD_DIR, file_id)
        File.write(dest, text, encoding: "UTF-8")
        "[File attached: #{original_name} — file path: #{dest}]"
      end

      def self.extract_docx(body)
        text_parts = []
        Zip::File.open_buffer(StringIO.new(body)) do |zip|
          entry = zip.find_entry("word/document.xml")
          return "(Could not extract content — possibly encrypted)" unless entry

          doc = REXML::Document.new(entry.get_input_stream.read)
          REXML::XPath.each(doc, "//w:p") do |para|
            texts = REXML::XPath.match(para, ".//w:t").map(&:text).compact.join
            text_parts << texts unless texts.strip.empty?
          end
        end
        text_parts.empty? ? "(Document appears to be empty)" : text_parts.join("\n")
      rescue => e
        "(Failed to parse document: #{e.message})"
      end

      def self.extract_xlsx(body)
        shared_strings = []
        sheets = {}

        Zip::File.open_buffer(StringIO.new(body)) do |zip|
          ss_entry = zip.find_entry("xl/sharedStrings.xml")
          if ss_entry
            doc = REXML::Document.new(ss_entry.get_input_stream.read)
            REXML::XPath.each(doc, "//si") do |si|
              shared_strings << REXML::XPath.match(si, ".//t").map(&:text).compact.join
            end
          end

          zip.each do |entry|
            if entry.name =~ %r{xl/worksheets/sheet(\d+)\.xml}
              sheets[$1.to_i] = entry.get_input_stream.read
            end
          end
        end

        rows = []
        sheets.keys.sort.each do |num|
          doc = REXML::Document.new(sheets[num])
          REXML::XPath.each(doc, "//row") do |row|
            cells = REXML::XPath.match(row, ".//c").map do |c|
              v = REXML::XPath.first(c, "v")&.text
              next "" unless v
              c.attributes["t"] == "s" ? (shared_strings[v.to_i] || "") : v
            end
            rows << cells.join("\t") unless cells.all?(&:empty?)
          end
        end
        rows.empty? ? "(Spreadsheet appears to be empty)" : rows.join("\n")
      rescue => e
        "(Failed to parse spreadsheet: #{e.message})"
      end

      private_class_method :save_as_text, :extract_docx, :extract_xlsx
    end
  end
end
