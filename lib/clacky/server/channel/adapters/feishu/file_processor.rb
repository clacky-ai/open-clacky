# frozen_string_literal: true

require "clacky/tools/file_attachment"

module Clacky
  module Channel
    module Adapters
      module Feishu
        # Processes file attachments downloaded from Feishu messages.
        # Returns a path-reference string to be injected into the agent prompt.
        module FileProcessor
          MAX_FILE_BYTES = Clacky::Tools::FileAttachment::MAX_FILE_BYTES

          # Allowlist of extensions confirmed to be agent-readable at low token cost.
          # Unknown formats are rejected to avoid expensive shell-based extraction.
          SUPPORTED_EXTENSIONS = %w[pdf docx doc xlsx xls txt md json csv html].freeze

          # Check if a file is supported before downloading.
          # @param file_name [String]
          # @return [String, nil] error message if unsupported, nil if ok
          def self.unsupported_error(file_name)
            ext = File.extname(file_name).downcase.delete_prefix(".")
            return nil if SUPPORTED_EXTENSIONS.include?(ext)
            "[Attachment: #{file_name}]\nUnsupported file type .#{ext}. Supported: #{SUPPORTED_EXTENSIONS.join(", ")}."
          end

          # Process a downloaded file and return a text snippet for the prompt.
          # @param body [String] Raw file bytes
          # @param file_name [String] Original file name
          # @return [String] Text to inject into the prompt
          def self.process(body, file_name)
            if body.bytesize > MAX_FILE_BYTES
              return "[Attachment: #{file_name}]\nFile too large (#{body.bytesize / 1024 / 1024}MB), max #{MAX_FILE_BYTES / 1024 / 1024}MB."
            end

            Clacky::Tools::FileAttachment.save_and_reference(body, file_name)
          end
        end
      end
    end
  end
end
