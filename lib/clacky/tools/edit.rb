# frozen_string_literal: true

module Clacky
  module Tools
    class Edit < Base
      self.tool_name = "edit"
      self.tool_description = "Make precise edits to existing files by replacing old text with new text. " \
                              "The old_string must match exactly (including whitespace and indentation)."
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "The path of the file to edit (absolute or relative)"
          },
          old_string: {
            type: "string",
            description: "The exact string to find and replace (must match exactly including whitespace)"
          },
          new_string: {
            type: "string",
            description: "The new string to replace the old string with"
          },
          replace_all: {
            type: "boolean",
            description: "If true, replace all occurrences. If false (default), replace only the first occurrence",
            default: false
          }
        },
        required: %w[path old_string new_string]
      }

      def execute(path:, old_string:, new_string:, replace_all: false)
        # Validate path
        unless File.exist?(path)
          return { error: "File not found: #{path}" }
        end

        unless File.file?(path)
          return { error: "Path is not a file: #{path}" }
        end

        begin
          # Read current content
          content = File.read(path)
          original_content = content.dup

          # Check if old_string exists
          unless content.include?(old_string)
            return { error: "String to replace not found in file" }
          end

          # Count occurrences
          occurrences = content.scan(old_string).length

          # If not replace_all and multiple occurrences, warn about ambiguity
          if !replace_all && occurrences > 1
            return {
              error: "String appears #{occurrences} times in the file. Use replace_all: true to replace all occurrences, " \
                     "or provide a more specific string that appears only once."
            }
          end

          # Perform replacement
          if replace_all
            content = content.gsub(old_string, new_string)
          else
            content = content.sub(old_string, new_string)
          end

          # Write modified content
          File.write(path, content)

          {
            path: File.expand_path(path),
            replacements: replace_all ? occurrences : 1,
            error: nil
          }
        rescue Errno::EACCES => e
          { error: "Permission denied: #{e.message}" }
        rescue StandardError => e
          { error: "Failed to edit file: #{e.message}" }
        end
      end
    end
  end
end
