# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  # DeployApiClient - Encapsulates all Deploy API calls for the Railway deployment flow.
  #
  # All endpoints use Workspace API Key (clacky_ak_*) authentication, as the backend
  # supports both clacky_ak_* and clacky_dk_* for all deploy endpoints.
  #
  # Usage:
  #   client = DeployApiClient.new("clacky_ak_xxx", base_url: "https://api.clacky.ai")
  #
  #   # Check payment status
  #   result = client.payment_status(project_id: "proj_abc")
  #   # => { success: true, is_paid: true }
  #
  #   # Create a deploy task
  #   result = client.create_task(project_id: "proj_abc")
  #   # => { success: true, deploy_task_id: "...", platform_token: "...", ... }
  #
  #   # Poll services until DB is ready
  #   result = client.services(deploy_task_id: "task_abc")
  #   # => { success: true, services: [...], domain_name: "..." }
  #
  #   # Poll deploy status
  #   result = client.deploy_status(deploy_task_id: "task_abc")
  #   # => { success: true, status: "SUCCESS", url: "https://..." }
  #
  #   # Bind domain
  #   result = client.bind_domain(deploy_task_id: "task_abc")
  #   # => { success: true, domain: "my-app.example.com" }
  #
  #   # Notify backend of deploy outcome
  #   client.notify(project_id: "...", deploy_task_id: "...", status: "success")
  class DeployApiClient
    BASE_PATH        = "/openclacky/v1"
    REQUEST_TIMEOUT  = 30   # seconds for normal requests
    OPEN_TIMEOUT     = 10   # seconds for connection

    def initialize(workspace_key, base_url:)
      @workspace_key = workspace_key.to_s.strip
      @base_url      = base_url.to_s.strip.sub(%r{/+$}, "")
    end

    # -------------------------------------------------------------------------
    # Payment
    # -------------------------------------------------------------------------

    # Query whether the project has an active paid subscription.
    #
    # @param project_id [String]
    # @return [Hash] { success: true, is_paid: Boolean } or { success: false, error: String }
    def payment_status(project_id:)
      response = connection.get("#{BASE_PATH}/deploy/payment") do |req|
        req.params["project_id"] = project_id
      end

      return http_error(response) unless response.status == 200

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      data = body["data"] || {}
      { success: true, is_paid: data["is_paid"] == true }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # -------------------------------------------------------------------------
    # Regions
    # -------------------------------------------------------------------------

    # Fetch the list of supported deployment regions.
    #
    # @param project_id [String] Required by the backend to scope region availability.
    # @return [Hash] {
    #   success: true,
    #   regions: Array<Hash>  # e.g. [{ "id" => "us-west", "name" => "US West", "label" => "US West (Oregon)" }, ...]
    # } or { success: false, error: String }
    def regions(project_id:)
      response = connection.get("#{BASE_PATH}/deploy/regions") do |req|
        req.params["project_id"] = project_id
      end

      return http_error(response) unless response.status == 200

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      data = body["data"] || {}
      list = data["regions"] || data || []
      list = list.values if list.is_a?(Hash)
      { success: true, regions: Array(list) }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # -------------------------------------------------------------------------
    # Create Deploy Task
    # -------------------------------------------------------------------------

    # Create a new deployment task on the backend. Returns Railway credentials.
    #
    # @param project_id [String]
    # @param backup_db  [Boolean] default false
    # @param env_vars   [Hash]    extra env vars to pass at task creation time
    # @param region     [String]  optional Railway region slug
    # @return [Hash] {
    #   success: true,
    #   deploy_task_id:         String,
    #   deploy_service_id:      String,
    #   platform_token:         String,   # RAILWAY_TOKEN
    #   platform_project_id:    String,
    #   platform_environment_id: String
    # }
    def create_task(project_id:, backup_db: false, env_vars: {}, region: nil)
      body_params = { project_id: project_id, backup_db: backup_db }
      body_params[:env_vars] = env_vars unless env_vars.empty?
      body_params[:region]   = region   if region

      response = connection.post("#{BASE_PATH}/deploy/create-task") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(body_params)
      end

      return http_error(response) unless response.status == 200

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      data = body["data"] || {}
      {
        success:                 true,
        deploy_task_id:          data["deploy_task_id"],
        deploy_service_id:       data["deploy_service_id"],
        platform_token:          data["platform_token"],
        platform_project_id:     data["platform_project_id"],
        platform_environment_id: data["platform_environment_id"]
      }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # -------------------------------------------------------------------------
    # Services (poll for middleware readiness)
    # -------------------------------------------------------------------------

    # Query all services under a deploy task.
    # Used to wait for the PostgreSQL middleware to reach status SUCCESS
    # before injecting the DATABASE_URL reference.
    #
    # @param deploy_task_id [String]
    # @return [Hash] {
    #   success: true,
    #   services:    Array<Hash>,   # full service objects from API
    #   domain_name: String,        # assigned domain (may be empty on first call)
    #   db_service:  Hash | nil     # first middleware service with status SUCCESS
    # }
    def services(deploy_task_id:)
      response = connection.get("#{BASE_PATH}/deploy/services") do |req|
        req.params["deploy_task_id"] = deploy_task_id
      end

      return http_error(response) unless response.status == 200

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      data     = body["data"] || {}
      svcs     = data["services"] || []
      domain   = data["domain_name"].to_s

      # Find first middleware (DB) that is fully provisioned
      db_svc = svcs.find do |s|
        s["type"] == "middleware" && s["status"]&.upcase == "SUCCESS"
      end

      # middleware_support: { supported: Boolean, supported_types: Array }
      # When supported == false, no DB middleware will be provisioned by Clacky.
      # The deploy script uses this to skip the DB polling loop entirely.
      middleware_support = data["middleware_support"] || {}

      # platform_bucket_credentials contains S3-compatible storage credentials.
      # Passed through so the deploy script can inject STORAGE_BUCKET_* env vars.
      bucket_credentials = data["platform_bucket_credentials"]
      bucket_name        = data["platform_bucket_name"].to_s

      {
        success:              true,
        services:             svcs,
        domain_name:          domain,
        db_service:           db_svc,
        middleware_support:   middleware_support,
        bucket_credentials:   bucket_credentials,
        bucket_name:          bucket_name
      }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # -------------------------------------------------------------------------
    # Deploy Status
    # -------------------------------------------------------------------------

    # Query the real-time deployment status for a task.
    #
    # @param deploy_task_id [String]
    # @return [Hash] {
    #   success: true,
    #   status:  String,   # SUCCESS / FAILED / CRASHED / DEPLOYING / WAITING
    #   url:     String
    # }
    def deploy_status(deploy_task_id:)
      response = connection.get("#{BASE_PATH}/deploy/status") do |req|
        req.params["deploy_task_id"] = deploy_task_id
      end

      return http_error(response) unless response.status == 200

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      data = body["data"] || {}
      {
        success: true,
        status:  data["status"].to_s.upcase,
        url:     data["url"].to_s,
        deploy_service_id: data["deploy_service_id"].to_s
      }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # -------------------------------------------------------------------------
    # Bind Domain
    # -------------------------------------------------------------------------

    # Bind a custom domain to the deploy task.
    #
    # @param deploy_task_id [String]
    # @return [Hash] { success: true, domain: String } or { success: false, error: String }
    def bind_domain(deploy_task_id:)
      response = connection.post("#{BASE_PATH}/deploy/bind-domain") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate({ deploy_task_id: deploy_task_id })
      end

      return http_error(response) unless response.status == 200

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      data = body["data"] || {}
      { success: true, domain: data["domain"].to_s }
    rescue Faraday::Error => e
      { success: false, error: "Network error: #{e.message}" }
    rescue => e
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # -------------------------------------------------------------------------
    # Notify
    # -------------------------------------------------------------------------

    # Notify the backend of the current deployment outcome.
    # Fire-and-forget — failures are logged but do not raise.
    #
    # @param project_id        [String]
    # @param deploy_task_id    [String]
    # @param deploy_service_id [String] optional
    # @param status            [String] "deploying" | "success" | "failed"
    # @param message           [String] optional description
    # @param target_port       [Integer] default 3000
    # @return [Hash] { success: true } or { success: false, error: String }
    def notify(project_id:, deploy_task_id:, status:,
               deploy_service_id: nil, message: nil, target_port: nil)
      payload = {
        project_id:     project_id,
        deploy_task_id: deploy_task_id,
        status:         status
      }
      payload[:deploy_service_id] = deploy_service_id if deploy_service_id
      payload[:message]           = message           if message
      payload[:target_port]       = target_port       if target_port

      response = connection.post("#{BASE_PATH}/deploy/notify") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(payload)
      end

      return http_error(response) unless response.status == 200

      body = parse_body(response)
      return body_error(body) unless success_code?(body)

      { success: true }
    rescue => e
      # Notify failures are non-fatal — log and move on
      warn "[deploy_api] notify failed: #{e.message}"
      { success: false, error: e.message }
    end

    # -------------------------------------------------------------------------
    # Private helpers
    # -------------------------------------------------------------------------

    private def connection
      @connection ||= Faraday.new(url: @base_url) do |f|
        f.options.timeout      = REQUEST_TIMEOUT
        f.options.open_timeout = OPEN_TIMEOUT
        f.headers["Authorization"] = "Bearer #{@workspace_key}"
        f.headers["Accept"]        = "application/json"
        # Disable SSL verification to avoid OpenSSL certificate path issues
        # on some macOS environments with system Ruby
        f.ssl.verify = false
        f.adapter Faraday.default_adapter
      end
    end

    private def parse_body(response)
      JSON.parse(response.body)
    rescue JSON::ParserError
      nil
    end

    private def success_code?(body)
      return false if body.nil?

      code = body["code"].to_i
      code == 0 || code == 200
    end

    private def http_error(response)
      msg = begin
        parsed = JSON.parse(response.body)
        parsed["message"] || parsed["msg"] || response.body.to_s[0, 200]
      rescue
        response.body.to_s[0, 200]
      end
      { success: false, error: "HTTP #{response.status}: #{msg}" }
    end

    private def body_error(body)
      return { success: false, error: "Invalid JSON response from API" } if body.nil?

      msg = body["message"] || body["msg"] || "Unknown API error (code: #{body["code"]})"
      { success: false, error: msg }
    end
  end
end
