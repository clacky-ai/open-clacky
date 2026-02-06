# frozen_string_literal: true

module Clacky
  class AgentConfig
    PERMISSION_MODES = [:auto_approve, :confirm_safes, :confirm_edits, :plan_only].freeze
    EDITING_TOOLS = %w[write edit].freeze

    attr_accessor :model, :permission_mode,
                  :max_tokens, :verbose, :enable_compression, :keep_recent_messages,
                  :enable_prompt_caching

    def initialize(options = {})
      @model = options[:model] || "gpt-3.5-turbo"
      @permission_mode = validate_permission_mode(options[:permission_mode])
      @max_tokens = options[:max_tokens] || 8192
      @verbose = options[:verbose] || false
      @enable_compression = options[:enable_compression].nil? ? true : options[:enable_compression]
      @keep_recent_messages = options[:keep_recent_messages] || 20
      # Enable prompt caching by default for cost savings
      @enable_prompt_caching = options[:enable_prompt_caching].nil? ? true : options[:enable_prompt_caching]
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
