# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Clacky
  module DeployTools
    # Fetch runtime (environment) logs from a deployed Railway service via
    # the Clacky Deploy API SSE endpoint.
    #
    # Uses DeployApiClient#stream_build_logs for build-phase logs (on failure),
    # and this class for runtime log fetching (e.g. post-deploy diagnostics).
    class FetchRuntimeLogs
      DEFAULT_LINES   = 50
      MAX_LINES       = 200
      STREAM_TIMEOUT  = 60   # seconds

      # Fetch recent runtime logs for a project.
      #
      # @param project_id     [String]  Clacky project ID
      # @param workspace_key  [String]  clacky_ak_* key
      # @param base_url       [String]  API base URL
      # @param lines          [Integer] max log lines to collect
      # @param keyword        [String]  optional filter keyword
      # @return [Hash] { success: true, logs: Array<String> }
      #             or { success: false, error: String }
      def self.execute(project_id:, workspace_key:, base_url:,
                       lines: DEFAULT_LINES, keyword: nil)
        lines = [[lines.to_i, 1].max, MAX_LINES].min

        params  = "project_id=#{URI.encode_www_form_component(project_id)}"
        params += "&keyword=#{URI.encode_www_form_component(keyword)}" if keyword

        uri = URI.parse(
          "#{base_url.to_s.sub(%r{/+$}, "")}" \
          "/openclacky/v1/deploy/logs/environment/stream?#{params}"
        )

        collected = []

        http              = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = STREAM_TIMEOUT

        req                    = Net::HTTP::Get.new(uri.request_uri)
        req["Authorization"]   = "Bearer #{workspace_key}"
        req["Accept"]          = "text/event-stream"

        http.request(req) do |response|
          response.read_body do |chunk|
            chunk.split("\n").each do |raw|
              next unless raw.start_with?("data:")

              json_str = raw.sub(/\Adata:\s*/, "")
              next if json_str.strip.empty?

              begin
                event = JSON.parse(json_str)
                msg   = event["message"].to_s
                collected << msg unless msg.empty?
                return { success: true, logs: collected } if collected.size >= lines
              rescue JSON::ParserError
                # skip malformed events
              end
            end
          end
        end

        { success: true, logs: collected }
      rescue => e
        { success: false, error: "Failed to fetch runtime logs: #{e.message}" }
      end
    end
  end
end
