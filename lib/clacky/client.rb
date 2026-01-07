# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  class Client
    def initialize(api_key, base_url: "https://api.openai.com")
      @api_key = api_key
      @base_url = base_url
    end

    def send_message(content, model: "gpt-3.5-turbo", max_tokens: 4096)
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

    def send_messages(messages, model: "gpt-3.5-turbo", max_tokens: 4096)
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
    def send_messages_with_tools(messages, model: "gpt-3.5-turbo", tools: nil, max_tokens: 4096, verbose: false)
      body = {
        model: model,
        max_tokens: max_tokens,
        messages: messages
      }

      # Add tools if provided
      body[:tools] = tools if tools&.any?

      # Debug output
      if verbose || ENV["CLACKY_DEBUG"]
        puts "\n[DEBUG] Current directory: #{Dir.pwd}"
        puts "[DEBUG] Request to API:"

        # Create a simplified version of the body for display
        display_body = body.dup
        if display_body[:tools]&.any?
          tool_names = display_body[:tools].map { |t| t.dig(:function, :name) }.compact
          display_body[:tools] = "use tools: #{tool_names.join(', ')}"
        end

        puts JSON.pretty_generate(display_body)
      end

      response = connection.post("chat/completions") do |req|
        req.body = body.to_json
      end

      handle_tool_response(response)
    end

    private

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

        # Debug: show raw API response content
        if ENV["CLACKY_DEBUG"]
          puts "\n[DEBUG] Raw API response content:"
          puts "  content: #{message["content"].inspect}"
          puts "  content length: #{message["content"]&.length || 0}"
        end

        {
          content: message["content"],
          tool_calls: parse_tool_calls(message["tool_calls"]),
          finish_reason: data["choices"].first["finish_reason"],
          usage: {
            prompt_tokens: usage["prompt_tokens"],
            completion_tokens: usage["completion_tokens"],
            total_tokens: usage["total_tokens"]
          }
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
