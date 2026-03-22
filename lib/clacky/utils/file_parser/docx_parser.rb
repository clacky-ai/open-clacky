# frozen_string_literal: true

require "zip"
require "rexml/document"
require "stringio"

module Clacky
  module FileParser
    # Parses DOCX/DOC files into Markdown, preserving headings, paragraphs, and tables.
    module DocxParser
      # Parse raw DOCX bytes and return a Markdown string.
      # @param body [String] Raw file bytes
      # @return [String] Markdown representation
      def self.parse(body)
        xml = read_document_xml(body)
        raise "Failed to open file: #{xml[1..-2]}" if xml.start_with?("(") # error string from read_document_xml

        doc = REXML::Document.new(xml)
        numbering = read_numbering(body)
        styles    = read_styles(body)

        lines = []
        REXML::XPath.each(doc, "//w:body/*") do |node|
          case node.name
          when "p"
            line = parse_paragraph(node, styles, numbering)
            lines << line unless line.nil?
          when "tbl"
            lines << parse_table(node)
          end
        end

        result = lines.join("\n").strip
        result.empty? ? "(Document appears to be empty)" : result
      end

      # --- private ---

      def self.read_document_xml(body)
        Zip::File.open_buffer(StringIO.new(body)) do |zip|
          entry = zip.find_entry("word/document.xml")
          raise "Could not extract content — possibly encrypted or invalid format" unless entry
          entry.get_input_stream.read
        end
      end

      # Returns a hash: { abstract_num_id => { ilvl => { numFmt, start } } }
      def self.read_numbering(body)
        result = {}
        Zip::File.open_buffer(StringIO.new(body)) do |zip|
          entry = zip.find_entry("word/numbering.xml")
          break unless entry
          doc = REXML::Document.new(entry.get_input_stream.read)
          REXML::XPath.each(doc, "//w:abstractNum") do |an|
            id = an.attributes["w:abstractNumId"]
            levels = {}
            REXML::XPath.each(an, "w:lvl") do |lvl|
              ilvl = lvl.attributes["w:ilvl"].to_i
              fmt  = REXML::XPath.first(lvl, "w:numFmt")&.attributes&.[]("w:val")
              levels[ilvl] = { fmt: fmt || "bullet" }
            end
            result[id] = levels
          end
        end
        result
      rescue
        {}
      end

      # Returns a hash: { styleId => { heading_level } }
      def self.read_styles(body)
        result = {}
        Zip::File.open_buffer(StringIO.new(body)) do |zip|
          entry = zip.find_entry("word/styles.xml")
          break unless entry
          doc = REXML::Document.new(entry.get_input_stream.read)
          REXML::XPath.each(doc, "//w:style") do |s|
            sid  = s.attributes["w:styleId"]
            name = REXML::XPath.first(s, "w:name")&.attributes&.[]("w:val").to_s
            if name =~ /^heading (\d)/i
              result[sid] = { heading: $1.to_i }
            end
          end
        end
        result
      rescue
        {}
      end

      def self.parse_paragraph(node, styles, numbering)
        ppr    = REXML::XPath.first(node, "w:pPr")
        style  = REXML::XPath.first(ppr, "w:pStyle")&.attributes&.[]("w:val") if ppr
        num_pr = REXML::XPath.first(ppr, "w:numPr") if ppr

        text = extract_runs(node)
        return nil if text.strip.empty?

        # Heading
        if style && styles[style]
          level = styles[style][:heading]
          return "#{"#" * level} #{text}"
        end

        # List item
        if num_pr
          ilvl = REXML::XPath.first(num_pr, "w:ilvl")&.attributes&.[]("w:val").to_i
          indent = "  " * ilvl
          return "#{indent}- #{text}"
        end

        text
      end

      def self.extract_runs(para_node)
        parts = []
        REXML::XPath.each(para_node, "w:r") do |run|
          rpr  = REXML::XPath.first(run, "w:rPr")
          bold = REXML::XPath.first(rpr, "w:b") if rpr
          text = REXML::XPath.match(run, "w:t").map(&:text).compact.join
          next if text.empty?
          parts << (bold ? "**#{text}**" : text)
        end
        parts.join
      end

      def self.parse_table(tbl_node)
        rows = []
        REXML::XPath.each(tbl_node, "w:tr") do |tr|
          cells = REXML::XPath.match(tr, "w:tc").map do |tc|
            REXML::XPath.match(tc, ".//w:t").map(&:text).compact.join(" ").strip
          end
          rows << cells
        end
        return "" if rows.empty?

        # Build markdown table
        col_count = rows.map(&:size).max
        lines = []
        rows.each_with_index do |row, i|
          padded = row + [""] * [col_count - row.size, 0].max
          lines << "| #{padded.join(" | ")} |"
          # Header separator after first row
          lines << "|#{" --- |" * col_count}" if i == 0
        end
        lines.join("\n")
      end

      private_class_method :read_document_xml, :read_numbering, :read_styles,
                           :parse_paragraph, :extract_runs, :parse_table
    end
  end
end
