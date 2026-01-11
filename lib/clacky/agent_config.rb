# frozen_string_literal: true

module Clacky
  class AgentConfig
    PERMISSION_MODES = [:auto_approve, :confirm_safes, :confirm_edits, :plan_only].freeze
    EDITING_TOOLS = %w[write edit].freeze

    attr_accessor :model, :max_iterations, :max_cost_usd, :timeout_seconds,
                  :permission_mode, :allowed_tools, :disallowed_tools,
                  :max_tokens, :verbose, :enable_compression, :keep_recent_messages

    def initialize(options = {})
      @model = options[:model] || "gpt-3.5-turbo"
      @max_iterations = options[:max_iterations] || 200
      @max_cost_usd = options[:max_cost_usd] || 5.0
      @timeout_seconds = options[:timeout_seconds] # nil means no timeout
      @permission_mode = validate_permission_mode(options[:permission_mode])
      @allowed_tools = options[:allowed_tools]
      @disallowed_tools = options[:disallowed_tools] || []
      @max_tokens = options[:max_tokens] || 8192
      @verbose = options[:verbose] || false
      @enable_compression = options[:enable_compression].nil? ? true : options[:enable_compression]
      @keep_recent_messages = options[:keep_recent_messages] || 20
    end



    def is_plan_only?
      @permission_mode == :plan_only
    end

    private

    def validate_permission_mode(mode)
      mode ||= :confirm_safes
      mode = mode.to_sym

      unless PERMISSION_MODES.include?(mode)
        raise ArgumentError, "Invalid permission mode: #{mode}. Must be one of #{PERMISSION_MODES.join(', ')}"
      end

      mode
    end


  end
end
