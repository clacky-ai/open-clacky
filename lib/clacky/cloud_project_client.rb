# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  # CloudProjectClient - Manages cloud project lifecycle via the OpenClacky API
  #
  # Handles creating projects, fetching project details (including subscription
  # status and categorized_config), and listing projects in a workspace.
  #
  # All API calls use the Workspace API Key (clacky_ak_*) from PlatformConfig.
  #
  # Usage:
  #   client = CloudProjectClient.new("clacky_ak_xxx", base_url: "https://api.clacky.ai")
  #
  #   # Create a new cloud project
  #   result = client.create_project(name: "my-app")
  #   # => { success: true, project: { "id" => "...", "name" => "...", "workspace_id" => "...",
  #   #        "categorized_config" => { "auth" => {...}, "email" => {...}, ... } } }
  #
  #   # Get project details (subscription + categorized_config)
  #   result = client.get_project("019d41be-...")
  #   # => { success: true, project: { "id" => "...", "subscription" => { "status" => "PAID" }, ... } }
  #
  #   # List all projects in workspace
  #   result = client.list_projects
  #   # => { success: true, projects: [ { "id" => "...", "name" => "..." }, ... ] }
  #
  # On failure, all methods return: { success: false, error: "..." }
  class CloudProjectClient
    PROJECTS_PATH       = "/openclacky/v1/projects"
    REQUEST_TIMEOUT     = 15  # seconds
    OPEN_TIMEOUT        = 5   # seconds

    def initialize(workspace_api_key, base_url:)
      @workspace_api_key = workspace_api_key.to_s.strip
      @base_url          = base_url.to_s.strip.sub(%r{/+$}, "")
    end

    # Create a new cloud project with the given name.
    #
    # @param name [String] Project name (typically the local directory name)
    # @return [Hash] { success: true, project: {...} } or { success: false, error: "..." }
    def create_project(name:)
      validate_inputs!

      response = connection.post(PROJECTS_PATH) do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate({ name: name.to_s.strip })
      end

      unless response.status == 200
        error_msg = extract_error(response)
        return { success: false, error: "HTTP #{response.status}: #{error_msg}" }
      end

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      { success: true, project: body["data"] }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # Get project details including subscription status and categorized_config.
    #
    # @param project_id [String] The cloud project UUID
    # @return [Hash] { success: true, project: {...} } or { success: false, error: "..." }
    def get_project(project_id)
      validate_inputs!

      response = connection.get("#{PROJECTS_PATH}/#{project_id}")

      unless response.status == 200
        error_msg = extract_error(response)
        return { success: false, error: "HTTP #{response.status}: #{error_msg}" }
      end

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      { success: true, project: body["data"] }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # List all projects in the current workspace.
    #
    # @return [Hash] { success: true, projects: [...] } or { success: false, error: "..." }
    def list_projects
      validate_inputs!

      response = connection.get(PROJECTS_PATH)

      unless response.status == 200
        error_msg = extract_error(response)
        return { success: false, error: "HTTP #{response.status}: #{error_msg}" }
      end

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      projects = body["data"] || []
      projects = projects["list"] if projects.is_a?(Hash) && projects["list"]

      { success: true, projects: Array(projects) }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    private def validate_inputs!
      raise ArgumentError, "workspace_api_key is required" if @workspace_api_key.empty?
      raise ArgumentError, "base_url is required"          if @base_url.empty?
    end

    private def connection
      @connection ||= Faraday.new(url: @base_url) do |f|
        f.options.timeout      = REQUEST_TIMEOUT
        f.options.open_timeout = OPEN_TIMEOUT
        f.headers["Authorization"] = "Bearer #{@workspace_api_key}"
        f.headers["Accept"]        = "application/json"
        f.adapter Faraday.default_adapter
      end
    end

    # Parse JSON response body.
    # Returns the parsed Hash on success, or nil if the body is not valid JSON.
    private def parse_body(response)
      JSON.parse(response.body)
    rescue JSON::ParserError
      nil
    end

    # The API returns code 0 or 200 to signal success.
    # Returns false if body is nil (unparseable JSON).
    private def success_code?(body)
      return false if body.nil?

      code = body["code"].to_i
      code == 0 || code == 200
    end

    # Build a failure hash from a parsed response body (may be nil for non-JSON)
    private def body_error(body)
      return { success: false, error: "Invalid JSON response from API" } if body.nil?

      msg = body["message"] || "Unknown API error (code: #{body["code"]})"
      { success: false, error: msg }
    end

    # Extract a human-readable error string from a raw Faraday response
    private def extract_error(response)
      parsed = JSON.parse(response.body)
      parsed["message"] || response.body.to_s[0, 200]
    rescue
      response.body.to_s[0, 200]
    end
  end
end
