# frozen_string_literal: true

require_relative "base"
require_relative "../utils/file_processor"

module Clacky
  module Tools
    class FileReader < Base
      self.tool_name = "file_reader"
      self.tool_description = "Read contents of a file from the filesystem. Supports text files, images (PNG/JPG/GIF/WEBP), and documents (PDF/DOCX/XLSX/PPTX — auto-converted to text via parsers, with OCR fallback for scanned PDFs)."
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
            description: "Maximum number of lines to read from start (default: 1000)",
            default: 1000
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
      MAX_CONTENT_CHARS = 60_000

      # Maximum characters per line (prevent single huge lines from bloating tokens)
      MAX_LINE_CHARS = 1000

      def execute(path:, max_lines: 1000, start_line: nil, end_line: nil, working_dir: nil)
        # Expand path relative to working_dir when provided
        expanded_path = expand_path(path, working_dir: working_dir)

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
          # Delegate to FileProcessor for file type dispatch. FileProcessor is
          # the single source of truth for how a file becomes a readable form
          # (parser-extracted text, image base64, archive listing, plain text).
          # FileReader here only shapes the result for the LLM.
          ref = Utils::FileProcessor.process_path(expanded_path)

          case ref.type
          when :image
            # Images go to LLM as base64 via the image_inject sidecar channel.
            return handle_image_file(expanded_path)

          when :pdf, :document, :spreadsheet, :presentation
            # Parser-backed document formats. FileProcessor has already
            # produced a preview markdown file (or set parse_error on failure).
            if ref.preview_path && File.exist?(ref.preview_path)
              return read_text_file(
                expanded_path,
                max_lines: max_lines,
                start_line: start_line,
                end_line: end_line,
                source_path: ref.preview_path,
                parsed_from: ref.type
              )
            else
              return build_parser_failure_result(expanded_path, ref)
            end

          when :text, :csv, :zip
            # FileProcessor already produced a preview (raw text copy for
            # text/csv, archive listing for zip/tar). Read the preview with
            # normal line-range + truncation rules.
            source = (ref.preview_path && File.exist?(ref.preview_path)) ? ref.preview_path : expanded_path
            return read_text_file(
              expanded_path,
              max_lines: max_lines,
              start_line: start_line,
              end_line: end_line,
              source_path: source
            )

          else
            # Unknown / :file — could be an unrecognised source file, a binary
            # blob, or anything else. Fall back to:
            #   1. If FileProcessor.binary_file_path? says it's binary → report unsupported.
            #   2. Otherwise → read as plain text (covers .rb, .py, .js, .log, etc.).
            if Utils::FileProcessor.binary_file_path?(expanded_path)
              return handle_unsupported_binary(expanded_path, ref)
            end

            return read_text_file(
              expanded_path,
              max_lines: max_lines,
              start_line: start_line,
              end_line: end_line
            )
          end
        rescue StandardError => e
          {
            path: expanded_path,
            content: nil,
            error: "Error reading file: #{e.message}"
          }
        end
      end

      # Read a plain-text file with line-range selection and token-budget
      # truncation. The source of the text can be:
      #   - the original file itself (source_path == expanded_path)
      #   - a parser-generated preview.md for documents (source_path = ref.preview_path)
      # The reported `path` is always the original file so the LLM sees a
      # consistent identity.
      private def read_text_file(display_path, max_lines:, start_line:, end_line:, source_path: nil, parsed_from: nil)
        source_path ||= display_path

        file_size = File.size(source_path)
        if file_size > MAX_TEXT_FILE_SIZE
          return {
            path: display_path,
            content: nil,
            size_bytes: file_size,
            error: "Text file too large: #{format_file_size(file_size)} (max: #{format_file_size(MAX_TEXT_FILE_SIZE)}). Please use grep tool to search within this file instead."
          }
        end

        # Read text file with optional line range.
        # Scrub invalid UTF-8 bytes (e.g. GBK-encoded files) so downstream
        # JSON.generate / history persistence won't blow up later.
        all_lines = File.readlines(source_path).map! { |line| safe_utf8(line) }
        total_lines = all_lines.size

        # Calculate start index (convert 1-indexed to 0-indexed)
        start_idx = start_line ? [start_line - 1, 0].max : 0

        # Calculate end index based on parameters
        if end_line
          end_idx = [end_line - 1, total_lines - 1].min
        elsif start_line
          calculated_end_line = start_line + max_lines - 1
          end_idx = [calculated_end_line - 1, total_lines - 1].min
        else
          end_idx = [max_lines - 1, total_lines - 1].min
        end

        if total_lines == 0
          return {
            path: display_path,
            content: "",
            lines_read: 0,
            total_lines: 0,
            truncated: false,
            start_line: start_line,
            end_line: end_line,
            parsed_from: parsed_from&.to_s,
            source_path: (source_path != display_path ? source_path : nil),
            error: nil
          }
        end

        # Check if start_line exceeds file length first
        if start_idx >= total_lines
          return {
            path: display_path,
            content: nil,
            lines_read: 0,
            error: "Invalid line range: start_line #{start_line} exceeds total lines (#{total_lines})"
          }
        end

        # Validate range
        if start_idx > end_idx
          return {
            path: display_path,
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
          path: display_path,
          content: content,
          lines_read: lines.size,
          total_lines: total_lines,
          truncated: truncated,
          start_line: start_line,
          end_line: end_line,
          parsed_from: parsed_from&.to_s,
          source_path: (source_path != display_path ? source_path : nil),
          error: nil
        }
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
            size_warning = size > Utils::FileProcessor::MAX_FILE_SIZE ? " (WARNING: large file)" : ""
            return "Binary file (#{format_type}, #{format_file_size(size)}) - sent to LLM#{size_warning}"
          else
            return "Binary file (#{format_type}, #{format_file_size(size)}) - cannot be read as text"
          end
        end

        # Handle text file reading (including parser-extracted documents)
        lines = result[:lines_read] || result['lines_read'] || 0
        truncated = result[:truncated] || result['truncated']
        parsed_from = result[:parsed_from] || result['parsed_from']
        suffix = parsed_from ? " (from #{parsed_from})" : ""
        "Read #{lines} lines#{suffix}#{truncated ? ' (truncated)' : ''}"
      end

      # Format result for LLM - handles both text and binary (image) content
      # This method is called by the agent to format tool results before sending to LLM
      def format_result_for_llm(result)
        # For LLM-compatible binary files with base64 data (images only — documents
        # are converted to text upstream via FileProcessor parsers).
        if result[:binary] && result[:base64_data]
          description = "File: #{result[:path]}\nType: #{result[:format]}\nSize: #{format_file_size(result[:size_bytes])}"

          if result[:size_bytes] > Utils::FileProcessor::MAX_FILE_SIZE
            description += "\nWARNING: Large file (>#{Utils::FileProcessor::MAX_FILE_SIZE / 1024}KB) - may consume significant tokens"
          end

          # For images: return a plain-text tool result + a sidecar `image_inject`
          # payload that the agent will append as a follow-up `role: "user"` message.
          #
          # WHY: OpenAI-compatible APIs (including OpenRouter/Gemini) only accept
          # image_url content blocks inside `role: "user"` messages, NOT inside
          # `role: "tool"` messages.  Putting base64 in a tool message causes it to
          # be JSON-encoded as a plain string, which the tokeniser treats as text —
          # blowing up token counts by 20-40x (observed: ~115k tokens for a 124 KB jpg).
          #
          # The agent detects `:image_inject` in the tool result after observe() and
          # appends a `role: "user"` system_injected message containing the image block.
          if result[:mime_type]&.start_with?("image/")
            return {
              type: "text",
              text: description,
              image_inject: {
                mime_type: result[:mime_type],
                base64_data: result[:base64_data],
                path: result[:path]
              }
            }
          end

          # No non-image binary type should reach here anymore — documents now
          # go through the parser + text path. Keep this as a defensive fallback.
          return {
            type: "document",
            path: result[:path],
            format: result[:format],
            size_bytes: result[:size_bytes],
            mime_type: result[:mime_type],
            description: description
          }
        end

        # For error cases, return hash as-is
        return result if result[:error] || result[:content].nil?

        # For directory listings, return as-is (no raw file content to preserve)
        return result if result[:is_directory]

        # For plain text files (and parser-extracted documents): return a plain
        # string so the agent sends it directly to the LLM without JSON-encoding
        # (avoids \" / \n escaping).
        header = "File: #{result[:path]}"
        if result[:parsed_from]
          header += " [extracted from #{result[:parsed_from]}]"
        end
        header += " (lines #{result[:start_line]}-#{result[:end_line]})" if result[:start_line]
        header += " [#{result[:lines_read]}/#{result[:total_lines]} lines]"
        header += " [TRUNCATED]" if result[:truncated]
        "#{header}\n\n#{result[:content]}"
      end

      # Handle an image file: convert to base64 and return an LLM-ready result
      # with the image_inject sidecar. Used by execute() for :image type files.
      private def handle_image_file(path)
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
          # File too large or unreadable
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
      end

      # Handle an unsupported binary file (no parser available, not an image).
      # Returns a clear error message so the LLM knows it needs a different approach.
      private def handle_unsupported_binary(path, ref = nil)
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

      # Build an error result when the parser for a supported document format
      # failed. The LLM receives the parser path so it can fix and retry, matching
      # the behaviour of the file-upload pipeline (agent.rb's file_prompt).
      private def build_parser_failure_result(path, ref)
        ext = File.extname(path).downcase
        file_size = File.size(path) rescue 0
        message_lines = ["Failed to extract text from #{ext.empty? ? 'file' : ext[1..-1].upcase}."]
        message_lines << "Parser error: #{ref.parse_error}" if ref.parse_error
        if ref.parser_path
          expected_preview = "#{path}.preview.md"
          message_lines << "Parser script: #{ref.parser_path}"
          message_lines << "To fix: edit the parser, then run: ruby #{ref.parser_path} #{path} > #{expected_preview}"
          message_lines << "After a successful parse, re-run file_reader on this file."
        end
        {
          path: path,
          binary: true,
          format: ext.empty? ? "unknown" : ext[1..-1],
          size_bytes: file_size,
          content: nil,
          parser_path: ref.parser_path,
          parse_error: ref.parse_error,
          error: message_lines.join("\n")
        }
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


      # List first-level directory contents (files and directories)
      private def list_directory_contents(path)
        begin
          # Scrub entry names — filenames on disk may contain non-UTF-8 bytes
          # (e.g. GBK/Shift-JIS names on macOS/Linux) which would poison history.
          entries = Dir.entries(path)
                       .map { |entry| safe_utf8(entry) }
                       .reject { |entry| entry == "." || entry == ".." }

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

      # Scrub invalid UTF-8 byte sequences so the result survives
      # JSON.generate (session replay, API responses).
      # Invalid bytes are replaced with U+FFFD (�). Valid UTF-8 is
      # returned untouched via the fast path.
      private def safe_utf8(str)
        return str if str.nil?
        return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?
        str.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\u{FFFD}")
      end
    end
  end
end
