# frozen_string_literal: true

require "tty-prompt"
require "pastel"
require "tty-screen"
require_relative "enhanced_prompt"

module Clacky
  module UI
    # Enhanced input prompt with box drawing and status info
    class Prompt
      def initialize
        @pastel = Pastel.new
        @enhanced_prompt = EnhancedPrompt.new
      end

      # Read user input with enhanced prompt box
      # @param prefix [String] Prompt prefix (default: "You:")
      # @param placeholder [String] Placeholder text (not used)
      # @return [String, nil] User input text or nil on EOF
      # @return [Hash, nil] { text: String, images: Array } or nil on EOF if images present
      def read_input(prefix: "You:", placeholder: nil)
        result = @enhanced_prompt.read_input(prefix: prefix)
        
        # Return nil if cancelled
        return nil if result.nil?
        
        # For now, just return the text (images will be handled in future updates)
        # TODO: Update agent to handle images
        result[:text]
      end
    end
  end
end
