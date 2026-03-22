# frozen_string_literal: true

require "zip"
require "stringio"

module Clacky
  module FileParser
    # Lists the contents of a ZIP archive as a Markdown file tree.
    module ZipParser
      MAX_ENTRIES = 200

      # Parse raw ZIP bytes and return a Markdown directory listing.
      # @param body [String] Raw file bytes
      # @return [String] Markdown representation of archive contents
      def self.parse(body)
        entries = []

        Zip::File.open_buffer(StringIO.new(body)) do |zip|
          zip.each do |entry|
            entries << {
              name: entry.name,
              size: entry.file? ? entry.size : nil,
              dir:  entry.directory?
            }
            break if entries.size >= MAX_ENTRIES
          end
        end

        return "(ZIP archive appears to be empty)" if entries.empty?

        truncated = entries.size >= MAX_ENTRIES
        lines = ["**Archive contents** (#{entries.size}#{truncated ? "+" : ""} entries):\n"]

        entries.sort_by { |e| [e[:dir] ? 0 : 1, e[:name]] }.each do |e|
          if e[:dir]
            lines << "- 📁 #{e[:name]}"
          else
            size_str = e[:size] ? " *(#{format_size(e[:size])})*" : ""
            lines << "- #{e[:name]}#{size_str}"
          end
        end

        lines << "\n*(listing truncated at #{MAX_ENTRIES} entries)*" if truncated
        lines.join("\n")
      end

      # --- private ---

      def self.format_size(bytes)
        return "#{bytes} B"       if bytes < 1024
        return "#{bytes / 1024} KB" if bytes < 1024 * 1024
        "#{(bytes / 1024.0 / 1024).round(1)} MB"
      end

      private_class_method :format_size
    end
  end
end
