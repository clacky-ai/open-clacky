# frozen_string_literal: true

require "clacky/utils/file_attachment"

module Clacky
  module Channel
    module Adapters
      module Feishu
        # Processes file attachments downloaded from Feishu messages.
        # Returns a path-reference string to be injected into the agent prompt.
        module FileProcessor
          MAX_FILE_BYTES = Clacky::FileAttachment::MAX_FILE_BYTES

          # Process a downloaded file and return a text snippet for the prompt.
          # @param body [String] Raw file bytes
          # @param file_name [String] Original file name
          # @return [String] Text to inject into the prompt
          def self.process(body, file_name)
            if body.bytesize > MAX_FILE_BYTES
              return "[Attachment: #{file_name}]\nFile too large (#{body.bytesize / 1024 / 1024}MB), max #{MAX_FILE_BYTES / 1024 / 1024}MB."
            end

            Clacky::FileAttachment.save_and_reference(body, file_name)
          end
        end
      end
    end
  end
end
