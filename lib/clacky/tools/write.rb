# frozen_string_literal: true

module Clacky
  module Tools
    class Write < Base
      self.tool_name = "write"
      self.tool_description = "Write content to a file. Creates new files or overwrites existing ones."
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "The path of the file to write (absolute or relative)"
          },
          content: {
            type: "string",
            description: "The content to write to the file"
          }
        },
        required: %w[path content]
      }

      def execute(path:, content:, working_dir: nil)
        # Validate path
        if path.nil? || path.strip.empty?
          return { error: "Path cannot be empty" }
        end

        begin
          # Expand ~ to home directory
          path = expand_path(path)

          # Ensure parent directory exists
          dir = File.dirname(path)
          FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

          # Write content to file
          File.write(path, content)

          {
            path: File.expand_path(path),
            bytes_written: content.bytesize,
            error: nil
          }
        rescue Errno::EACCES => e
          { error: "Permission denied: #{e.message}" }
        rescue Errno::ENOSPC => e
          { error: "No space left on device: #{e.message}" }
        rescue StandardError => e
          { error: "Failed to write file: #{e.message}" }
        end
      end

      def format_call(args)
        path = args[:path] || args['path']
        "Write(#{Utils::PathHelper.safe_basename(path)})"
      end

      def format_result(result)
        return result[:error] if result[:error]

        bytes = result[:bytes_written] || result['bytes_written'] || 0
        "Written #{bytes} bytes"
      end
    end
  end
end
