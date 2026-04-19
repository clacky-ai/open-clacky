# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Clacky
  # PlatformHttpClient provides a resilient HTTP client for all calls to the
  # OpenClacky platform API (www.openclacky.com and its fallback domain).
  #
  # Features:
  #   - Automatic retry with exponential back-off on transient failures
  #   - Transparent domain failover: if the primary domain times out or returns a
  #     5xx error, the request is automatically retried against the fallback domain
  #   - Override via CLACKY_LICENSE_SERVER env var (used in development)
  #
  # Usage:
  #   client = Clacky::PlatformHttpClient.new
  #   result = client.post("/api/v1/licenses/activate", payload)
  #   # result => { success: true, data: {...} }
  #   #        or { success: false, error: "...", data: {} }
  class PlatformHttpClient
    # Primary CDN-accelerated endpoint
    PRIMARY_HOST  = "https://www.openclacky.com"
    # Direct fallback — bypasses EdgeOne, used when the primary times out
    FALLBACK_HOST = "https://openclacky.up.railway.app"

    # Number of attempts per domain (1 = no retry within the same domain)
    ATTEMPTS_PER_HOST = 2
    # Initial back-off between retries within the same domain (seconds)
    INITIAL_BACKOFF   = 0.5
    # Connection / read timeouts (seconds)
    OPEN_TIMEOUT  = 8
    READ_TIMEOUT  = 15

    # API error code → human-readable message table (shared across all callers)
    API_ERROR_MESSAGES = {
      "invalid_proof"        => "Invalid license key — please check and try again.",
      "invalid_signature"    => "Invalid request signature.",
      "nonce_replayed"       => "Duplicate request detected. Please try again.",
      "timestamp_expired"    => "System clock is out of sync. Please adjust your time settings.",
      "license_revoked"      => "This license has been revoked. Please contact support.",
      "license_expired"      => "This license has expired. Please renew to continue.",
      "device_limit_reached" => "Device limit reached for this license.",
      "device_revoked"       => "This device has been revoked from the license.",
      "invalid_license"      => "License key not found. Please verify the key.",
      "device_not_found"     => "Device not registered. Please re-activate."
    }.freeze

    # @param base_url [String, nil]  Override the primary host (e.g. for local dev).
    #   When set, the fallback domain is disabled — only the override URL is used.
    def initialize(base_url: nil)
      if base_url
        # Developer / test override: single host, no failover
        @hosts   = [base_url]
      else
        @hosts = [PRIMARY_HOST, FALLBACK_HOST]
      end
    end

    # Send a POST request with a JSON body and return a normalised result hash.
    #
    # @param path    [String]  API path, e.g. "/api/v1/licenses/activate"
    # @param payload [Hash]    Request body (will be JSON-encoded)
    # @param headers [Hash]    Additional HTTP headers (optional)
    # @return [Hash]  { success: Boolean, data: Hash, error: String }
    def post(path, payload, headers: {})
      request_with_failover(:post, path, payload, headers)
    end

    # Send a GET request and return a normalised result hash.
    # Query string parameters should be appended to path by the caller.
    #
    # @param path    [String]  API path with optional query string
    # @param headers [Hash]    Additional HTTP headers (optional)
    # @return [Hash]  { success: Boolean, data: Hash, error: String }
    def get(path, headers: {})
      request_with_failover(:get, path, nil, headers)
    end

    # Send a PATCH request.  Same contract as #post.
    def patch(path, payload, headers: {})
      request_with_failover(:patch, path, payload, headers)
    end

    # Send a DELETE request (no body).
    def delete(path, headers: {})
      request_with_failover(:delete, path, nil, headers)
    end

    # Send a multipart/form-data POST.
    #
    # @param path       [String]  API path
    # @param body_bytes [String]  Pre-built binary multipart body
    # @param boundary   [String]  Multipart boundary string (without leading --)
    # @param read_timeout [Integer]  Override read timeout (uploads may be slow)
    # @return [Hash]  { success: Boolean, data: Hash, error: String }
    def multipart_post(path, body_bytes, boundary, read_timeout: READ_TIMEOUT)
      headers = { "Content-Type" => "multipart/form-data; boundary=#{boundary}" }
      request_with_failover(:multipart_post, path, body_bytes, headers,
                            read_timeout_override: read_timeout)
    end

    # Send a multipart/form-data PATCH.  Same contract as #multipart_post.
    def multipart_patch(path, body_bytes, boundary, read_timeout: READ_TIMEOUT)
      headers = { "Content-Type" => "multipart/form-data; boundary=#{boundary}" }
      request_with_failover(:multipart_patch, path, body_bytes, headers,
                            read_timeout_override: read_timeout)
    end

    private def request_with_failover(method, path, payload, extra_headers, read_timeout_override: nil)
      last_error = nil

      @hosts.each_with_index do |base, host_index|
        ATTEMPTS_PER_HOST.times do |attempt|
          begin
            return execute_request(method, base, path, payload, extra_headers,
                                   read_timeout_override: read_timeout_override)
          rescue RetryableNetworkError => e
            last_error = e
            backoff    = INITIAL_BACKOFF * (2**attempt)
            Clacky::Logger.debug(
              "[PlatformHTTP] #{method.upcase} #{base}#{path} attempt #{attempt + 1} failed: " \
              "#{e.message} — retrying in #{backoff}s"
            )
            sleep(backoff)
          end
        end

        if host_index + 1 < @hosts.size
          Clacky::Logger.debug(
            "[PlatformHTTP] Primary host exhausted, switching to fallback: #{@hosts[host_index + 1]}"
          )
        end
      end

      # All hosts / attempts exhausted
      { success: false, error: "Network error: #{last_error&.message || "unknown"}", data: {} }
    end

    private def execute_request(method, base, path, payload, extra_headers, read_timeout_override: nil)
      uri  = URI.parse("#{base}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = read_timeout_override || READ_TIMEOUT

      req = build_request(method, uri, payload, extra_headers)

      response = http.request(req)
      parse_response(response)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise RetryableNetworkError, "Timeout: #{e.message}"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
           Errno::ECONNRESET, EOFError => e
      raise RetryableNetworkError, "Connection error: #{e.message}"
    rescue OpenSSL::SSL::SSLError => e
      raise RetryableNetworkError, "SSL error: #{e.message}"
    rescue StandardError => e
      raise RetryableNetworkError, e.message
    end

    private def build_request(method, uri, payload, extra_headers)
      # Multipart methods use body_stream to preserve binary null bytes.
      # payload is already the pre-built binary body_bytes string.
      if method == :multipart_post || method == :multipart_patch
        klass = method == :multipart_post ? Net::HTTP::Post : Net::HTTP::Patch
        req   = klass.new(uri.path)
        extra_headers.each { |k, v| req[k] = v }
        req["Content-Length"] = payload.bytesize.to_s
        req.body_stream = StringIO.new(payload)
        return req
      end

      klass = {
        post:   Net::HTTP::Post,
        patch:  Net::HTTP::Patch,
        delete: Net::HTTP::Delete,
        get:    Net::HTTP::Get
      }.fetch(method)

      req = klass.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      extra_headers.each { |k, v| req[k] = v }
      req.body = JSON.generate(payload) if payload
      req
    end

    private def parse_response(response)
      body = JSON.parse(response.body) rescue {}
      code = response.code.to_i

      if code == 200 || code == 201
        { success: true, data: body["data"] || body }
      else
        error_code = body["code"]
        error_msg  = API_ERROR_MESSAGES[error_code] ||
                     body["error"] ||
                     "Request failed (HTTP #{code}#{error_code ? ", code: #{error_code}" : ""}). Please contact support."
        { success: false, error: error_msg, data: body }
      end
    end

    # Raised for transient failures that should be retried (timeouts, conn resets, SSL errors).
    class RetryableNetworkError < StandardError; end
  end
end
