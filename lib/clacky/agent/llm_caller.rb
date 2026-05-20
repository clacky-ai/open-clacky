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

        tools_to_send = @tool_registry.allowed_definitions(@agent_profile.allowed_tools)

        max_retries = 10
        retry_delay = 5
        retries = 0

        # Track whether any of the retry/fallback branches below opened a
        # "retrying" progress slot via show_progress(progress_type:
        # "retrying", phase: "active"). If so, we MUST close it before
        # leaving call_llm — otherwise the UI's legacy shim in
        # UI2::UIController keeps the :quiet ProgressHandle alive, its
        # ticker thread keeps running, and the user sees a frozen
        # "Network failed: ... (681s)" line long after the task finished.
        #
        # The close is done in the outer ensure below so it runs on:
        #   - normal success (response returned)
        #   - unrecoverable failure (raise propagates out)
        #   - BadRequestError reasoning-content retry success
        retrying_progress_opened = false
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
        # One-shot flag for context-overflow recovery. When the server complains
        # the input exceeds the model's context window, we run a forced
        # compression with pull_back_from_tail: 1 (preserves the model's
        # two-checkpoint prompt cache) and retry the original request once.
        # We retry at most once — if still overflowing afterward, the issue is
        # something else (e.g. tool schemas alone exceed the window) and we let
        # the error propagate.
        context_overflow_retry_attempted = false

        begin
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
            enable_caching: @config.enable_prompt_caching,
            on_chunk: build_progress_on_chunk
          )

          # Successful response — if we were probing, confirm primary is healthy.
          handle_probe_success if @config.probing?

          # ── Upstream truncation detector ──────────────────────────────────
          # OpenRouter / Bedrock and other routers sometimes close the SSE
          # stream mid-tool_use: we receive finish_reason="stop" together with
          # a syntactically valid tool_call whose `arguments` JSON is empty,
          # "{}" (placeholder before any key was streamed), or otherwise
          # unparseable. Treat this as retryable — otherwise the agent would
          # execute a tool with empty args (often failing cryptically) or
          # silently exit thinking the task is done.
          #
          # Raises UpstreamTruncatedError (a RetryableError) so the rescue
          # block below handles retry + fallback identically to 5xx/429.
          detect_upstream_truncation!(response)

        rescue Faraday::TimeoutError => e
          # ── Read-timeout path (distinct from connection-level failures) ──
          # Faraday::TimeoutError on our non-streaming POST almost always means
          # the *response* took longer than the 300s read-timeout to come back —
          # i.e. the model is trying to produce a huge output in one shot
          # (e.g. "write me a 2000-line snake game"). Blindly retrying the same
          # request with the same prompt reproduces the same timeout.
          #
          # Strategy:
          #   1. On the FIRST timeout in a task, inject a `[SYSTEM]` user message
          #      telling the model to break the work into smaller steps, then
          #      retry. The history edit changes the prompt, so the retry is
          #      materially different from the failed attempt.
          #   2. On subsequent timeouts in the same task, fall back to the
          #      generic "just retry" behaviour (the model may have ignored
          #      the hint; don't pile on duplicate hints).
          #   3. Probing-mode timeouts still go through handle_probe_failure.
          retries += 1

          if @config.probing?
            handle_probe_failure
            retry
          end

          if retries <= max_retries
            inject_large_output_hint_if_first_timeout(e)
            @ui&.show_progress(
              "Response too slow (likely generating too much at once): #{e.message}",
              progress_type: "retrying",
              phase: "active",
              metadata: { attempt: retries, total: max_retries }
            )
            retrying_progress_opened = true
            sleep retry_delay
            retry
          else
            raise AgentError, "[LLM] Request timed out after #{max_retries} retries: #{e.message}"
          end

        rescue Faraday::ConnectionFailed, Faraday::SSLError, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
          retries += 1

          # Probing failure: primary still down — renew cooling-off and retry with fallback.
          if @config.probing?
            handle_probe_failure
            retry
          end

          # Connection-level errors (DNS, TCP refused, open-timeout, TLS) are
          # transient infrastructure blips — do NOT trigger fallback, and do
          # NOT inject the "break into steps" hint (the model did nothing wrong).
          # Just retry on the current model up to max_retries.
          if retries <= max_retries
            @ui&.show_progress(
              "Network failed: #{e.message}",
              progress_type: "retrying",
              phase: "active",
              metadata: { attempt: retries, total: max_retries }
            )
            retrying_progress_opened = true
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
          retrying_progress_opened = true
          sleep retry_delay
          retry
        else
          # Don't show_error here — let the outer rescue block handle it to avoid duplicates.
          # Progress cleanup is the caller's responsibility (via its own ensure block).
          raise AgentError, "[LLM] Service unavailable after #{current_max} retries"
        end

        rescue Clacky::BadRequestError => e
          # One-shot recovery for "context too long" errors. The model's
          # context window is exceeded by the current history+tools+system
          # prompt. We run a forced compression with pull_back_from_tail: 1
          # (preserves the two-checkpoint prompt cache so the compression
          # call itself still hits cache#A on the second-to-last position),
          # then retry the original request once.
          if !context_overflow_retry_attempted &&
              !@compressing_for_overflow &&
              context_too_long_error?(e) &&
              respond_to?(:compress_messages_if_needed, true)
            context_overflow_retry_attempted = true
            Clacky::Logger.info(
              "[context-overflow] caught BadRequestError, attempting forced compression with pull-back",
              error_message: e.message[0, 200],
              history_size: @history.size,
              previous_total_tokens: @previous_total_tokens
            )
            # Layer 1: standard cache-preserving compression (pull_back: 1).
            # Handles 99% of real overflow cases (newest message tipped the
            # request just past the window).
            if perform_context_overflow_compression(mode: :standard)
              retry
            end

            # Layer 2: aggressive fallback. The Layer 1 compression call
            # itself overflowed — happens when a single newly-appended
            # message is enormous (huge tool_result, pasted file, etc.) so
            # popping just K=1 didn't bring the request below the window.
            # Pop ~half the history this time; sacrifices prompt cache to
            # guarantee the compression call fits.
            Clacky::Logger.warn(
              "[context-overflow] standard compression failed, escalating to aggressive mode"
            )
            if perform_context_overflow_compression(mode: :aggressive)
              retry
            end

            # Both layers exhausted. Let the original error propagate so the
            # user sees the underlying provider message. This should be
            # extremely rare — would require both halves of the history to
            # individually exceed the window, which is essentially impossible
            # under the "previous turn succeeded" invariant.
            Clacky::Logger.error(
              "[context-overflow] both standard and aggressive compression failed; " \
              "propagating original error"
            )
            raise
          end

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

        # [DIAG] Log raw client response shape. Only emit when we see the
        # "finish_reason=stop + non-empty tool_calls" combo, or when any
        # tool_call's arguments look empty/unparseable — both indicate the
        # upstream (Bedrock/relay/model) cut the tool_use stream short.
        # Normal responses produce no log line (too noisy).
        begin
          tool_calls = response[:tool_calls] || []
          if !tool_calls.empty?
            raw_tcs = tool_calls.map do |c|
              args_str = c[:arguments].is_a?(String) ? c[:arguments] : c[:arguments].to_s
              parseable = begin
                JSON.parse(args_str)
                true
              rescue StandardError
                false
              end
              {
                name: c[:name].to_s,
                args_len: args_str.length,
                args_parseable: parseable,
                args_head: args_str[0, 120]
              }
            end
            truncated_call = raw_tcs.any? { |t| t[:args_len] == 0 || t[:args_len] == 2 || !t[:args_parseable] }
            suspicious     = response[:finish_reason] == "stop"

            if suspicious || truncated_call
              Clacky::Logger.warn("llm.response_suspicious",
                model: current_model,
                finish_reason: response[:finish_reason].to_s,
                tool_calls_count: raw_tcs.size,
                tool_calls: raw_tcs,
                completion_tokens: token_data[:completion_tokens],
                ttft_ms: response.dig(:latency, :ttft_ms),
                combo_stop_with_toolcalls: suspicious,
                has_truncated_args: truncated_call
              )
            end
          end
        rescue StandardError => e
          Clacky::Logger.warn("llm.response_log_failed", error: e.message)
        end

        response
        ensure
          # Close any "retrying" progress slot that was opened during the
          # retry/fallback loop above. The legacy UI shim allocates a
          # separate :quiet ProgressHandle under the "retrying" key; if it
          # is never finished its ticker thread keeps running and the user
          # sees a stale "Network failed: ... (NNN s)" line long after the
          # task has completed. This ensure runs on:
          #   - successful retry → close the slot, message is "Recovered"
          #     so the final frame is informative rather than blank
          #   - unrecoverable failure that raises out → close the slot so
          #     the spinner doesn't linger while the error bubbles up
          if retrying_progress_opened
            @ui&.show_progress(progress_type: "retrying", phase: "done")
          end
        end
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

      # Run a forced compression to recover from a context-overflow error.
      # Called by the BadRequestError rescue when context_too_long_error?
      # returns true.
      #
      # Two-layer defence:
      # ────────────────────────────────────────────────────────────────────
      # Layer 1 (mode: :standard, default) — preserves prompt cache.
      #   Pop K=1 message from @history tail, then run compression. This
      #   frees just enough token budget for the compression LLM call
      #   itself to fit, while preserving the model's two-checkpoint prompt
      #   cache (cache#A at second-to-last position is still hit). The
      #   popped message is reattached to the rebuilt history's tail by
      #   handle_compression_response, so recent task progress is not lost.
      #   Handles 99% of real-world cases where overflow is caused by the
      #   newest message pushing total just past the window.
      #
      # Layer 2 (mode: :aggressive) — sacrifices prompt cache to survive.
      #   Pop ~half the history (capped) from the tail. This dramatically
      #   shrinks the compression call's input regardless of how big any
      #   single message is. Used as a fallback when Layer 1 itself raises
      #   context_too_long — i.e. a single newly-appended message is so
      #   large (e.g. >50K-token tool_result, pasted huge file) that even
      #   removing it didn't bring the request under the window, OR the
      #   popped message was small but earlier history grew past the limit.
      #   Pulled-back messages are still reattached after compression so no
      #   user content is silently dropped.
      #
      # @param mode [Symbol] :standard or :aggressive
      # @return [Boolean] true if compression succeeded (caller should retry
      #   the original request), false if compression was unable to run
      #   (compression disabled, history too short, etc.) or itself failed
      #   — caller decides whether to escalate to the next layer or
      #   propagate the original error.
      private def perform_context_overflow_compression(mode: :standard)
        return false unless respond_to?(:compress_messages_if_needed, true)

        # Compute pull-back count.
        # Standard: K=1 (cache-preserving).
        # Aggressive: pop ~half the history, but never less than 4 and never
        #   more than (history_size - 2) so we always keep system + at least
        #   one recent message. Capped at 64 to bound the worst case (an
        #   enormous history that should never realistically occur).
        pull_back =
          if mode == :aggressive
            half = @history.size / 2
            [[half, 4].max, [@history.size - 2, 64].min].min
          else
            1
          end

        @compressing_for_overflow = true
        compression_context = nil

        begin
          compression_context = compress_messages_if_needed(
            force: true,
            pull_back_from_tail: pull_back
          )
          return false if compression_context.nil?

          compression_message = compression_context[:compression_message]
          @history.append(compression_message)

          response = call_llm  # recursive — guarded by @compressing_for_overflow
          handle_compression_response(response, compression_context)
          Clacky::Logger.info(
            "[context-overflow] compression succeeded",
            mode: mode,
            pull_back: pull_back
          )
          true
        rescue => e
          # Compression failed mid-flight. Restore @history to a sensible state:
          # roll back the compression instruction we appended, and re-append the
          # pulled-back messages so the user's recent work isn't silently lost.
          if compression_context
            cm = compression_context[:compression_message]
            @history.rollback_before(cm) if cm
            (compression_context[:pulled_back_messages] || []).each do |m|
              @history.append(m)
            end
          end
          Clacky::Logger.warn(
            "[context-overflow] compression failed during overflow recovery",
            mode: mode,
            pull_back: pull_back,
            error_class: e.class.name,
            error_message: e.message[0, 200]
          )
          false
        ensure
          @compressing_for_overflow = false
        end
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

      # True when a 400 BadRequestError indicates the request exceeded the
      # model's context window (i.e. the conversation history is too long).
      #
      # We deliberately favour broad detection over narrow precision:
      #   - False positive cost: one extra (no-op) compression cycle.
      #   - False negative cost: user is stuck — every retry hits the same wall.
      # So the matcher is intentionally permissive.
      #
      # Coverage (verified against real production error strings):
      #
      #   OpenAI:
      #     "This model's maximum context length is 128000 tokens. However
      #      you requested ... Please reduce the length of the messages."
      #     error.code == "context_length_exceeded"
      #
      #   Anthropic:
      #     "prompt is too long: 218849 tokens > 200000 maximum"
      #
      #   Qwen / Alibaba (DashScope):
      #     "You passed 117345 input tokens and requested 8192 output tokens.
      #      However the model's context length is only 125536 tokens, resulting
      #      in a maximum input length of 117344 tokens. Please reduce the length
      #      of the input prompt. (parameter=input_tokens, value=117345)"
      #
      #   Qwen / Alibaba (DashScope) — newer/terser format (qwen3.6 series):
      #     "InternalError.Algo.InvalidParameter: Range of input length should be [1, 229376]"
      #
      #   DeepSeek / Kimi / MiniMax / most OpenAI-compatible relays:
      #     Variants of OpenAI-style "context length" / "tokens exceeds" wording.
      #
      #   Generic gateways (Portkey, OpenRouter):
      #     "The total number of tokens exceeds the model's maximum context length"
      private def context_too_long_error?(err)
        return false unless err.is_a?(Clacky::BadRequestError)

        msg = err.message.to_s.downcase

        # Strong phrases — any one of these is conclusive on its own.
        # Each phrase is two-or-more semantic words to avoid single-word noise.
        strong_phrases = [
          "context length",                 # OpenAI / Qwen / many compat APIs
          "context_length_exceeded",        # OpenAI error.code
          "maximum context",                # OpenAI variant
          "maximum input length",           # Qwen
          "prompt is too long",             # Anthropic
          "input is too long",              # Anthropic-compat relays
          "exceeds the maximum context",    # Portkey & generic gateways
          "exceeds the model's context",    # Generic
          "exceeds the model's maximum",    # Generic
          "reduce the length of the input", # Qwen action hint
          "reduce the length of the messages", # OpenAI action hint
          "reduce the length of your",      # Generic action hint
          "reduce the length of the prompt", # Generic action hint
          "range of input length"           # Qwen DashScope qwen3.6+ terse format
        ]
        return true if strong_phrases.any? { |p| msg.include?(p) }

        # Pattern 1: Anthropic-style "<N> tokens > <N> maximum"
        return true if msg =~ /\d+\s*tokens?\s*>\s*\d+/

        # Pattern 2: Qwen-style structured field "parameter=input_tokens"
        return true if msg.include?("parameter=input_tokens")

        false
      end

      # Detect upstream tool-call truncation and raise UpstreamTruncatedError
      # so the standard RetryableError rescue (with fallback model support)
      # handles retry identically to 5xx/429.
      #
      # Background: OpenRouter routes to Anthropic/Bedrock/etc. and passes
      # through whatever the upstream sends. If the upstream closes the SSE
      # stream mid-tool_use (observed with Anthropic at ~127 s TTFT under
      # load), OpenRouter does NOT surface an error — it emits a valid
      # `tool_calls[]` whose `arguments` is empty, `"{}"`, or non-parseable
      # JSON. Without this check the agent would either execute the tool with
      # empty args or (worse) silently exit thinking the task finished.
      #
      # Rule is deliberately narrow: we only intercept the case where the
      # model streamed literally nothing into the tool_call arguments —
      # i.e. `nil`, empty string, or the placeholder `"{}"`. Partial/invalid
      # JSON (e.g. `{"path": "/tmp/x"`) is left to the existing
      # ArgumentsParser → BadArgumentsError path, because the model already
      # committed to specific values and feeding the parse error back as a
      # tool_result lets it self-correct in one round-trip (faster than a
      # blind retry from scratch).
      private def detect_upstream_truncation!(response)
        tool_calls = response[:tool_calls]
        return if tool_calls.nil? || tool_calls.empty?

        truncated = tool_calls.find { |tc| tool_call_args_truncated?(tc[:arguments]) }
        return unless truncated

        args_str = truncated[:arguments].is_a?(String) ? truncated[:arguments] : truncated[:arguments].to_s
        Clacky::Logger.warn("llm.upstream_truncation_detected",
          model: current_model,
          tool_name: truncated[:name].to_s,
          args_len: args_str.length,
          args_head: args_str[0, 80],
          finish_reason: response[:finish_reason].to_s,
          completion_tokens: response.dig(:token_usage, :completion_tokens),
          ttft_ms: response.dig(:latency, :ttft_ms)
        )

        # Inject a one-shot [SYSTEM] hint so a plain retry isn't doomed to the
        # same fate when the truncation correlates with large tool_call args
        # (e.g. writing a 5000-char file in one go). For infrastructure-level
        # blips this hint is harmless — the retry usually succeeds on its own
        # and the hint just sits in history without affecting behaviour.
        inject_upstream_truncation_hint_if_first(truncated)

        raise Clacky::UpstreamTruncatedError,
          "[LLM] Upstream truncated tool_call `#{truncated[:name]}` " \
          "(args=#{args_str[0, 40].inspect}). Retrying..."
      end

      # True when a tool_call's arguments field looks COMPLETELY empty —
      # i.e. the upstream stream was cut before the model wrote any real
      # content into the arguments JSON.
      #
      # Rules:
      #   - nil / non-String / empty string  → truncated (nothing at all)
      #   - parses to {} (empty object)      → truncated (placeholder only)
      #   - anything else (including partial/invalid JSON like `{"path":
      #     "/tmp/x"` where the model already started writing) → NOT
      #     truncated by this detector
      #
      # Partial-JSON cases are deliberately left to the existing
      # ArgumentsParser → BadArgumentsError path, which surfaces the parse
      # error back to the LLM as a tool_result so it can self-correct. That
      # is more efficient than a blind retry when the model already wrote
      # most of the args.
      private def tool_call_args_truncated?(args)
        return true if args.nil?
        return true unless args.is_a?(String)
        return true if args.empty?

        parsed = begin
          JSON.parse(args)
        rescue JSON::ParserError
          # Partial/invalid JSON — let ArgumentsParser handle it downstream.
          return false
        end

        parsed.is_a?(Hash) && parsed.empty?
      end

      # On the FIRST Faraday::TimeoutError within a task, append a [SYSTEM]
      # user message to the history instructing the model to break its work
      # into smaller steps. Subsequent timeouts in the same task are ignored
      # here (caller just retries) so we don't pollute history with duplicate
      # hints.
      #
      # The injected message carries `system_injected: true` so it is:
      #   - Hidden from UI replay (session_serializer / replay_history filters)
      #   - Skipped by prompt-caching marker placement (client.rb)
      #   - Skipped by message compression's "recent user turn" protection
      #     (message_compressor_helper.rb)
      #
      # Reset per-task via Agent#run (see @task_timeout_hint_injected = false).
      private def inject_large_output_hint_if_first_timeout(err)
        return if @task_timeout_hint_injected

        @task_timeout_hint_injected = true

        hint = "[SYSTEM] The previous LLM response timed out (read timeout after ~300s). " \
               "This usually means the model was trying to produce too much output in a single response. " \
               "Please change your approach:\n" \
               "- Break the task into multiple smaller steps, each producing a short response.\n" \
               "- For long files: first create a skeleton with `write` (structure + placeholder comments only), " \
               "then fill in each section with separate `edit` calls.\n" \
               "- Keep each single tool-call argument (especially file content) well under ~500 lines.\n" \
               "- Do NOT attempt to output the entire deliverable in one response."

        @history.append({
          role: "user",
          content: hint,
          system_injected: true,
          task_id: @current_task_id
        })

        Clacky::Logger.info(
          "[llm_caller] Read-timeout detected — injected 'break into smaller steps' hint " \
          "(error=#{err.class}: #{err.message})"
        )

        @ui&.show_warning(
          "LLM response timed out — asking model to break the task into smaller steps and retrying..."
        )
      end

      # On the FIRST upstream-truncation detection within a task, append a
      # [SYSTEM] user message nudging the model toward smaller tool_call args.
      # This guards against the (real but rare) case where the upstream SSE
      # cut correlates with large tool_call payloads — a plain retry on the
      # same oversized args would keep tripping the same wire.
      #
      # For purely infrastructural truncations (Anthropic edge blip, router
      # hiccup), the hint is harmless — the retry will succeed and the hint
      # just sits unused in history. Cheaper than letting the agent burn
      # through its retry budget on the same oversized payload.
      #
      # Same plumbing as inject_large_output_hint_if_first_timeout: one-shot
      # per task, carries `system_injected: true` so it's hidden from UI
      # replay and skipped by compression/caching placement logic. Reset per
      # task via Agent#run (see @task_upstream_truncation_hint_injected).
      private def inject_upstream_truncation_hint_if_first(truncated_call)
        return if @task_upstream_truncation_hint_injected

        @task_upstream_truncation_hint_injected = true

        tool_name = truncated_call[:name].to_s
        hint = "[SYSTEM] The previous response was cut short by the upstream provider " \
               "before the `#{tool_name}` tool_call finished streaming. " \
               "The partial tool_call has been discarded. To avoid the same problem on retry, " \
               "please adapt your approach:\n" \
               "- Prefer smaller tool_call arguments — large single-shot payloads are more likely to be truncated.\n" \
               "- For long file content: create the file first with a minimal skeleton via `write`, " \
               "then append sections one at a time with `edit`.\n" \
               "- Break large tasks into multiple smaller tool calls instead of one big one.\n" \
               "- Keep each tool-call argument comfortably under ~2000 characters when possible."

        @history.append({
          role: "user",
          content: hint,
          system_injected: true,
          task_id: @current_task_id
        })

        Clacky::Logger.info(
          "[llm_caller] Upstream truncation — injected 'smaller tool_call args' hint " \
          "(tool=#{tool_name.inspect})"
        )

        @ui&.show_warning(
          "Upstream response was truncated mid tool-call — asking model to use smaller steps and retrying..."
        )
      end

      # Build a streaming progress callback for Client#send_messages_with_tools.
      # Returns nil when no UI is attached, so the client skips the streaming
      # plumbing entirely. Callback throttles UI updates to avoid flooding the
      # progress handle on fast streams.
      private def build_progress_on_chunk
        return nil unless @ui

        last_emit_at = 0.0
        min_interval = 0.25
        ->(input_tokens:, output_tokens:) {
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return if now - last_emit_at < min_interval && output_tokens > 0
          last_emit_at = now
          @ui.show_progress(
            progress_type: "thinking",
            phase: "active",
            metadata: { input_tokens: input_tokens, output_tokens: output_tokens }
          )
        }
      end
    end
  end
end
