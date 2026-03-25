# frozen_string_literal: true

module Clacky
  class Agent
    # Cost tracking and token usage statistics
    # Manages cost calculation, token estimation, and usage display
    module CostTracker
      # Track cost from API usage
      # Updates total cost and displays iteration statistics
      # @param usage [Hash] Usage data from API response
      # @param raw_api_usage [Hash, nil] Raw API usage data for debugging
      def track_cost(usage, raw_api_usage: nil)
        # Priority 1: Use API-provided cost if available (OpenRouter, LiteLLM, etc.)
        iteration_cost = nil
        if usage[:api_cost]
          @total_cost += usage[:api_cost]
          @cost_source = :api
          @task_cost_source = :api
          iteration_cost = usage[:api_cost]
          @ui&.log("Using API-provided cost: $#{usage[:api_cost]}", level: :debug) if @config.verbose
        else
          # Priority 2: Calculate from tokens using ModelPricing
          result = ModelPricing.calculate_cost(model: current_model, usage: usage)
          cost = result[:cost]
          pricing_source = result[:source]

          @total_cost += cost
          iteration_cost = cost
          # Map pricing source to cost source: :price or :default
          @cost_source = pricing_source
          @task_cost_source = pricing_source

          if @config.verbose
            source_label = pricing_source == :price ? "model pricing" : "default pricing"
            @ui&.log("Calculated cost for #{@config.model_name} using #{source_label}: $#{cost.round(6)}", level: :debug)
            @ui&.log("Usage breakdown: prompt=#{usage[:prompt_tokens]}, completion=#{usage[:completion_tokens]}, cache_write=#{usage[:cache_creation_input_tokens] || 0}, cache_read=#{usage[:cache_read_input_tokens] || 0}", level: :debug)
          end
        end

        # Collect token usage data for this iteration (returned to caller for deferred display)
        token_data = collect_iteration_tokens(usage, iteration_cost)

        # Update session bar cost in real-time (don't wait for agent.run to finish)
        @ui&.update_sessionbar(cost: @total_cost)

        # Track cache usage statistics (global)
        @cache_stats[:total_requests] += 1

        if usage[:cache_creation_input_tokens]
          @cache_stats[:cache_creation_input_tokens] += usage[:cache_creation_input_tokens]
        end

        if usage[:cache_read_input_tokens]
          @cache_stats[:cache_read_input_tokens] += usage[:cache_read_input_tokens]
          @cache_stats[:cache_hit_requests] += 1
        end

        # Store raw API usage samples (keep last 3 for debugging)
        if raw_api_usage
          @cache_stats[:raw_api_usage_samples] ||= []
          @cache_stats[:raw_api_usage_samples] << raw_api_usage
          @cache_stats[:raw_api_usage_samples] = @cache_stats[:raw_api_usage_samples].last(3)
        end

        # Track cache usage for current task
        if @task_cache_stats
          @task_cache_stats[:total_requests] += 1

          if usage[:cache_creation_input_tokens]
            @task_cache_stats[:cache_creation_input_tokens] += usage[:cache_creation_input_tokens]
          end

          if usage[:cache_read_input_tokens]
            @task_cache_stats[:cache_read_input_tokens] += usage[:cache_read_input_tokens]
            @task_cache_stats[:cache_hit_requests] += 1
          end
        end

        # Return token_data so the caller can display it at the right moment
        token_data
      end

      # Estimate token count for a message content
      # Simple approximation: characters / 4 (English text)


      private

      # Collect token usage data for current iteration and return it.
      # Does NOT call @ui directly — the caller is responsible for displaying
      # at the right moment (e.g. after show_assistant_message).
      # @param usage [Hash] Usage data from API
      # @param cost [Float] Cost for this iteration
      # @return [Hash] token_data ready for show_token_usage
      def collect_iteration_tokens(usage, cost)
        prompt_tokens = usage[:prompt_tokens] || 0
        completion_tokens = usage[:completion_tokens] || 0
        total_tokens = usage[:total_tokens] || (prompt_tokens + completion_tokens)
        cache_write = usage[:cache_creation_input_tokens] || 0
        cache_read = usage[:cache_read_input_tokens] || 0

        # Calculate token delta from previous iteration
        delta_tokens = total_tokens - @previous_total_tokens
        @previous_total_tokens = total_tokens  # Update for next iteration

        {
          delta_tokens: delta_tokens,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          total_tokens: total_tokens,
          cache_write: cache_write,
          cache_read: cache_read,
          cost: cost,
          cost_source: @cost_source
        }
      end
    end
  end
end
