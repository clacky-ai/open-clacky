# frozen_string_literal: true

require_relative "base"
require_relative "../utils/file_processor"

module Clacky
  module Tools
    class FileReader < Base
      self.tool_name = "file_reader"
      self.tool_description = "Read contents of a file from the filesystem."
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute or relative path to the file"
          },
          max_lines: {
            type: "integer",
            description: "Maximum number of lines to read from start (default: 500)",
            default: 500
          },
          start_line: {
            type: "integer",
            description: "Start line number (1-indexed, e.g., 100 reads from line 100)"
          },
          end_line: {
            type: "integer",
            description: "End line number (1-indexed, e.g., 200 reads up to line 200)"
          }
        },
        required: ["path"]
      }



      # Maximum text file size (1MB)
      MAX_TEXT_FILE_SIZE = 1 * 1024 * 1024

      # Maximum content size to return (~10,000 tokens = ~40,000 characters)
      MAX_CONTENT_CHARS = 40_000

      # Maximum characters per line (prevent single huge lines from bloating tokens)
      MAX_LINE_CHARS = 1000

      def execute(path:, max_lines: 500, start_line: nil, end_line: nil, working_dir: nil)
        # Expand ~ to home directory
        expanded_path = expand_path(path)

        unless File.exist?(expanded_path)
          return {
            path: expanded_path,
            content: nil,
            error: "File not found: #{expanded_path}"
          }
        end

        # If path is a directory, list its first-level contents (similar to filetree)
        if File.directory?(expanded_path)
          return list_directory_contents(expanded_path)
        end

        unless File.file?(expanded_path)
          return {
            path: expanded_path,
            content: nil,
            error: "Path is not a file: #{expanded_path}"
          }
        end

        begin
          # Check if file is binary
          if Utils::FileProcessor.binary_file_path?(expanded_path)
            return handle_binary_file(expanded_path)
          end

          # Check text file size (only for non-binary files)
          file_size = File.size(expanded_path)
          if file_size > MAX_TEXT_FILE_SIZE
            return {
              path: expanded_path,
              content: nil,
              size_bytes: file_size,
              error: "Text file too large: #{format_file_size(file_size)} (max: #{format_file_size(MAX_TEXT_FILE_SIZE)}). Please use grep tool to search within this file instead."
            }
          end

          # Read text file with optional line range
          all_lines = File.readlines(expanded_path)
          total_lines = all_lines.size

          # Calculate start index (convert 1-indexed to 0-indexed)
          start_idx = start_line ? [start_line - 1, 0].max : 0

          # Calculate end index based on parameters
          if end_line
            # User specified end_line directly
            end_idx = [end_line - 1, total_lines - 1].min
          elsif start_line
            # start_line + max_lines - 1 (relative to start_line, inclusive)
            calculated_end_line = start_line + max_lines - 1
            end_idx = [calculated_end_line - 1, total_lines - 1].min
          else
            # Read from beginning with max_lines limit
            end_idx = [max_lines - 1, total_lines - 1].min
          end

          # Check if start_line exceeds file length first
          if start_idx >= total_lines
            return {
              path: expanded_path,
              content: nil,
              lines_read: 0,
              error: "Invalid line range: start_line #{start_line} exceeds total lines (#{total_lines})"
            }
          end

          # Validate range
          if start_idx > end_idx
            return {
              path: expanded_path,
              content: nil,
              lines_read: 0,
              error: "Invalid line range: start_line #{start_line} > end_line #{end_line || (start_line + max_lines)}"
            }
          end

          lines = all_lines[start_idx..end_idx] || []

          # Truncate individual lines that are too long
          lines = lines.map do |line|
            if line.length > MAX_LINE_CHARS
              line[0...MAX_LINE_CHARS] + "... [Line truncated - #{line.length} chars]\n"
            else
              line
            end
          end

          content = lines.join
          truncated = end_idx < (total_lines - 1)

          # Truncate total content if it exceeds maximum size
          if content.length > MAX_CONTENT_CHARS
            content = content[0...MAX_CONTENT_CHARS] +
                     "\n\n[Content truncated - exceeded #{MAX_CONTENT_CHARS} characters (~10,000 tokens)]" +
                     "\nUse start_line/end_line parameters to read specific sections, or grep tool to search for keywords."
            truncated = true
          end

          {
            path: expanded_path,
            content: content,
            lines_read: lines.size,
            total_lines: total_lines,
            truncated: truncated,
            start_line: start_line,
            end_line: end_line,
            error: nil
          }
        rescue StandardError => e
          {
            path: expanded_path,
            content: nil,
            error: "Error reading file: #{e.message}"
          }
        end
      end

      def format_call(args)
        path = args[:path] || args['path']
        "Read(#{Utils::PathHelper.safe_basename(path)})"
      end

      def format_result(result)
        return result[:error] if result[:error]

        # Handle directory listing
        if result[:is_directory] || result['is_directory']
          entries = result[:entries_count] || result['entries_count'] || 0
          dirs = result[:directories_count] || result['directories_count'] || 0
          files = result[:files_count] || result['files_count'] || 0
          return "Listed #{entries} entries (#{dirs} directories, #{files} files)"
        end

        # Handle binary file
        if result[:binary] || result['binary']
          format_type = result[:format] || result['format'] || 'unknown'
          size = result[:size_bytes] || result['size_bytes'] || 0

          # Check if it has base64 data (LLM-compatible format)
          if result[:base64_data] || result['base64_data']
            size_warning = size > 5_000_000 ? " (WARNING: large file)" : ""
            return "Binary file (#{format_type}, #{format_file_size(size)}) - sent to LLM#{size_warning}"
          else
            return "Binary file (#{format_type}, #{format_file_size(size)}) - cannot be read as text"
          end
        end

        # Handle text file reading
        lines = result[:lines_read] || result['lines_read'] || 0
        truncated = result[:truncated] || result['truncated']
        "Read #{lines} lines#{truncated ? ' (truncated)' : ''}"
      end

      # Format result for LLM - handles both text and binary (image/PDF) content
      # This method is called by the agent to format tool results before sending to LLM
      def format_result_for_llm(result)
        # For LLM-compatible binary files with base64 data, return as content blocks
        if result[:binary] && result[:base64_data]
          # Create a text description
          description = "File: #{result[:path]}\nType: #{result[:format]}\nSize: #{format_file_size(result[:size_bytes])}"

          # Add size warning for large files
          if result[:size_bytes] > 5_000_000
            description += "\nWARNING: Large file (>5MB) - may consume significant tokens"
          end

          # For images, return both description and image content
          if result[:mime_type]&.start_with?("image/")
            return {
              type: "image",
              path: result[:path],
              format: result[:format],
              size_bytes: result[:size_bytes],
              mime_type: result[:mime_type],
              base64_data: result[:base64_data],
              description: description
            }
          end

          # For PDFs and other binary formats, just return metadata with base64
          return {
            type: "document",
            path: result[:path],
            format: result[:format],
            size_bytes: result[:size_bytes],
            mime_type: result[:mime_type],
            base64_data: result[:base64_data],
            description: description
          }
        end

        # For error cases, return hash as-is
        return result if result[:error] || result[:content].nil?

        # For directory listings, return as-is (no raw file content to preserve)
        return result if result[:is_directory]

        # For plain text files: return a plain string so the agent sends it
        # directly to the LLM without JSON-encoding (avoids \" / \n escaping).
        header = "File: #{result[:path]}"
        header += " (lines #{result[:start_line]}-#{result[:end_line]})" if result[:start_line]
        header += " [#{result[:lines_read]}/#{result[:total_lines]} lines]"
        header += " [TRUNCATED]" if result[:truncated]
        "#{header}\n\n#{result[:content]}"
      end

      private def handle_binary_file(path)
        # Check if it's a supported format using FileProcessor
        if Utils::FileProcessor.supported_binary_file?(path)
          # Use FileProcessor to convert to base64
          begin
            result = Utils::FileProcessor.file_to_base64(path)
            {
              path: path,
              binary: true,
              format: result[:format],
              mime_type: result[:mime_type],
              size_bytes: result[:size_bytes],
              base64_data: result[:base64_data],
              error: nil
            }
          rescue ArgumentError => e
            # File too large or other error
            file_size = File.size(path)
            ext = File.extname(path).downcase
            {
              path: path,
              binary: true,
              format: ext.empty? ? "unknown" : ext[1..-1],
              size_bytes: file_size,
              content: nil,
              error: e.message
            }
          end
        else
          # Binary file that we can't send to LLM
          file_size = File.size(path)
          ext = File.extname(path).downcase
          {
            path: path,
            binary: true,
            format: ext.empty? ? "unknown" : ext[1..-1],
            size_bytes: file_size,
            content: nil,
            error: "Binary file detected. This format cannot be read as text. File size: #{format_file_size(file_size)}"
          }
        end
      end

      private def detect_mime_type(path, data)
        Utils::FileProcessor.detect_mime_type(path, data)
      end

      private def format_file_size(bytes)
        if bytes < 1024
          "#{bytes} bytes"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(2)} KB"
        else
          "#{(bytes / (1024.0 * 1024)).round(2)} MB"
        end
      end

      private

      # List first-level directory contents (files and directories)
      private def list_directory_contents(path)
        begin
          entries = Dir.entries(path).reject { |entry| entry == "." || entry == ".." }

          # Separate files and directories
          files = []
          directories = []

          entries.each do |entry|
            full_path = File.join(path, entry)
            if File.directory?(full_path)
              directories << entry + "/"
            else
              files << entry
            end
          end

          # Sort directories and files separately, then combine
          directories.sort!
          files.sort!
          all_entries = directories + files

          # Format as a tree-like structure
          content = all_entries.map { |entry| "  #{entry}" }.join("\n")

          {
            path: path,
            content: "Directory listing:\n#{content}",
            entries_count: all_entries.size,
            directories_count: directories.size,
            files_count: files.size,
            is_directory: true,
            error: nil
          }
        rescue StandardError => e
          {
            path: path,
            content: nil,
            error: "Error reading directory: #{e.message}"
          }
        end
      end
    end
  end
end
