# frozen_string_literal: true

module Clacky
  # Module for handling AI model pricing
  # Supports different pricing tiers and prompt caching
  module ModelPricing
    # Pricing per 1M tokens (MTok) in USD
    # All pricing is based on official API documentation
    PRICING_TABLE = {
      # Claude 4.5 models - tiered pricing based on prompt length
      "claude-opus-4.5" => {
        input: {
          default: 5.00,              # $5/MTok for prompts ≤ 200K tokens
          over_200k: 5.00             # same for all tiers
        },
        output: {
          default: 25.00,             # $25/MTok for prompts ≤ 200K tokens
          over_200k: 25.00            # same for all tiers
        },
        cache: {
          write: 6.25,                # $6.25/MTok cache write
          read: 0.50                  # $0.50/MTok cache read
        }
      },
      
      "claude-sonnet-4.5" => {
        input: {
          default: 3.00,              # $3/MTok for prompts ≤ 200K tokens
          over_200k: 6.00             # $6/MTok for prompts > 200K tokens
        },
        output: {
          default: 15.00,             # $15/MTok for prompts ≤ 200K tokens
          over_200k: 22.50            # $22.50/MTok for prompts > 200K tokens
        },
        cache: {
          write_default: 3.75,        # $3.75/MTok cache write (≤ 200K)
          write_over_200k: 7.50,      # $7.50/MTok cache write (> 200K)
          read_default: 0.30,         # $0.30/MTok cache read (≤ 200K)
          read_over_200k: 0.60        # $0.60/MTok cache read (> 200K)
        }
      },
      
      "claude-haiku-4.5" => {
        input: {
          default: 1.00,              # $1/MTok
          over_200k: 1.00             # same for all tiers
        },
        output: {
          default: 5.00,              # $5/MTok
          over_200k: 5.00             # same for all tiers
        },
        cache: {
          write: 1.25,                # $1.25/MTok cache write
          read: 0.10                  # $0.10/MTok cache read
        }
      },

      # Claude 3.5 models (for backwards compatibility)
      "claude-3-5-sonnet-20241022" => {
        input: {
          default: 3.00,
          over_200k: 6.00
        },
        output: {
          default: 15.00,
          over_200k: 22.50
        },
        cache: {
          write_default: 3.75,
          write_over_200k: 7.50,
          read_default: 0.30,
          read_over_200k: 0.60
        }
      },

      "claude-3-5-sonnet-20240620" => {
        input: {
          default: 3.00,
          over_200k: 6.00
        },
        output: {
          default: 15.00,
          over_200k: 22.50
        },
        cache: {
          write_default: 3.75,
          write_over_200k: 7.50,
          read_default: 0.30,
          read_over_200k: 0.60
        }
      },

      "claude-3-5-haiku-20241022" => {
        input: {
          default: 1.00,
          over_200k: 1.00
        },
        output: {
          default: 5.00,
          over_200k: 5.00
        },
        cache: {
          write: 1.25,
          read: 0.10
        }
      },

      # Default fallback pricing (conservative estimates)
      "default" => {
        input: {
          default: 0.50,
          over_200k: 0.50
        },
        output: {
          default: 1.50,
          over_200k: 1.50
        },
        cache: {
          write: 0.625,
          read: 0.05
        }
      }
    }.freeze

    # Threshold for tiered pricing (200K tokens)
    TIERED_PRICING_THRESHOLD = 200_000

    class << self
      # Calculate cost for the given model and usage
      # 
      # @param model [String] Model identifier
      # @param usage [Hash] Usage statistics containing:
      #   - prompt_tokens: number of input tokens
      #   - completion_tokens: number of output tokens
      #   - cache_creation_input_tokens: tokens written to cache (optional)
      #   - cache_read_input_tokens: tokens read from cache (optional)
      # @return [Hash] Hash containing:
      #   - cost: Cost in USD (Float)
      #   - source: Cost source (:price or :default) (Symbol)
      def calculate_cost(model:, usage:)
        pricing_result = get_pricing_with_source(model)
        pricing = pricing_result[:pricing]
        source = pricing_result[:source]
        
        prompt_tokens = usage[:prompt_tokens] || 0
        completion_tokens = usage[:completion_tokens] || 0
        cache_write_tokens = usage[:cache_creation_input_tokens] || 0
        cache_read_tokens = usage[:cache_read_input_tokens] || 0
        
        # Determine if we're in the over_200k tier
        # Note: prompt_tokens includes cache_read_tokens but NOT cache_write_tokens
        # cache_write_tokens are additional tokens that were written to cache
        total_input_tokens = prompt_tokens + cache_write_tokens
        over_threshold = total_input_tokens > TIERED_PRICING_THRESHOLD
        
        # Calculate regular input cost (non-cached tokens)
        # prompt_tokens already includes cache_read_tokens, so we need to subtract them
        # cache_write_tokens are not part of prompt_tokens, so they're handled separately in cache_cost
        regular_input_tokens = prompt_tokens - cache_read_tokens
        input_rate = over_threshold ? pricing[:input][:over_200k] : pricing[:input][:default]
        input_cost = (regular_input_tokens / 1_000_000.0) * input_rate
        
        # Calculate output cost
        output_rate = over_threshold ? pricing[:output][:over_200k] : pricing[:output][:default]
        output_cost = (completion_tokens / 1_000_000.0) * output_rate
        
        # Calculate cache costs
        cache_cost = calculate_cache_cost(
          pricing: pricing,
          cache_write_tokens: cache_write_tokens,
          cache_read_tokens: cache_read_tokens,
          over_threshold: over_threshold
        )
        
        {
          cost: input_cost + output_cost + cache_cost,
          source: source
        }
      end
      
      # Get pricing for a specific model
      # Falls back to default pricing if model not found
      # 
      # @param model [String] Model identifier
      # @return [Hash] Pricing structure for the model
      def get_pricing(model)
        get_pricing_with_source(model)[:pricing]
      end
      
      # Get pricing with source information
      # 
      # @param model [String] Model identifier
      # @return [Hash] Hash containing:
      #   - pricing: Pricing structure for the model
      #   - source: :price (matched model) or :default (fallback)
      def get_pricing_with_source(model)
        # Normalize model name (remove version suffixes, handle variations)
        normalized_model = normalize_model_name(model)
        
        if normalized_model == "default"
          # Using default fallback pricing
          {
            pricing: PRICING_TABLE["default"],
            source: :default
          }
        else
          # Found specific pricing for this model
          {
            pricing: PRICING_TABLE[normalized_model],
            source: :price
          }
        end
      end
      
      
      # Normalize model name to match pricing table keys
      def normalize_model_name(model)
        return "default" if model.nil? || model.empty?
        
        model = model.downcase.strip
        
        # Direct match
        return model if PRICING_TABLE.key?(model)
        
        # Check for Claude model variations
        # Support both dot and dash separators (e.g., "4.5", "4-5", "4-6")
        # Also handles Bedrock cross-region prefixes (e.g. "jp.anthropic.claude-sonnet-4-6")
        case model
        when /claude.*opus.*4[.-]?[56]/i
          "claude-opus-4.5"
        when /claude.*sonnet.*4[.-]?[56]/i
          "claude-sonnet-4.5"
        when /claude.*haiku.*4[.-]?[56]/i
          "claude-haiku-4.5"
        when /claude-3-5-sonnet-20241022/i
          "claude-3-5-sonnet-20241022"
        when /claude-3-5-sonnet-20240620/i
          "claude-3-5-sonnet-20240620"
        when /claude-3-5-haiku-20241022/i
          "claude-3-5-haiku-20241022"
        else
          "default"
        end
      end
      
      # Calculate cache-related costs
      def calculate_cache_cost(pricing:, cache_write_tokens:, cache_read_tokens:, over_threshold:)
        cache_cost = 0.0
        
        # Cache write cost
        if cache_write_tokens > 0
          write_rate = if pricing[:cache].key?(:write)
                         # Simple pricing (Opus 4.5, Haiku 4.5)
                         pricing[:cache][:write]
                       elsif over_threshold
                         # Tiered pricing (Sonnet 4.5)
                         pricing[:cache][:write_over_200k]
                       else
                         pricing[:cache][:write_default]
                       end
          
          cache_cost += (cache_write_tokens / 1_000_000.0) * write_rate
        end
        
        # Cache read cost
        if cache_read_tokens > 0
          read_rate = if pricing[:cache].key?(:read)
                        # Simple pricing (Opus 4.5, Haiku 4.5)
                        pricing[:cache][:read]
                      elsif over_threshold
                        # Tiered pricing (Sonnet 4.5)
                        pricing[:cache][:read_over_200k]
                      else
                        pricing[:cache][:read_default]
                      end
          
          cache_cost += (cache_read_tokens / 1_000_000.0) * read_rate
        end
        
        cache_cost
      end
    end
  end
end
