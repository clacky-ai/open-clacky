# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  class Client
    MAX_RETRIES = 10
    RETRY_DELAY = 5 # seconds

    def initialize(api_key, base_url:)
      @api_key = api_key
      @base_url = base_url
    end

    def send_message(content, model:, max_tokens:)
      response = connection.post("chat/completions") do |req|
        req.body = {
          model: model,
          max_tokens: max_tokens,
          messages: [
            {
              role: "user",
              content: content
            }
          ]
        }.to_json
      end

      handle_response(response)
    end

    def send_messages(messages, model:, max_tokens:)
      response = connection.post("chat/completions") do |req|
        req.body = {
          model: model,
          max_tokens: max_tokens,
          messages: messages
        }.to_json
      end

      handle_response(response)
    end

    # Send messages with function calling (tools) support
    # Options:
    #   - enable_caching: Enable prompt caching for system prompt and tools (default: false)
    def send_messages_with_tools(messages, model:, tools:, max_tokens:, enable_caching: false)
      # Apply caching to messages if enabled
      caching_supported = supports_prompt_caching?(model)
      caching_enabled = enable_caching && caching_supported

      # Deep clone messages to avoid modifying the original array
      processed_messages = messages.map { |msg| deep_clone(msg) }

      # Add cache control to messages if caching is enabled
      # Strategy: Cache system prompt and first user message for stable prefix caching
      if caching_enabled
        processed_messages = apply_message_caching(processed_messages)
      end

      body = {
        model: model,
        max_tokens: max_tokens,
        messages: processed_messages
      }

      # Add tools if provided
      # For Claude API with caching: mark the last tool definition with cache_control
      if tools&.any?
        caching_supported = supports_prompt_caching?(model)
        caching_enabled = enable_caching && caching_supported

        if caching_enabled
          # Deep clone tools to avoid modifying original
          cached_tools = tools.map { |tool| deep_clone(tool) }
          # Mark the last tool for caching (Claude caches from cache breakpoint to end)
          cached_tools.last[:cache_control] = { type: "ephemeral" }
          body[:tools] = cached_tools
        else
          body[:tools] = tools
        end
      end

      # Debug: Save request body to see what we're actually sending
      if ENV['CLACKY_DEBUG_REQUEST']
        debug_file = "/tmp/clacky_request_#{Time.now.to_i}.json"
        File.write(debug_file, JSON.pretty_generate(body))
        puts "DEBUG: Request saved to #{debug_file}"
      end

      response = connection.post("chat/completions") do |req|
        req.body = body.to_json
      end

      handle_tool_response(response)
    end

    private

    # Check if the model supports prompt caching
    # Currently only Claude 3.5+ models support this feature
    def supports_prompt_caching?(model)
      model_str = model.to_s.downcase
      
      # Only Claude models support prompt caching
      return false unless model_str.include?("claude")
      
      # Pattern matching for supported Claude versions:
      # - claude-3.5-*, claude-3-5-*, claude-3.5.*
      # - claude-3.7-*, claude-3-7-*, claude-3.7.*  
      # - claude-4*, claude-sonnet-4*
      # - anthropic/claude-sonnet-4* (OpenRouter format)
      cache_pattern = /
        claude                        # Must contain "claude"
        (?:                          # Non-capturing group for version patterns
          (?:-3[-.]?[5-9])|          # 3.5, 3.6, 3.7, 3.8, 3.9 or 3-5, 3-6, etc
          (?:-[4-9])|                # 4, 5, 6, 7, 8, 9 (future versions)
          (?:-sonnet-[34])           # OpenRouter: claude-sonnet-3, claude-sonnet-4
        )
      /x
      
      model_str.match?(cache_pattern)
    end

    # Apply cache_control to messages for prompt caching
    # Strategy: Add cache_control on the LAST message before tools
    # This ensures everything from start to the breakpoint gets cached
    def apply_message_caching(messages)
      return messages if messages.empty?

      # Add cache_control to the last message (before tools are added)
      # This will cache: system message + all conversation history
      messages.map.with_index do |msg, idx|
        if idx == messages.length - 1
          # Last message: add cache_control in content block
          add_cache_control_to_message(msg)
        else
          msg
        end
      end
    end

    # Convert message content to array format and add cache_control
    # Claude API format: content: [{type: "text", text: "...", cache_control: {...}}]
    def add_cache_control_to_message(msg)
      content = msg[:content]

      # Convert content to array format if it's a string
      content_array = if content.is_a?(String)
        [{ type: "text", text: content, cache_control: { type: "ephemeral" } }]
      elsif content.is_a?(Array)
        # Content is already an array, add cache_control to the last block
        content.map.with_index do |block, idx|
          if idx == content.length - 1
            block.merge(cache_control: { type: "ephemeral" })
          else
            block
          end
        end
      else
        # Unknown format, return as-is
        return msg
      end

      msg.merge(content: content_array)
    end

    # Deep clone a hash/array structure (for tool definitions)
    def deep_clone(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k] = deep_clone(v) }
      when Array
        obj.map { |item| deep_clone(item) }
      when String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass
        obj
      else
        obj.dup rescue obj
      end
    end

    def connection
      @connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"] = "application/json"
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.options.timeout = 120  # Read timeout in seconds
        conn.options.open_timeout = 10  # Connection timeout in seconds
        conn.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      case response.status
      when 200
        data = JSON.parse(response.body)
        data["choices"].first["message"]["content"]
      when 401
        raise Error, "Invalid API key"
      when 429
        raise Error, "Rate limit exceeded"
      when 500..599
        raise Error, "Server error: #{response.status}"
      else
        raise Error, "Unexpected error: #{response.status} - #{response.body}"
      end
    end

    def handle_tool_response(response)
      case response.status
      when 200
        data = JSON.parse(response.body)
        message = data["choices"].first["message"]
        usage = data["usage"]

        # Store raw API usage for debugging
        raw_api_usage = usage.dup

        # Parse usage with cache information
        usage_data = {
          prompt_tokens: usage["prompt_tokens"],
          completion_tokens: usage["completion_tokens"],
          total_tokens: usage["total_tokens"]
        }
        
        # Add OpenRouter cost information if present
        if usage["cost"]
          usage_data[:api_cost] = usage["cost"]
        end
        
        # Add cache metrics if present (Claude API with prompt caching)
        if usage["cache_creation_input_tokens"]
          usage_data[:cache_creation_input_tokens] = usage["cache_creation_input_tokens"]
        end
        if usage["cache_read_input_tokens"]
          usage_data[:cache_read_input_tokens] = usage["cache_read_input_tokens"]
        end
        
        # Add OpenRouter cache information from prompt_tokens_details
        if usage["prompt_tokens_details"]
          details = usage["prompt_tokens_details"]
          if details["cached_tokens"] && details["cached_tokens"] > 0
            usage_data[:cache_read_input_tokens] = details["cached_tokens"]
          end
          if details["cache_write_tokens"] && details["cache_write_tokens"] > 0
            usage_data[:cache_creation_input_tokens] = details["cache_write_tokens"]
          end
        end
        
        {
          content: message["content"],
          tool_calls: parse_tool_calls(message["tool_calls"]),
          finish_reason: data["choices"].first["finish_reason"],
          usage: usage_data,
          raw_api_usage: raw_api_usage
        }
      when 401
        raise Error, "Invalid API key"
      when 429
        raise Error, "Rate limit exceeded"
      when 500..599
        error_body = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          response.body
        end
        raise Error, "Server error: #{response.status}\nResponse: #{error_body.inspect}"
      else
        raise Error, "Unexpected error: #{response.status} - #{response.body}"
      end
    end

    def parse_tool_calls(tool_calls)
      return nil if tool_calls.nil? || tool_calls.empty?

      tool_calls.map do |call|
        {
          id: call["id"],
          type: call["type"],
          name: call["function"]["name"],
          arguments: call["function"]["arguments"]
        }
      end
    end
  end
end
