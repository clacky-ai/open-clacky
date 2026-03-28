# frozen_string_literal: true

module Clacky
  class HookManager
    HOOK_EVENTS = [
      :before_tool_use,
      :after_tool_use,
      :on_tool_error,
      :on_start,
      :on_complete,
      :on_iteration,
      :session_rollback
    ].freeze

    def initialize
      @hooks = Hash.new { |h, k| h[k] = [] }
    end

    def add(event, &block)
      validate_event!(event)
      @hooks[event] << block
    end

    def trigger(event, *args)
      validate_event!(event)
      result = { action: :allow }

      @hooks[event].each do |hook|
        begin
          hook_result = hook.call(*args)
          result.merge!(hook_result) if hook_result.is_a?(Hash)
        rescue StandardError => e
          # Log error but don't fail
          Clacky::Logger.error("Hook error", event: event, error: e)
        end
      end

      result
    end

    def has_hooks?(event)
      @hooks[event].any?
    end

    def clear(event = nil)
      if event
        validate_event!(event)
        @hooks[event].clear
      else
        @hooks.clear
      end
    end


    def validate_event!(event)
      return if HOOK_EVENTS.include?(event)

      raise ArgumentError, "Invalid hook event: #{event}. Must be one of #{HOOK_EVENTS.join(', ')}"
    end
  end
end
