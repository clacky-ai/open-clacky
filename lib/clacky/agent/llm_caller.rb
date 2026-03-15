# frozen_string_literal: true

module Clacky
  class Agent
    # LLM API call management
    # Handles API calls with retry logic and progress indication
    module LlmCaller
      # Execute LLM API call with progress indicator, retry logic, and cost tracking
      # This method is shared by both normal think() and compression flows
      # @return [Hash] API response with :content, :tool_calls, :usage, etc.
      private def call_llm
        @ui&.show_progress

        tools_to_send = @tool_registry.all_definitions

        # Retry logic for network failures
        max_retries = 10
        retry_delay = 5
        retries = 0

        begin
          # Use active_messages to filter out "future" messages after undo
          messages_to_send = respond_to?(:active_messages) ? active_messages : @messages
          
          response = @client.send_messages_with_tools(
            messages_to_send,
            model: current_model,
            tools: tools_to_send,
            max_tokens: @config.max_tokens,
            enable_caching: @config.enable_prompt_caching
          )
        rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
          @ui&.clear_progress
          retries += 1
          if retries <= max_retries
            @ui&.show_warning("Network failed: #{e.message}. Retry #{retries}/#{max_retries}...")
            sleep retry_delay
            retry
          else
            @ui&.show_error("Network failed after #{max_retries} retries: #{e.message}")
            raise AgentError, "Network connection failed after #{max_retries} retries: #{e.message}"
          end
        ensure
          @ui&.clear_progress
        end

        # Track cost and collect token usage data.
        # token_data is returned to the caller so it can be displayed
        # after show_assistant_message (ensuring correct ordering in WebUI).
        token_data = track_cost(response[:usage], raw_api_usage: response[:raw_api_usage])
        response[:token_usage] = token_data

        response
      end
    end
  end
end
