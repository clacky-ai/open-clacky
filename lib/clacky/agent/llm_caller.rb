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
      # NOTE on progress lifecycle:
      #   call_llm intentionally does NOT start or stop the progress indicator.
      #   Ownership lives with the caller (Agent#think for normal/compression
      #   paths, Agent#trigger_idle_compression for idle compression). This
      #   avoids nested active/done pairs clobbering each other — a bug that
      #   silently dropped the idle-compression summary line.
      #
      #   Inside call_llm we only *update in place* during retries, so the
      #   already-live progress slot shows meaningful transient status
      #   ("Network failed… attempt 2/10", etc.).
      private def call_llm
        # Transition :fallback_active → :probing if cooling-off has expired.
        @config.maybe_start_probing

        tools_to_send = @tool_registry.all_definitions

        max_retries = 10
        retry_delay = 5
        retries = 0
        # One-shot flag set by the BadRequestError rescue below when the server
        # complained about missing reasoning_content. The subsequent retry will
        # pad every assistant message's reasoning_content, which satisfies
        # DeepSeek / Kimi thinking-mode providers even when the earlier turns
        # were produced by a different provider (e.g. MiniMax keeps thinking
        # inline in content and never emits a reasoning_content field, so the
        # history-evidence heuristic in MessageHistory can't infer thinking
        # mode on its own). We retry at most once — if padding doesn't fix it,
        # the error is something else and we let it propagate.
        force_reasoning_content_pad = false
        thinking_retry_attempted = false

        begin
          # Use active_messages (Time Machine) when undone, otherwise send full history.
          # to_api strips internal fields and handles orphaned tool_calls.
          messages_to_send = if respond_to?(:active_messages)
            active_messages(force_reasoning_content_pad: force_reasoning_content_pad)
          else
            @history.to_api(force_reasoning_content_pad: force_reasoning_content_pad)
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
            # Don't show_error here — let the outer rescue block handle it to avoid duplicates.
            # Progress cleanup is the caller's responsibility (via its own ensure block).
            raise AgentError, "[LLM] Network connection failed after #{max_retries} retries: #{e.message}"
          end

        rescue RetryableError => e
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
          # Don't show_error here — let the outer rescue block handle it to avoid duplicates.
          # Progress cleanup is the caller's responsibility (via its own ensure block).
          raise AgentError, "[LLM] Service unavailable after #{current_max} retries"
        end

        rescue Clacky::BadRequestError => e
          # One-shot recovery for thinking-mode providers (DeepSeek V4, Kimi K2)
          # that require every assistant message in the history to carry a
          # reasoning_content field. The history-evidence heuristic in
          # MessageHistory#to_api can miss this when the preceding turns came
          # from a different thinking style (e.g. MiniMax keeps <think>...</think>
          # inline in content and never emits reasoning_content) — so we detect
          # the error here and retry once with forced padding.
          if !thinking_retry_attempted && reasoning_content_missing_error?(e)
            thinking_retry_attempted = true
            force_reasoning_content_pad = true
            Clacky::Logger.info(
              "[thinking-mode] retrying with forced reasoning_content padding " \
              "(model=#{@config.model_name.inspect} base_url=#{@config.base_url.inspect})"
            )
            retry
          end
          raise
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

      # True when a 400 BadRequestError is specifically about a missing
      # reasoning_content field in thinking mode (DeepSeek V4, Kimi K2 thinking).
      # We require TWO distinct substrings to avoid false positives — a generic
      # 400 that happens to mention "reasoning_content" in passing (e.g. a
      # validation hint in some unrelated provider) must NOT trigger the pad
      # retry, which would silently add an empty field to every assistant
      # message in the history.
      private def reasoning_content_missing_error?(err)
        return false unless err.is_a?(Clacky::BadRequestError)

        msg = err.message.to_s.downcase
        msg.include?("reasoning_content") &&
          (msg.include?("thinking") || msg.include?("must be passed back") ||
           msg.include?("must be provided"))
      end
    end
  end
end
