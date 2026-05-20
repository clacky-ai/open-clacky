# frozen_string_literal: true

require "json"
require "open3"

module Clacky
  module Tools
    class NoknoAdmin < Base
      VALID_ACTIONS = %w[
        prepare_release
        build_release
        upgrade_canary
        promote_release
        rollback_release
        release_status
        health_audit
      ].freeze

      self.tool_name = "nokno_admin"
      self.tool_description = "Run nokno control-plane actions through a fixed helper pipeline. Use this for upstream sync preparation, image builds, canary upgrades, full promotion, rollback, release status checks, and manual health audits."
      self.tool_category = "system_admin"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: VALID_ACTIONS,
            description: "The release-control action to run."
          },
          upstream_tag: {
            type: "string",
            description: "Official upstream tag, required for prepare_release."
          },
          image_tag: {
            type: "string",
            description: "Release image tag such as oc-v1.2.3-nokno.1."
          },
          slug: {
            type: "string",
            description: "Target user slug. Defaults to NOKNO_CANARY_USER_SLUG for upgrade_canary."
          },
          target_users: {
            type: "array",
            items: { type: "string" },
            description: "Ordered user slug list for promote_release, rollback_release, or health_audit."
          }
        },
        required: ["action"]
      }

      def execute(action:, upstream_tag: nil, image_tag: nil, slug: nil, target_users: nil, working_dir: nil, **_args)
        action = action.to_s.strip
        raise Clacky::ToolCallError, "Unsupported nokno_admin action: #{action}" unless VALID_ACTIONS.include?(action)

        users = normalize_users(target_users)
        validate_action_inputs!(action, upstream_tag: upstream_tag, image_tag: image_tag, slug: slug, users: users)

        helper_script = helper_script_path(working_dir)
        raise Clacky::ToolCallError, "Admin helper script not found: #{helper_script}" unless File.exist?(helper_script)

        env = {
          "NOKNO_ADMIN_ACTION" => action,
          "NOKNO_UPSTREAM_TAG" => upstream_tag.to_s,
          "NOKNO_IMAGE_TAG" => image_tag.to_s,
          "NOKNO_TARGET_SLUG" => slug.to_s
        }
        env["NOKNO_TARGET_USERS_JSON"] = JSON.generate(users) unless users.nil?

        stdout, stderr, status = Open3.capture3(env, "bash", helper_script)
        unless status.success?
          error_output = [stderr, stdout].map(&:to_s).reject(&:empty?).join("\n").strip
          raise Clacky::ToolCallError, error_output.empty? ? "nokno admin helper failed" : error_output
        end

        parse_helper_output(stdout, action)
      end

      def format_call(args)
        action = args[:action] || args["action"]
        "NoknoAdmin(#{action})"
      end

      def format_result(result)
        return "Done" unless result.is_a?(Hash)

        result[:message] || result["message"] || result[:status] || result["status"] || "Done"
      end

      private def validate_action_inputs!(action, upstream_tag:, image_tag:, slug:, users:)
        case action
        when "prepare_release"
          raise Clacky::ToolCallError, "upstream_tag is required for prepare_release" if upstream_tag.to_s.strip.empty?
        when "build_release"
          raise Clacky::ToolCallError, "image_tag is required for build_release" if image_tag.to_s.strip.empty?
        when "upgrade_canary"
          raise Clacky::ToolCallError, "image_tag is required for upgrade_canary" if image_tag.to_s.strip.empty?
        when "promote_release", "rollback_release"
          raise Clacky::ToolCallError, "image_tag is required for #{action}" if image_tag.to_s.strip.empty?
          raise Clacky::ToolCallError, "target_users is required for #{action}" if users.nil? || users.empty?
        end

        validate_slug!(slug) unless slug.to_s.strip.empty?
        Array(users).each { |user| validate_slug!(user) }
      end

      private def validate_slug!(value)
        return if value.to_s.match?(/\A[a-z0-9][a-z0-9-]{1,38}\z/)

        raise Clacky::ToolCallError, "Invalid user slug: #{value}"
      end

      private def normalize_users(target_users)
        return nil if target_users.nil?

        values =
          case target_users
          when Array then target_users
          else [target_users]
          end

        values.map(&:to_s).map(&:strip).reject(&:empty?)
      end

      private def helper_script_path(working_dir)
        candidates = []
        candidates << ENV["NOKNO_ADMIN_HELPER_SCRIPT"]
        control_plane_root = ENV["NOKNO_CONTROL_PLANE_ROOT"].to_s.strip
        candidates << File.join(control_plane_root, "deploy/nas/scripts/run-admin-helper.sh") unless control_plane_root.empty?
        candidates << File.join(working_dir, "deploy/nas/scripts/run-admin-helper.sh") if working_dir
        candidates << File.expand_path("../../../../../deploy/nas/scripts/run-admin-helper.sh", __dir__)
        candidates.compact.find { |path| !path.to_s.empty? && File.exist?(path) } || candidates.last
      end

      private def parse_helper_output(stdout, action)
        output = stdout.to_s.strip
        return { action: action, ok: true, message: "Completed #{action}" } if output.empty?

        parsed = JSON.parse(output, symbolize_names: true)
        parsed[:action] ||= action
        parsed
      rescue JSON::ParserError
        {
          action: action,
          ok: true,
          message: "Completed #{action}",
          output: output
        }
      end
    end
  end
end
