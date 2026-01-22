# frozen_string_literal: true

require_relative "base_component"

module Clacky
  module UI2
    module Components
      # StatusComponent renders status information (iteration count, cost, tasks, etc.)
      class StatusComponent < BaseComponent
        # Render status information
        # @param data [Hash] Status data
        #   - :iteration [Integer] Current iteration number
        #   - :cost [Float] Total cost in USD
        #   - :tasks_completed [Integer] Number of completed tasks
        #   - :tasks_total [Integer] Total number of tasks
        #   - :message [String] Custom status message
        # @return [String] Rendered status
        def render(data)
          parts = []

          # Iteration info
          if data[:iteration]
            parts << render_iteration(data[:iteration])
          end

          # Cost info
          if data[:cost]
            parts << render_cost(data[:cost])
          end

          # Tasks info
          if data[:tasks_total] && data[:tasks_total] > 0
            parts << render_tasks(data[:tasks_completed] || 0, data[:tasks_total])
          end

          # Custom message
          if data[:message]
            parts << format_text(data[:message], :info)
          end

          # Join parts with separator
          symbol = format_symbol(:info)
          "#{symbol} #{parts.join(' | ')}"
        end

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
          symbol = format_symbol(:thinking)  # Use [..] symbol
          text = format_text(message, :thinking)  # Use dim color
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

        private

        # Render iteration count
        # @param iteration [Integer] Iteration number
        # @return [String] Formatted iteration
        def render_iteration(iteration)
          @pastel.dim("Iter: ") + @pastel.white(iteration.to_s)
        end

        # Render cost
        # @param cost [Float] Cost in USD
        # @return [String] Formatted cost
        def render_cost(cost)
          formatted_cost = format("%.4f", cost)
          @pastel.dim("Cost: $") + @pastel.yellow(formatted_cost)
        end

        # Render tasks progress
        # @param completed [Integer] Completed tasks
        # @param total [Integer] Total tasks
        # @return [String] Formatted tasks
        def render_tasks(completed, total)
          progress = format_progress_bar(completed, total, 10)
          @pastel.dim("Tasks: ") + "#{progress} (#{completed}/#{total})"
        end
      end
    end
  end
end
