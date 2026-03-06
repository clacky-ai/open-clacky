# frozen_string_literal: true

module Clacky
  module Tools
    class RequestUserFeedback < Base
      self.tool_name = "request_user_feedback"
      self.tool_description = <<~DESC
        Request feedback or clarification from the user when you need more information to complete a task.
        Use this tool when:
        - You need clarification on ambiguous requirements
        - You need the user to choose between multiple options
        - You need additional information that you cannot infer
        - You want to confirm your understanding before proceeding
        
        After calling this tool, STOP and wait for the user's response.
        Do NOT continue with other actions until you receive user feedback.
      DESC
      
      self.tool_parameters = {
        type: "object",
        properties: {
          question: {
            type: "string",
            description: "The question or clarification request to ask the user"
          },
          context: {
            type: "string",
            description: "Optional context explaining why you need this information (helps user understand)"
          },
          options: {
            type: "array",
            items: { type: "string" },
            description: "Optional array of choices/options if asking user to select from predefined options"
          }
        },
        required: ["question"]
      }
      
      self.tool_category = "interaction"

      def execute(question:, context: nil, options: nil, working_dir: nil)
        # Build the feedback request message
        message_parts = []
        
        if context && !context.strip.empty?
          message_parts << "**Context:** #{context.strip}"
          message_parts << ""
        end
        
        message_parts << "**Question:** #{question.strip}"
        
        if options && !options.empty?
          message_parts << ""
          message_parts << "**Options:**"
          options.each_with_index do |option, index|
            message_parts << "  #{index + 1}. #{option}"
          end
        end
        
        formatted_message = message_parts.join("\n")
        
        {
          success: true,
          message: formatted_message,
          awaiting_feedback: true  # Special flag to indicate we're waiting for user
        }
      end

      def format_call(args)
        question = args[:question] || args["question"]
        preview = question.length > 60 ? "#{question[0..60]}..." : question
        "request_user_feedback(\"#{preview}\")"
      end

      def format_result(result)
        if result.is_a?(Hash) && result[:message]
          result[:message]
        else
          "Waiting for user feedback..."
        end
      end
    end
  end
end
