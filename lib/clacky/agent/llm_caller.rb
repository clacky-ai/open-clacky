# frozen_string_literal: true

module Clacky
  class Agent
    # LLM API call management
    # Handles API calls with retry logic, fallback model support, and progress indication
    module LlmCaller
      # Number of consecutive RetryableError failures (503/429/5xx) before switching to fallback.
      # Network-level errors (connection failures, timeouts) do NOT trigger fallback — they are
      # retried on the primary model for the full max_retries budget, since they are likely
      # transient infrastructure blips rather than a model-level outage.
      RETRIES_BEFORE_FALLBACK = 3

      # After switching to the fallback model, allow this many retries before giving up.
      # Kept lower than max_retries (10) because we have already exhausted the primary model.
      MAX_RETRIES_ON_FALLBACK = 5

      # Execute LLM API call with progress indicator, retry logic, and cost tracking.
      #
      # Fallback / probing state machine (driven by AgentConfig):
      #
      #   :primary_ok (nil)
      #     Normal operation — use the configured model.
      #     After RETRIES_BEFORE_FALLBACK consecutive failures → :fallback_active
      #
      #   :fallback_active
      #     Use fallback model.  After FALLBACK_COOLING_OFF_SECONDS (30 min) the
      #     config transitions to :probing on the next call_llm entry.
      #
      #   :probing
      #     Silently attempt the primary model once.
      #     Success  → config transitions back to :primary_ok, user notified.
      #     Failure  → renew cooling-off clock, back to :fallback_active, then
      #                retry the *same* request with the fallback model so the
      #                user experiences no extra delay.
      #
      # @return [Hash] API response with :content, :tool_calls, :usage, etc.
      private def call_llm
        # Transition :fallback_active → :probing if cooling-off has expired.
        @config.maybe_start_probing

        @ui&.show_progress

        tools_to_send = @tool_registry.all_definitions

        max_retries = 10
        retry_delay = 5
        retries = 0

        begin
          # Use active_messages (Time Machine) when undone, otherwise send full history.
          # to_api strips internal fields and handles orphaned tool_calls.
          messages_to_send = if respond_to?(:active_messages)
            active_messages
          else
            @history.to_api
          end

          response = @client.send_messages_with_tools(
            messages_to_send,
            model: current_model,
            tools: tools_to_send,
            max_tokens: @config.max_tokens,
            enable_caching: @config.enable_prompt_caching
          )

          # Successful response — if we were probing, confirm primary is healthy.
          handle_probe_success if @config.probing?

        rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
          @ui&.show_progress(phase: "done")
          retries += 1

          # Probing failure: primary still down — renew cooling-off and retry with fallback.
          if @config.probing?
            handle_probe_failure
            retry
          end

          # Network-level errors (timeouts, connection failures) are likely transient
          # infrastructure blips — do NOT trigger fallback.  Just retry on the current
          # model (primary or already-active fallback) up to max_retries.
          if retries <= max_retries
            @ui&.show_progress(
              "Network failed: #{e.message}",
              progress_type: "retrying",
              phase: "active",
              metadata: { attempt: retries, total: max_retries }
            )
            sleep retry_delay
            retry
          else
            @ui&.show_progress(phase: "done")
            @ui&.show_error("Network failed after #{max_retries} retries: #{e.message}")
            raise AgentError, "Network connection failed after #{max_retries} retries: #{e.message}"
          end

        rescue RetryableError => e
          @ui&.show_progress(phase: "done")
          retries += 1

          # Probing failure: primary still down — renew cooling-off and retry with fallback.
          if @config.probing?
            handle_probe_failure
            retry
          end

          # RetryableError (503/429/5xx/ThrottlingException) signals a service-level outage.
          # After RETRIES_BEFORE_FALLBACK attempts, switch to the fallback model and reset the
          # retry counter — but cap fallback retries at MAX_RETRIES_ON_FALLBACK (< max_retries)
          # since we have already confirmed the primary is struggling.
          current_max = @config.fallback_active? ? MAX_RETRIES_ON_FALLBACK : max_retries

          if retries <= current_max
            if retries == RETRIES_BEFORE_FALLBACK && !@config.fallback_active?
              if try_activate_fallback(current_model)
                retries = 0
                retry
              end
            end
            @ui&.show_progress(
              e.message,
              progress_type: "retrying",
              phase: "active",
              metadata: { attempt: retries, total: current_max }
            )
            sleep retry_delay
            retry
          else
            @ui&.show_progress(phase: "done")
            @ui&.show_error("LLM service unavailable after #{current_max} retries. Please try again later.")
            raise AgentError, "LLM service unavailable after #{current_max} retries"
          end

        ensure
          @ui&.show_progress(phase: "done")
        end

        # Track cost and collect token usage data.
        token_data = track_cost(response[:usage], raw_api_usage: response[:raw_api_usage])
        response[:token_usage] = token_data

        response
      end

      # Attempt to activate the provider fallback model for the given primary model.
      # Shows a user-visible warning when switching. Returns true if a fallback was found
      # and activated, false if no fallback is configured.
      # @param failed_model [String] the model name that is currently failing
      # @return [Boolean]
      private def try_activate_fallback(failed_model)
        fallback = @config.fallback_model_for(failed_model)
        return false unless fallback

        @config.activate_fallback!(fallback)
        @ui&.show_warning(
          "Model #{failed_model} appears unavailable. " \
          "Automatically switching to fallback model: #{fallback}"
        )
        true
      end

      # Called when a probe attempt (testing primary after cooling-off) succeeds.
      # Resets the state machine to :primary_ok and notifies the user.
      private def handle_probe_success
        primary = @config.model_name
        @config.confirm_fallback_ok!
        @ui&.show_warning("Primary model #{primary} is healthy again. Switched back automatically.")
      end

      # Called when a probe attempt fails.
      # Renews the cooling-off clock (back to :fallback_active) so the *same*
      # request is immediately retried with the fallback model — no extra delay.
      private def handle_probe_failure
        fallback = @config.instance_variable_get(:@fallback_model)
        primary  = @config.model_name
        @config.activate_fallback!(fallback)  # renews @fallback_since
        @ui&.show_warning(
          "Primary model #{primary} still unavailable. " \
          "Continuing with fallback model: #{fallback}"
        )
      end
    end
  end
end
