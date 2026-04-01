# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  # ClackyAuthClient - Fetches LLM keys from a Clacky workspace via API
  #
  # Usage:
  #   client = ClackyAuthClient.new("clacky_ak_xxx", base_url: "https://api.example.com")
  #   result = client.fetch_workspace_keys
  #   # => { success: true, llm_key: "ABSK...", model_name: "jp.anthropic.claude-sonnet-4-6",
  #   #      base_url: "https://...", anthropic_format: false }
  class ClackyAuthClient
    WORKSPACE_KEYS_PATH = "/openclacky/v1/workspace/keys"
    REQUEST_TIMEOUT     = 15   # seconds
    OPEN_TIMEOUT        = 5    # seconds

    # Default model to use when the workspace/keys response does not specify one
    DEFAULT_MODEL = "jp.anthropic.claude-sonnet-4-6"

    def initialize(workspace_api_key, base_url:)
      @workspace_api_key = workspace_api_key.to_s.strip
      @base_url          = base_url.to_s.strip.sub(%r{/+$}, "")
    end

    # Fetch workspace keys from the Clacky backend.
    #
    # @return [Hash]
    #   On success:
    #     { success: true,
    #       llm_key: "...",          # raw LLM key string returned by the API (ABSK prefix = Bedrock)
    #       model_name: "...",       # model to configure (provider default or our default)
    #       base_url: "...",         # LLM proxy base URL (clean host, no path suffix)
    #       anthropic_format: false  # ABSK keys use Bedrock Converse format, not Anthropic wire format
    #     }
    #   On failure:
    #     { success: false, error: "..." }
    def fetch_workspace_keys
      validate_inputs!

      response = connection.get(WORKSPACE_KEYS_PATH)

      unless response.status == 200
        error_msg = extract_error(response)
        return { success: false, error: "HTTP #{response.status}: #{error_msg}" }
      end

      body = JSON.parse(response.body)

      unless body["code"].to_i == 200
        return { success: false, error: "API error: #{body["msg"] || body["message"]}" }
      end

      llm_key_data = body.dig("data", "llm_key")
      if llm_key_data.nil?
        return { success: false, error: "No LLM key available for this workspace" }
      end

      # Extract key value – the API returns a hash with fields:
      #   raw_key  – plaintext secret (primary field since 2026-03-30)
      #   key      – alias used by some gateway endpoints
      #   key_id   – legacy identifier (kept for forward-compat)
      # Priority: raw_key > key > key_id > value
      # We also accept a plain string form for forward-compat.
      llm_key = case llm_key_data
                when String then llm_key_data
                when Hash
                  llm_key_data["raw_key"] || llm_key_data["key"] ||
                    llm_key_data["key_id"] || llm_key_data["value"]
                end

      if llm_key.nil? || llm_key.to_s.strip.empty?
        return { success: false, error: "LLM key value is empty or missing in response" }
      end

      # base_url comes from the `host` field in the API response (set per environment by backend config).
      # Fallback to @base_url (the backend URL the user entered).
      # No path suffix is appended — the LLM key has ABSK prefix (Bedrock), so client.rb will
      # automatically build the correct endpoint: /model/{model}/converse
      host = llm_key_data.is_a?(Hash) ? llm_key_data["host"].to_s.strip : ""
      llm_base_url = if host.start_with?("http://", "https://")
                       host
                     else
                       @base_url
                     end

      {
        success:          true,
        llm_key:          llm_key.to_s.strip,
        model_name:       DEFAULT_MODEL,
        base_url:         llm_base_url,
        anthropic_format: false
      }
    rescue Faraday::ConnectionFailed => e
      { success: false, error: "Connection failed: #{e.message}" }
    rescue Faraday::TimeoutError
      { success: false, error: "Request timed out (#{REQUEST_TIMEOUT}s)" }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue JSON::ParserError => e
      { success: false, error: "Invalid JSON response: #{e.message}" }
    rescue ArgumentError => e
      { success: false, error: e.message }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    private

    # Validate that inputs look reasonable before making a network request.
    def validate_inputs!
      if @workspace_api_key.empty?
        raise ArgumentError, "Workspace API key is required"
      end

      unless @workspace_api_key.start_with?("clacky_ak_")
        raise ArgumentError, "Invalid key format (expected prefix: clacky_ak_)"
      end

      if @base_url.empty?
        raise ArgumentError, "Base URL is required"
      end

      unless @base_url.start_with?("http://", "https://")
        raise ArgumentError, "Base URL must start with http:// or https://"
      end
    end

    # Build a Faraday connection pointing at the Clacky backend.
    def connection
      @connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"]  = "application/json"
        conn.headers["Authorization"] = "Bearer #{@workspace_api_key}"
        conn.options.timeout          = REQUEST_TIMEOUT
        conn.options.open_timeout     = OPEN_TIMEOUT
        conn.ssl.verify               = false
        conn.adapter Faraday.default_adapter
      end
    end

    # Extract a human-readable error from a failed response.
    def extract_error(response)
      body = JSON.parse(response.body) rescue nil
      return response.body.to_s[0..200] unless body.is_a?(Hash)

      body["msg"] ||
        body["message"] ||
        body.dig("error", "message") ||
        body["error"].to_s[0..200] ||
        response.body.to_s[0..200]
    end
  end
end
