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
      # Detect Bedrock API key by ABSK prefix — overrides anthropic_format routing
      @use_bedrock = MessageFormat::Bedrock.bedrock_api_key?(api_key)
    end

    # Returns true when the client is using the AWS Bedrock Converse API.
    def bedrock?
      @use_bedrock
    end

    # Returns true when the client is talking directly to the Anthropic API
    # (determined at construction time via the anthropic_format flag).
    def anthropic_format?(model = nil)
      @use_anthropic_format && !@use_bedrock
    end

    # ── Connection test ───────────────────────────────────────────────────────

    # Test API connection by sending a minimal request.
    # Returns { success: true } or { success: false, error: "..." }.
    def test_connection(model:)
      if bedrock?
        body = MessageFormat::Bedrock.build_request_body(
          [{ role: :user, content: "hi" }], model, [], 16
        ).to_json
        response = bedrock_connection.post(bedrock_endpoint(model)) { |r| r.body = body }
      elsif anthropic_format?
        minimal_body = { model: model, max_tokens: 16,
                         messages: [{ role: "user", content: "hi" }] }.to_json
        response = anthropic_connection.post("v1/messages") { |r| r.body = minimal_body }
      else
        minimal_body = { model: model, max_tokens: 16,
                         messages: [{ role: "user", content: "hi" }] }.to_json
        response = openai_connection.post("chat/completions") { |r| r.body = minimal_body }
      end
      handle_test_response(response)
    rescue Faraday::Error => e
      { success: false, error: "Connection error: #{e.message}" }
    rescue => e
      { success: false, error: e.message }
    end

    # ── Simple (non-agent) helpers ────────────────────────────────────────────

    # Send a single string message and return the reply text.
    def send_message(content, model:, max_tokens:)
      messages = [{ role: "user", content: content }]
      send_messages(messages, model: model, max_tokens: max_tokens)
    end

    # Send a messages array and return the reply text.
    def send_messages(messages, model:, max_tokens:)
      if bedrock?
        body     = MessageFormat::Bedrock.build_request_body(messages, model, [], max_tokens)
        response = bedrock_connection.post(bedrock_endpoint(model)) { |r| r.body = body.to_json }
        parse_simple_bedrock_response(response)
      elsif anthropic_format?
        body     = MessageFormat::Anthropic.build_request_body(messages, model, [], max_tokens, false)
        response = anthropic_connection.post("v1/messages") { |r| r.body = body.to_json }
        parse_simple_anthropic_response(response)
      else
        body     = { model: model, max_tokens: max_tokens, messages: messages }
        response = openai_connection.post("chat/completions") { |r| r.body = body.to_json }
        parse_simple_openai_response(response)
      end
    end

    # ── Agent main path ───────────────────────────────────────────────────────

    # Send messages with tool-calling support.
    # Returns canonical response hash: { content:, tool_calls:, finish_reason:, usage: }
    def send_messages_with_tools(messages, model:, tools:, max_tokens:, enable_caching: false)
      caching_enabled = enable_caching && supports_prompt_caching?(model)
      cloned = deep_clone(messages)

      if bedrock?
        send_bedrock_request(cloned, model, tools, max_tokens)
      elsif anthropic_format?
        send_anthropic_request(cloned, model, tools, max_tokens, caching_enabled)
      else
        send_openai_request(cloned, model, tools, max_tokens, caching_enabled)
      end
    end

    # Format tool results into canonical messages ready to append to @messages.
    # Always returns canonical format (role: "tool") regardless of API type —
    # conversion to API-native happens inside each send_*_request.
    def format_tool_results(response, tool_results, model:)
      return [] if tool_results.empty?

      if bedrock?
        MessageFormat::Bedrock.format_tool_results(response, tool_results)
      elsif anthropic_format?
        MessageFormat::Anthropic.format_tool_results(response, tool_results)
      else
        MessageFormat::OpenAI.format_tool_results(response, tool_results)
      end
    end

    # ── Prompt-caching support ────────────────────────────────────────────────

    # Returns true for Claude 3.5+ models that support prompt caching.
    def supports_prompt_caching?(model)
      model_str = model.to_s.downcase
      return false unless model_str.include?("claude")

      model_str.match?(/claude(?:-3[-.]?[5-9]|-[4-9]|-sonnet-[34])/)
    end


    # ── Bedrock Converse request / response ───────────────────────────────────

    def send_bedrock_request(messages, model, tools, max_tokens)
      body     = MessageFormat::Bedrock.build_request_body(messages, model, tools, max_tokens)
      response = bedrock_connection.post(bedrock_endpoint(model)) { |r| r.body = body.to_json }

      raise_error(response) unless response.status == 200
      check_html_response(response)
      MessageFormat::Bedrock.parse_response(JSON.parse(response.body))
    end

    def parse_simple_bedrock_response(response)
      raise_error(response) unless response.status == 200
      data = JSON.parse(response.body)
      (data.dig("output", "message", "content") || [])
        .select { |b| b["text"] }
        .map { |b| b["text"] }
        .join("")
    end

    # ── Anthropic request / response ──────────────────────────────────────────

    def send_anthropic_request(messages, model, tools, max_tokens, caching_enabled)
      # Apply cache_control to the message that marks the cache breakpoint
      messages = apply_message_caching(messages) if caching_enabled

      body     = MessageFormat::Anthropic.build_request_body(messages, model, tools, max_tokens, caching_enabled)
      response = anthropic_connection.post("v1/messages") { |r| r.body = body.to_json }

      raise_error(response) unless response.status == 200
      check_html_response(response)
      MessageFormat::Anthropic.parse_response(JSON.parse(response.body))
    end

    def parse_simple_anthropic_response(response)
      raise_error(response) unless response.status == 200
      data = JSON.parse(response.body)
      (data["content"] || []).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("")
    end

    # ── OpenAI request / response ─────────────────────────────────────────────

    def send_openai_request(messages, model, tools, max_tokens, caching_enabled)
      # Apply cache_control markers to messages when caching is enabled.
      # OpenRouter proxies Claude with the same cache_control field convention as Anthropic direct.
      messages = apply_message_caching(messages) if caching_enabled

      body     = MessageFormat::OpenAI.build_request_body(messages, model, tools, max_tokens, caching_enabled)
      response = openai_connection.post("chat/completions") { |r| r.body = body.to_json }

      raise_error(response) unless response.status == 200
      check_html_response(response)
      MessageFormat::OpenAI.parse_response(JSON.parse(response.body))
    end

    def parse_simple_openai_response(response)
      raise_error(response) unless response.status == 200
      JSON.parse(response.body)["choices"].first["message"]["content"]
    end

    # ── Prompt caching helpers ────────────────────────────────────────────────

    # Add cache_control markers to the last 2 messages in the array.
    #
    # Why 2 markers:
    #   Turn N   — marks messages[-2] and messages[-1]; server caches prefix up to [-1]
    #   Turn N+1 — messages[-2] is Turn N's last message (still marked) → cache READ hit;
    #              messages[-1] is the new message (marked) → cache WRITE for Turn N+2
    #
    # With only 1 marker (old behavior): Turn N marks messages[-1]; in Turn N+1 that same
    # message is now [-2] and carries no marker → server sees a different prefix → cache MISS.
    #
    # Compression instructions (system_injected: true) are skipped — we never want to cache
    # those ephemeral injection messages.
    def apply_message_caching(messages)
      return messages if messages.empty?

      # Collect up to 2 candidate indices from the tail, skipping compression instructions.
      candidate_indices = []
      (messages.length - 1).downto(0) do |i|
        break if candidate_indices.length >= 2

        candidate_indices << i unless is_compression_instruction?(messages[i])
      end

      messages.map.with_index do |msg, idx|
        candidate_indices.include?(idx) ? add_cache_control_to_message(msg) : msg
      end
    end

    # Wrap or extend the message's content with a cache_control marker.
    def add_cache_control_to_message(msg)
      content = msg[:content]

      content_array = case content
                      when String
                        [{ type: "text", text: content, cache_control: { type: "ephemeral" } }]
                      when Array
                        content.map.with_index do |block, idx|
                          idx == content.length - 1 ? block.merge(cache_control: { type: "ephemeral" }) : block
                        end
                      else
                        return msg
                      end

      msg.merge(content: content_array)
    end

    def is_compression_instruction?(message)
      message.is_a?(Hash) && message[:system_injected] == true
    end

    # ── HTTP connections ──────────────────────────────────────────────────────

    # Bedrock Converse API endpoint path for a given model ID.
    def bedrock_endpoint(model)
      "/model/#{model}/converse"
    end

    def bedrock_connection
      @bedrock_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"]  = "application/json"
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.options.timeout      = 120
        conn.options.open_timeout = 10
        conn.ssl.verify           = false
        conn.adapter Faraday.default_adapter
      end
    end

    def openai_connection
      @openai_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"]  = "application/json"
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.options.timeout      = 120
        conn.options.open_timeout = 10
        conn.ssl.verify           = false
        conn.adapter Faraday.default_adapter
      end
    end

    def anthropic_connection
      @anthropic_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"]   = "application/json"
        conn.headers["x-api-key"]      = @api_key
        conn.headers["anthropic-version"] = "2023-06-01"
        conn.headers["anthropic-dangerous-direct-browser-access"] = "true"
        conn.options.timeout      = 120
        conn.options.open_timeout = 10
        conn.ssl.verify           = false
        conn.adapter Faraday.default_adapter
      end
    end

    # ── Error handling ────────────────────────────────────────────────────────

    def handle_test_response(response)
      return { success: true } if response.status == 200

      error_body = JSON.parse(response.body) rescue nil
      { success: false, error: extract_error_message(error_body, response.body) }
    end

    def raise_error(response)
      error_body    = JSON.parse(response.body) rescue nil
      error_message = extract_error_message(error_body, response.body)

      case response.status
      when 400
        hint = error_message.downcase.match?(/unavailable|quota/) ? " (possibly out of credits)" : ""
        raise AgentError, "API request failed (400): #{error_message}#{hint}"
      when 401 then raise AgentError, "Invalid API key"
      when 403 then raise AgentError, "Access denied: #{error_message}"
      when 404 then raise AgentError, "API endpoint not found: #{error_message}"
      when 429 then raise RetryableError, "Rate limit exceeded, please wait a moment"
      when 500..599 then raise RetryableError, "LLM service temporarily unavailable (#{response.status}), retrying..."
      else raise AgentError, "Unexpected error (#{response.status}): #{error_message}"
      end
    end

    # Raise a friendly error if the response body is HTML (e.g. gateway error page returned with 200)
    def check_html_response(response)
      body = response.body.to_s.lstrip
      if body.start_with?("<!DOCTYPE", "<!doctype", "<html", "<HTML")
        raise RetryableError, "LLM service temporarily unavailable (received HTML error page), retrying..."
      end
    end

    def extract_error_message(error_body, raw_body)
      if raw_body.is_a?(String) && raw_body.strip.start_with?("<!DOCTYPE", "<html")
        return "Invalid API endpoint or server error (received HTML instead of JSON)"
      end

      return raw_body unless error_body.is_a?(Hash)

      error_body["upstreamMessage"]&.then { |m| return m unless m.empty? }
      error_body.dig("error", "message")&.then { |m| return m }
      error_body["message"]&.then             { |m| return m }
      error_body["error"].is_a?(String) ? error_body["error"] : (raw_body.to_s[0..200] + (raw_body.to_s.length > 200 ? "..." : ""))
    end

    # ── Utilities ─────────────────────────────────────────────────────────────

    def deep_clone(obj)
      case obj
      when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_clone(v) }
      when Array then obj.map { |item| deep_clone(item) }
      else obj
      end
    end
  end
end
