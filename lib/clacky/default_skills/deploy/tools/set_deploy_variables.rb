# frozen_string_literal: true

require "open3"

module Clacky
  module DeployTools
    # Set environment variables on a Railway service via `railway variables --set`.
    # Uses RAILWAY_TOKEN passed through environment — no clackycli wrapper needed.
    #
    # Supports both normal key=value pairs and Railway inter-service references
    # like ${{postgres.DATABASE_PUBLIC_URL}} (pass raw_value: true to skip escaping).
    class SetDeployVariables

      SENSITIVE_PATTERNS = [
        /password/i, /secret/i, /api_key/i,
        /token/i,    /credential/i, /private_key/i
      ].freeze

      # Maximum number of variables to set in a single batch call
      BATCH_SIZE = 20

      # Retry config for transient failures
      MAX_RETRIES = 3
      RETRY_DELAY = 2 # seconds

      # Set one or more environment variables on a Railway service.
      # Batches all variables into a single `railway variables` call to minimize
      # network connections and avoid SSL reset issues.
      #
      # @param service_name   [String]  Railway service name
      # @param variables      [Hash]    KEY => VALUE pairs
      # @param platform_token [String]  RAILWAY_TOKEN for this deploy task
      # @param raw_value      [Boolean] when true, values are passed unquoted
      #                                 (for Railway ${{...}} references)
      # @return [Hash] {
      #   success:           Boolean,
      #   set_variables:     Array<String>,
      #   errors:            Array<Hash>
      # }
      def self.execute(service_name:, variables:, platform_token:, raw_value: false)
        if service_name.nil? || service_name.strip.empty?
          return { success: false, error: "service_name is required" }
        end

        env = ENV.to_h.merge("RAILWAY_TOKEN" => platform_token)

        # Log all variables being set
        variables.each do |key, value|
          log_value = sensitive?(key) ? "******" : value
          puts "  Setting #{key}=#{log_value}"
        end

        # Split into batches to avoid command line length limits
        set_vars   = []
        error_list = []
        var_pairs  = variables.map { |k, v| [k.to_s, v.to_s] }

        var_pairs.each_slice(BATCH_SIZE) do |batch|
          result = set_batch(env, service_name, batch, raw_value: raw_value)
          if result[:success]
            set_vars.concat(batch.map(&:first))
          else
            # Retry logic: attempt individual vars if batch fails
            batch.each do |key, value|
              individual = set_one_with_retry(env, service_name, key, value, raw_value: raw_value)
              if individual[:success]
                set_vars << key
              else
                error_list << { key: key, error: individual[:error] }
              end
            end
          end
        end

        {
          success:       error_list.empty?,
          set_variables: set_vars,
          errors:        error_list
        }
      end

      # Set a batch of variables in a single railway command call.
      #
      # @param env          [Hash]          environment variables
      # @param service_name [String]        Railway service name
      # @param pairs        [Array<Array>]  [[key, value], ...]
      # @return [Hash] { success: true } or { success: false, error: String }
      def self.set_batch(env, service_name, pairs, raw_value: false)
        set_flags = pairs.flat_map { |key, value| ["--set", "#{key}=#{value}"] }
        cmd = ["railway", "variables", "--service", service_name, "--skip-deploys"] + set_flags

        _out, err, status = Open3.capture3(env, *cmd)

        if status.success?
          { success: true }
        else
          { success: false, error: err.strip }
        end
      end

      # Set a single variable with retry logic for transient network errors.
      #
      # @return [Hash] { success: true } or { success: false, error: String }
      def self.set_one_with_retry(env, service_name, key, value, raw_value: false)
        last_error = nil

        MAX_RETRIES.times do |attempt|
          result = set_one(env, service_name, key, value, raw_value: raw_value)
          return result if result[:success]

          last_error = result[:error]
          # Only retry on connection/SSL errors
          break unless last_error.to_s =~ /connection|ssl|reset|timeout|network/i

          puts "  ⚠️  Retrying #{key} (attempt #{attempt + 2}/#{MAX_RETRIES})..." if attempt < MAX_RETRIES - 1
          sleep RETRY_DELAY
        end

        { success: false, error: last_error }
      end

      # Set a single variable. Builds the `railway variables --set` command.
      #
      # @return [Hash] { success: true } or { success: false, error: String }
      def self.set_one(env, service_name, key, value, raw_value: false)
        assignment = "#{key}=#{value}"

        cmd = [
          "railway", "variables",
          "--service", service_name,
          "--skip-deploys",
          "--set", assignment
        ]

        _out, err, status = Open3.capture3(env, *cmd)

        if status.success?
          { success: true }
        else
          { success: false, error: err.strip }
        end
      end

      private_class_method def self.sensitive?(key)
        SENSITIVE_PATTERNS.any? { |pat| key.match?(pat) }
      end

      private_class_method def self.shell_escape(str)
        "'#{str.to_s.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
