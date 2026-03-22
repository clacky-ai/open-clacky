# frozen_string_literal: true

require "zip"
require "rexml/document"
require "stringio"

module Clacky
  module FileParser
    # Parses PPTX files into Markdown, one section per slide.
    # Extracts slide titles, body text, and table content.
    module PptxParser
      # Parse raw PPTX bytes and return a Markdown string.
      # @param body [String] Raw file bytes
      # @return [String] Markdown representation
      def self.parse(body)
        slides = {}

        Zip::File.open_buffer(StringIO.new(body)) do |zip|
          zip.each do |entry|
            if entry.name =~ %r{ppt/slides/slide(\d+)\.xml}
              slides[$1.to_i] = entry.get_input_stream.read
            end
          end
        end

        return "(Presentation appears to be empty)" if slides.empty?

        sections = slides.keys.sort.map do |num|
          doc = REXML::Document.new(slides[num])
          parse_slide(doc, num)
        end.compact

        sections.empty? ? "(Presentation appears to be empty)" : sections.join("\n\n---\n\n")
      end

      # --- private ---

      def self.parse_slide(doc, slide_num)
        lines = []

        # Title: look for ph type="title" or ph type="ctrTitle"
        title_text = nil
        REXML::XPath.each(doc, "//p:sp") do |sp|
          ph = REXML::XPath.first(sp, ".//p:ph")
          next unless ph
          ph_type = ph.attributes["type"]
          if ph_type == "title" || ph_type == "ctrTitle"
            title_text = extract_text(sp).strip
            break
          end
        end

        lines << "## Slide #{slide_num}#{title_text && !title_text.empty? ? ": #{title_text}" : ""}"

        # Body: all other text shapes
        REXML::XPath.each(doc, "//p:sp") do |sp|
          ph = REXML::XPath.first(sp, ".//p:ph")
          # Skip title shapes (already handled) and slide number/date placeholders
          if ph
            ph_type = ph.attributes["type"]
            next if %w[title ctrTitle sldNum dt ftr].include?(ph_type)
          end

          text = extract_text(sp).strip
          next if text.empty?
          next if text == title_text  # deduplicate

          # Indent body bullets
          text.each_line do |line|
            lines << "- #{line.rstrip}" unless line.strip.empty?
          end
        end

        # Tables
        REXML::XPath.each(doc, "//a:tbl") do |tbl|
          lines << parse_table(tbl)
        end

        lines.join("\n")
      end

      def self.extract_text(shape_node)
        paras = []
        REXML::XPath.each(shape_node, ".//a:p") do |para|
          text = REXML::XPath.match(para, ".//a:t").map(&:text).compact.join
          paras << text unless text.strip.empty?
        end
        paras.join("\n")
      end

      def self.parse_table(tbl_node)
        rows = []
        REXML::XPath.each(tbl_node, ".//a:tr") do |tr|
          cells = REXML::XPath.match(tr, ".//a:tc").map do |tc|
            REXML::XPath.match(tc, ".//a:t").map(&:text).compact.join(" ").strip
          end
          rows << cells
        end
        return "" if rows.empty?

        col_count = rows.map(&:size).max
        lines = []
        rows.each_with_index do |row, i|
          padded = row + [""] * [col_count - row.size, 0].max
          lines << "| #{padded.join(" | ")} |"
          lines << "|#{" --- |" * col_count}" if i == 0
        end
        lines.join("\n")
      end

      private_class_method :parse_slide, :extract_text, :parse_table
    end
  end
end
