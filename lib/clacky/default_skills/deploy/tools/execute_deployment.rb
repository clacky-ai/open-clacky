# frozen_string_literal: true

require "open3"

module Clacky
  module DeployTools
    # Trigger a Railway deployment via `railway up --detach`.
    # Uses RAILWAY_TOKEN passed through environment — no clackycli wrapper needed.
    class ExecuteDeployment

      # Trigger deployment for a service (non-blocking, detached mode).
      #
      # @param service_name   [String] Railway service name (from railway.toml or service list)
      # @param platform_token [String] RAILWAY_TOKEN for this deploy task
      # @return [Hash] { success: true } or { success: false, error: String }
      def self.execute(service_name:, platform_token:)
        if service_name.nil? || service_name.strip.empty?
          return { success: false, error: "service_name is required" }
        end

        if platform_token.nil? || platform_token.strip.empty?
          return { success: false, error: "platform_token is required" }
        end

        puts "🚀 Triggering deployment for service: #{service_name}"

        env = ENV.to_h.merge("RAILWAY_TOKEN" => platform_token)
        cmd = "railway up --service #{shell_escape(service_name)} --detach"

        out, err, status = Open3.capture3(env, cmd)

        # railway up --detach exits 0 and prints a "Build Logs:" line on success
        if status.success? && (out.include?("Build Logs:") || out.include?("Deployment"))
          puts "✅ Build triggered successfully"
          return { success: true, output: out }
        end

        # Non-zero exit or unexpected output
        combined = [out, err].reject(&:empty?).join("\n")
        { success: false, error: "railway up failed (exit #{status.exitstatus})", details: combined }
      end

      private_class_method def self.shell_escape(str)
        "'#{str.to_s.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
