# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  class Client
    MAX_RETRIES = 10
    RETRY_DELAY = 5 # seconds

    def initialize(api_key, base_url:, model: nil, anthropic_format: false)
      @api_key = api_key
      @base_url = base_url
      @model = model
      @use_anthropic_format = anthropic_format
    end

    # Check if using Anthropic API format
    # Determined by the anthropic_format flag passed in constructor
    # (based on config source: ANTHROPIC_* env vars = true, config file = false)
    def anthropic_format?(model = nil)
      @use_anthropic_format
    end

    def send_message(content, model:, max_tokens:)
      if anthropic_format?(model)
        response = anthropic_connection.post("v1/messages") do |req|
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
        handle_anthropic_simple_response(response)
      else
        response = openai_connection.post("chat/completions") do |req|
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
    end

    def send_messages(messages, model:, max_tokens:)
      if anthropic_format?(model)
        # Convert to Anthropic format
        body = build_anthropic_body(messages, model, [], max_tokens, false)
        response = anthropic_connection.post("v1/messages") do |req|
          req.body = body.to_json
        end
        handle_anthropic_simple_response(response)
      else
        response = openai_connection.post("chat/completions") do |req|
          req.body = {
            model: model,
            max_tokens: max_tokens,
            messages: messages
          }.to_json
        end

        handle_response(response)
      end
    end

    # Send messages with function calling (tools) support
    # Options:
    #   - enable_caching: Enable prompt caching for system prompt and tools (default: false)
    def send_messages_with_tools(messages, model:, tools:, max_tokens:, enable_caching: false)
      # Auto-detect API format based on model name and base_url
      is_anthropic = anthropic_format?(model)

      # Deep clone messages to avoid modifying the original array
      processed_messages = messages.map { |msg| deep_clone(msg) }

      # Apply caching if enabled and supported
      caching_supported = supports_prompt_caching?(model)
      caching_enabled = enable_caching && caching_supported

      if is_anthropic
        send_anthropic_request(processed_messages, model, tools, max_tokens, caching_enabled)
      else
        send_openai_request(processed_messages, model, tools, max_tokens, caching_enabled)
      end
    end

    # Format tool results based on API type
    # Anthropic API: tool results go in user message content array
    # OpenAI API: tool results are separate messages with role: "tool"
    def format_tool_results(response, tool_results, model:)
      return [] if tool_results.empty?

      is_anthropic = anthropic_format?(model)

      # Create a map of tool_call_id -> result for quick lookup
      results_map = tool_results.each_with_object({}) do |result, hash|
        hash[result[:id]] = result
      end

      if is_anthropic
        # Anthropic format: tool results in user message content array
        tool_result_blocks = response[:tool_calls].map do |tool_call|
          result = results_map[tool_call[:id]]
          if result
            {
              type: "tool_result",
              tool_use_id: tool_call[:id],
              content: result[:content]
            }
          else
            {
              type: "tool_result",
              tool_use_id: tool_call[:id],
              content: JSON.generate({ error: "Tool result missing" })
            }
          end
        end

        # Return as a user message
        [
          {
            role: "user",
            content: tool_result_blocks
          }
        ]
      else
        # OpenAI format: tool results as separate messages
        response[:tool_calls].map do |tool_call|
          result = results_map[tool_call[:id]]
          if result
            {
              role: "tool",
              tool_call_id: result[:id],
              content: result[:content]
            }
          else
            {
              role: "tool",
              tool_call_id: tool_call[:id],
              content: JSON.generate({ error: "Tool result missing" })
            }
          end
        end
      end
    end

    private

    # Send request using OpenAI API format
    def send_openai_request(messages, model, tools, max_tokens, caching_enabled)
      # Apply caching to messages if enabled
      processed_messages = caching_enabled ? apply_message_caching(messages) : messages

      body = {
        model: model,
        max_tokens: max_tokens,
        messages: processed_messages
      }

      # Add tools if provided
      if tools&.any?
        if caching_enabled
          cached_tools = tools.map { |tool| deep_clone(tool) }
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
      end

      response = openai_connection.post("chat/completions") do |req|
        req.body = body.to_json
      end

      handle_tool_response(response)
    end

    # Send request using Anthropic API format
    def send_anthropic_request(messages, model, tools, max_tokens, caching_enabled)
      # Convert OpenAI message format to Anthropic format
      body = build_anthropic_body(messages, model, tools, max_tokens, caching_enabled)

      # DEBUG: Always save request body
      debug_file = "/tmp/clacky_request_body.json"
      File.write(debug_file, JSON.pretty_generate(body))

      response = anthropic_connection.post("v1/messages") do |req|
        req.body = body.to_json
      end

      # Debug response
      if ENV['CLACKY_DEBUG_REQUEST']
        timestamp = Time.now.to_i
        File.write("/tmp/clacky_debug_#{timestamp}.txt", "URL = #{@base_url}/v1/messages\n")
        File.write("/tmp/clacky_debug_#{timestamp}.txt", "API Key = #{@api_key[0..10]}...\n")
        File.write("/tmp/clacky_debug_#{timestamp}.txt", "Headers = #{anthropic_connection.headers.inspect}\n")
        File.open("/tmp/clacky_debug_#{timestamp}.txt", "a") do |f|
          f.puts "Response status = #{response.status}"
          f.puts "Response body = #{response.body}"
        end
      end

      handle_anthropic_response(response)
    end

    # Build request body in Anthropic format
    def build_anthropic_body(messages, model, tools, max_tokens, caching_enabled)
      # Separate system messages from regular messages
      system_messages = messages.select { |m| m[:role] == "system" }
      regular_messages = messages.reject { |m| m[:role] == "system" }

      # Build system for Anthropic - use string format which is most compatible
      system = if system_messages.any?
        system_messages.map do |msg|
          content = msg[:content]
          if content.is_a?(String)
            content
          elsif content.is_a?(Array)
            content.map { |block| block.is_a?(Hash) ? (block[:text] || block.dig(:text) || "") : block.to_s }.compact.join("\n")
          else
            content.to_s
          end
        end.join("\n\n")
      else
        ""
      end

      # Convert regular messages to Anthropic format
      anthropic_messages = regular_messages.map { |msg| convert_to_anthropic_message(msg, caching_enabled) }

      # Convert tools to Anthropic format
      anthropic_tools = tools&.map { |tool| convert_to_anthropic_tool(tool, caching_enabled) }

      # Add cache_control to last tool if caching is enabled
      if caching_enabled && anthropic_tools&.any?
        anthropic_tools.last[:cache_control] = { type: "ephemeral" }
      end

      # DEBUG: Log tools transformation
      debug_file = "/tmp/clacky_tools_debug.txt"
      File.write(debug_file, "Tools Debug:\n")
      File.write(debug_file, "Input tools count: #{tools&.length || 0}\n", mode: "a")
      File.write(debug_file, "Anthropic tools count: #{anthropic_tools&.length || 0}\n", mode: "a")
      if tools&.any?
        File.write(debug_file, "First input tool: #{JSON.pretty_generate(tools.first)}\n", mode: "a")
      end
      if anthropic_tools&.any?
        File.write(debug_file, "First anthropic tool: #{JSON.pretty_generate(anthropic_tools.first)}\n", mode: "a")
      end

      body = {
        model: model,
        max_tokens: max_tokens,
        messages: anthropic_messages
      }

      # Only include system if it's not empty
      body[:system] = system if system && !system.empty?

      body[:tools] = anthropic_tools if anthropic_tools&.any?

      # DEBUG: Log final body
      File.write(debug_file, "Body has tools: #{body.key?(:tools)}\n", mode: "a")
      File.write(debug_file, "Body tools count: #{body[:tools]&.length || 0}\n", mode: "a")

      body
    end

    # Convert a message to Anthropic format
    def convert_to_anthropic_message(message, caching_enabled)
      role = message[:role]
      content = message[:content]
      tool_calls = message[:tool_calls]

      # For assistant messages with tool_calls, convert tool_calls to content blocks
      if role == "assistant" && tool_calls && tool_calls.any?
        # Build content blocks from both content and tool_calls
        blocks = []

        # Add text content first
        if content.is_a?(String) && !content.empty?
          blocks << { type: "text", text: content }
        elsif content.is_a?(Array)
          blocks.concat(content.map do |block|
            case block[:type]
            when "text"
              { type: "text", text: block[:text] }
            when "image_url"
              url = block.dig(:image_url, :url) || block[:url]
              if url&.start_with?("data:")
                match = url.match(/^data:([^;]+);base64,(.*)$/)
                if match
                  { type: "image", source: { type: "base64", media_type: match[1], data: match[2] } }
                else
                  { type: "image", source: { type: "url", url: url } }
                end
              else
                { type: "image", source: { type: "url", url: url } }
              end
            else
              block
            end
          end)
        end

        # Add tool_use blocks
        tool_calls.each do |call|
          # Handle both OpenAI format (with function key) and direct format
          if call[:function]
            # OpenAI format
            tool_use_block = {
              type: "tool_use",
              id: call[:id],
              name: call[:function][:name],
              input: call[:function][:arguments].is_a?(String) ? JSON.parse(call[:function][:arguments]) : call[:function][:arguments]
            }
          else
            # Direct format
            tool_use_block = {
              type: "tool_use",
              id: call[:id],
              name: call[:name],
              input: call[:arguments].is_a?(String) ? JSON.parse(call[:arguments]) : call[:arguments]
            }
          end
          blocks << tool_use_block
        end

        return { role: role, content: blocks }
      end

      # Convert string content to array format
      if content.is_a?(String)
        return { role: role, content: [{ type: "text", text: content }] }
      end

      # Handle array content (already in some format)
      if content.is_a?(Array)
        blocks = content.map do |block|
          case block[:type]
          when "text"
            { type: "text", text: block[:text] }
          when "image_url"
            url = block.dig(:image_url, :url) || block[:url]
            if url&.start_with?("data:")
              match = url.match(/^data:([^;]+);base64,(.*)$/)
              if match
                { type: "image", source: { type: "base64", media_type: match[1], data: match[2] } }
              else
                { type: "image", source: { type: "url", url: url } }
              end
            else
              { type: "image", source: { type: "url", url: url } }
            end
          else
            block
          end
        end
        return { role: role, content: blocks }
      end

      { role: role, content: message[:content] }
    end

    # Convert a tool to Anthropic format
    # Handles both OpenAI format (with nested function key) and direct format
    def convert_to_anthropic_tool(tool, caching_enabled)
      # Handle OpenAI format from to_function_definition
      func = tool[:function] || tool
      {
        name: func[:name],
        description: func[:description],
        input_schema: func[:parameters]
      }
    end

    # Handle Anthropic API response
    def handle_anthropic_response(response)
      case response.status
      when 200
        data = JSON.parse(response.body)
        content_blocks = data["content"] || []
        usage = data["usage"] || {}

        # Extract content
        content = content_blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("")

        # Extract tool calls
        tool_calls = content_blocks.select { |b| b["type"] == "tool_use" }.map do |tc|
          {
            id: tc["id"],
            type: "function",
            name: tc["name"],
            arguments: tc["input"].is_a?(String) ? tc["input"] : tc["input"].to_json
          }
        end

        # DEBUG: Log what we got
        debug_file = "/tmp/clacky_anthropic_response.txt"
        File.write(debug_file, "Response Analysis:\n")
        File.write(debug_file, "content_blocks count: #{content_blocks.length}\n", mode: "a")
        File.write(debug_file, "content_block types: #{content_blocks.map { |b| b["type"] }.inspect}\n", mode: "a")
        File.write(debug_file, "tool_use blocks found: #{content_blocks.select { |b| b["type"] == "tool_use" }.length}\n", mode: "a")
        File.write(debug_file, "extracted tool_calls: #{tool_calls.length}\n", mode: "a")
        File.write(debug_file, "finish_reason (raw): #{data["stop_reason"]}\n", mode: "a")
        File.write(debug_file, "Full content_blocks: #{JSON.pretty_generate(content_blocks)}\n", mode: "a")

        # Parse finish reason
        finish_reason = case data["stop_reason"]
        when "end_turn" then "stop"
        when "tool_use" then "tool_calls"
        when "max_tokens" then "length"
        else data["stop_reason"]
        end

        # Build usage data
        usage_data = {
          prompt_tokens: usage["input_tokens"],
          completion_tokens: usage["output_tokens"],
          total_tokens: usage["input_tokens"].to_i + usage["output_tokens"].to_i
        }

        # Add cache metrics if present
        if usage["cache_read_input_tokens"]
          usage_data[:cache_read_input_tokens] = usage["cache_read_input_tokens"]
        end
        if usage["cache_creation_input_tokens"]
          usage_data[:cache_creation_input_tokens] = usage["cache_creation_input_tokens"]
        end

        {
          content: content,
          tool_calls: tool_calls,
          finish_reason: finish_reason,
          usage: usage_data,
          raw_api_usage: usage
        }
      else
        raise_error(response)
      end
    end

    # Handle simple Anthropic response (without tool calls)
    def handle_anthropic_simple_response(response)
      case response.status
      when 200
        data = JSON.parse(response.body)
        content_blocks = data["content"] || []

        # Extract and return text content only (simple format, consistent with OpenAI)
        content_blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("")
      else
        raise_error(response)
      end
    end

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

    # Connection for OpenAI API format (uses Bearer token)
    def openai_connection
      @openai_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"] = "application/json"
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.options.timeout = 120
        conn.options.open_timeout = 10
        conn.adapter Faraday.default_adapter
      end
    end

    # Connection for Anthropic API format (uses x-api-key header)
    def anthropic_connection
      @anthropic_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"] = "application/json"
        conn.headers["x-api-key"] = @api_key
        conn.headers["anthropic-version"] = "2023-06-01"
        conn.headers["anthropic-dangerous-direct-browser-access"] = "true"
        conn.options.timeout = 120
        conn.options.open_timeout = 10
        conn.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      case response.status
      when 200
        data = JSON.parse(response.body)
        data["choices"].first["message"]["content"]
      else
        raise_error(response)
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
      else
        raise_error(response)
      end
    end

    private

    def raise_error(response)
      # Try to parse error body as JSON for better error messages
      error_body = begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        nil
      end

      # Extract meaningful error message from response
      error_message = extract_error_message(error_body, response.body)

      case response.status
      when 400
        # Bad request - could be invalid model, quota exceeded, etc.
        hint = if error_message.downcase.include?("unavailable") || error_message.downcase.include?("quota")
          " (possibly out of credits)"
        else
          ""
        end
        raise AgentError, "API request failed (400): #{error_message}#{hint}"
      when 401
        raise AgentError, "Invalid API key"
      when 403
        raise AgentError, "Access denied: #{error_message}"
      when 404
        raise AgentError, "API endpoint not found: #{error_message}"
      when 429
        raise AgentError, "Rate limit exceeded"
      when 500..599
        raise AgentError, "Server error (#{response.status}): #{error_message}"
      else
        raise AgentError, "Unexpected error (#{response.status}): #{error_message}"
      end
    end

    # Extract the most meaningful error message from API response
    private def extract_error_message(error_body, raw_body)
      return raw_body unless error_body.is_a?(Hash)

      # Priority order for error messages:
      # 1. upstreamMessage (often contains the real reason)
      # 2. error.message (Anthropic format)
      # 3. message
      # 4. error (string)
      # 5. raw body
      if error_body["upstreamMessage"] && !error_body["upstreamMessage"].empty?
        error_body["upstreamMessage"]
      elsif error_body.dig("error", "message")
        error_body.dig("error", "message")
      elsif error_body["message"]
        error_body["message"]
      elsif error_body["error"].is_a?(String)
        error_body["error"]
      else
        raw_body
      end
    end

    def parse_tool_calls(tool_calls)
      return nil if tool_calls.nil? || tool_calls.empty?

      tool_calls.map do |call|
        # Handle cases where function might be nil or missing
        function_data = call["function"] || {}

        {
          id: call["id"],
          type: call["type"],
          name: function_data["name"],
          arguments: function_data["arguments"]
        }
      end
    end
  end
end
