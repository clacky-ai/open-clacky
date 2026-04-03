# frozen_string_literal: true

require "open3"
require "json"

module Clacky
  module DeployTools
    # List Railway services for the linked project.
    # Uses RAILWAY_TOKEN passed through environment — no clackycli wrapper needed.
    #
    # NOTE: In the new deploy flow, service discovery is primarily done via the
    # Clacky Deploy API (deploy/services endpoint). This tool is kept as a
    # fallback for detecting the main service name via `railway service list`.
    class ListServices

      # List services for the current Railway project.
      #
      # @param platform_token [String] RAILWAY_TOKEN for this deploy task
      # @return [Hash] {
      #   success:      Boolean,
      #   services:     Array<Hash>,
      #   main_service: Hash | nil,   # first non-middleware service
      #   db_service:   Hash | nil    # first postgres/mysql service
      # }
      def self.execute(platform_token:)
        if platform_token.nil? || platform_token.strip.empty?
          return { success: false, error: "platform_token is required" }
        end

        env = ENV.to_h.merge("RAILWAY_TOKEN" => platform_token)
        out, err, status = Open3.capture3(env, "railway status --json")

        unless status.success?
          return {
            success: false,
            error:   "railway service list failed (exit #{status.exitstatus})",
            details: err
          }
        end

        info     = JSON.parse(out)
        services = info["services"] || []

        main_svc = services.find do |s|
          name = s["name"].to_s.downcase
          !%w[postgres postgresql mysql redis].any? { |db| name.include?(db) }
        end

        db_svc = services.find do |s|
          name = s["name"].to_s.downcase
          %w[postgres postgresql mysql].any? { |db| name.include?(db) }
        end

        {
          success:      true,
          services:     services,
          main_service: main_svc,
          db_service:   db_svc
        }
      rescue JSON::ParserError => e
        { success: false, error: "Failed to parse service list: #{e.message}", raw: out.to_s[0, 200] }
      rescue => e
        { success: false, error: "Unexpected error: #{e.message}" }
      end
    end
  end
end
