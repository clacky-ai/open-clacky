# frozen_string_literal: true

require_relative "base_component"

module Clacky
  module UI2
    module Components
      # CommonComponent renders common UI elements (progress, success, error, warning)
      class CommonComponent < BaseComponent
        # Render thinking indicator
        # @return [String] Thinking indicator
        def render_thinking
          symbol = format_symbol(:thinking)
          text = format_text("Thinking...", :thinking)
          "#{symbol} #{text}"
        end

        # Render progress indicator
        # @param message [String] Progress message
        # @return [String] Progress indicator
        def render_progress(message)
          symbol = format_symbol(:thinking)
          text = format_text(message, :thinking)
          "#{symbol} #{text}"
        end

        # Render success message
        # @param message [String] Success message
        # @return [String] Success message
        def render_success(message)
          symbol = format_symbol(:success)
          text = format_text(message, :success)
          "#{symbol} #{text}"
        end

        # Render error message
        # @param message [String] Error message
        # @return [String] Error message
        def render_error(message)
          symbol = format_symbol(:error)
          text = format_text(message, :error)
          "#{symbol} #{text}"
        end

        # Render warning message
        # @param message [String] Warning message
        # @return [String] Warning message
        def render_warning(message)
          symbol = format_symbol(:warning)
          text = format_text(message, :warning)
          "#{symbol} #{text}"
        end

        # Render task completion summary
        # @param iterations [Integer] Number of iterations
        # @param cost [Float] Cost in USD
        # @param duration [Float] Duration in seconds
        # @param cache_tokens [Integer] Cache read tokens
        # @param cache_requests [Integer] Total cache requests count
        # @param cache_hits [Integer] Cache hit requests count
        # @return [String] Formatted completion summary
        def render_task_complete(iterations:, cost:, duration: nil, cache_tokens: nil, cache_requests: nil, cache_hits: nil)
          lines = []
          lines << ""
          lines << @pastel.dim("─" * 60)
          lines << render_success("Task Complete")
          lines << ""

          # Display each stat on a separate line
          lines << "  Iterations: #{iterations}"
          lines << "  Cost: $#{cost.round(4)}"
          lines << "  Duration: #{duration.round(1)}s" if duration

          # Display cache information if available
          if cache_tokens && cache_tokens > 0
            lines << "  Cache Tokens: #{cache_tokens} tokens"
          end

          if cache_requests && cache_requests > 0
            hit_rate = cache_hits > 0 ? ((cache_hits.to_f / cache_requests) * 100).round(1) : 0
            lines << "  Cache Requests: #{cache_requests} (#{cache_hits} hits, #{hit_rate}% hit rate)"
          end

          lines.join("\n")
        end
      end
    end
  end
end
