# frozen_string_literal: true

require "zip"
require "rexml/document"
require "stringio"

module Clacky
  module FileParser
    # Parses XLSX/XLS files into Markdown tables, one section per sheet.
    module XlsxParser
      # Parse raw XLSX bytes and return a Markdown string.
      # @param body [String] Raw file bytes
      # @return [String] Markdown representation with one table per sheet
      def self.parse(body)
        shared_strings = []
        sheet_names    = {}
        sheet_xmls     = {}

        Zip::File.open_buffer(StringIO.new(body)) do |zip|
          # Shared strings table
          ss_entry = zip.find_entry("xl/sharedStrings.xml")
          if ss_entry
            doc = REXML::Document.new(ss_entry.get_input_stream.read)
            REXML::XPath.each(doc, "//si") do |si|
              shared_strings << REXML::XPath.match(si, ".//t").map(&:text).compact.join
            end
          end

          # Sheet name mapping from workbook.xml
          wb_entry = zip.find_entry("xl/workbook.xml")
          if wb_entry
            doc = REXML::Document.new(wb_entry.get_input_stream.read)
            REXML::XPath.each(doc, "//sheet") do |s|
              idx  = s.attributes["sheetId"]
              name = s.attributes["name"]
              sheet_names[idx] = name if idx && name
            end
          end

          # Sheet XMLs
          zip.each do |entry|
            if entry.name =~ %r{xl/worksheets/sheet(\d+)\.xml}
              sheet_xmls[$1] = entry.get_input_stream.read
            end
          end
        end

        return "(Spreadsheet appears to be empty)" if sheet_xmls.empty?

        sections = []
        sheet_xmls.keys.sort_by(&:to_i).each do |idx|
          name = sheet_names[idx] || "Sheet#{idx}"
          doc  = REXML::Document.new(sheet_xmls[idx])

          rows = []
          REXML::XPath.each(doc, "//row") do |row|
            cells = parse_row(row, shared_strings)
            rows << cells unless cells.all?(&:empty?)
          end

          next if rows.empty?

          sections << "### #{name}\n\n#{build_markdown_table(rows)}"
        end

        sections.empty? ? "(Spreadsheet appears to be empty)" : sections.join("\n\n")
      end

      # --- private ---

      def self.parse_row(row_node, shared_strings)
        REXML::XPath.match(row_node, ".//c").map do |c|
          v = REXML::XPath.first(c, "v")&.text
          next "" unless v
          c.attributes["t"] == "s" ? (shared_strings[v.to_i] || "") : v
        end
      end

      def self.build_markdown_table(rows)
        col_count = rows.map(&:size).max
        lines = []
        rows.each_with_index do |row, i|
          padded = row + [""] * [col_count - row.size, 0].max
          lines << "| #{padded.join(" | ")} |"
          lines << "|#{" --- |" * col_count}" if i == 0
        end
        lines.join("\n")
      end

      private_class_method :parse_row, :build_markdown_table
    end
  end
end
