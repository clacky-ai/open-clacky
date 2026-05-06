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

      # DeepSeek V4 models
      # Source: https://api-docs.deepseek.com/quick_start/pricing (USD / 1M tokens)
      # DeepSeek billing model:
      #   - "cache miss input" = regular prompt_tokens rate
      #   - "cache hit input"  = cache_read rate (DeepSeek has no separate cache-write charge)
      #   - No tiered pricing (single rate regardless of context length)
      "deepseek-v4-flash" => {
        input: {
          default: 0.14,                  # $0.14/MTok cache miss
          over_200k: 0.14                 # no tiered pricing
        },
        output: {
          default: 0.28,                  # $0.28/MTok
          over_200k: 0.28
        },
        cache: {
          write: 0.14,                    # DeepSeek doesn't charge extra for writes; bill at miss rate
          read: 0.028                     # $0.028/MTok cache hit
        }
      },

      "deepseek-v4-pro" => {
        input: {
          default: 1.74,                  # $1.74/MTok cache miss
          over_200k: 1.74
        },
        output: {
          default: 3.48,                  # $3.48/MTok
          over_200k: 3.48
        },
        cache: {
          write: 1.74,                    # no separate write charge; bill at miss rate
          read: 0.145                     # $0.145/MTok cache hit
        }
      },

      # Kimi K2.5 / K2.6 multimodal models
      # Source: https://platform.moonshot.cn (USD / 1M tokens)
      # Kimi billing model (same shape as DeepSeek):
      #   - "cache miss input" = regular prompt_tokens rate
      #   - "cache hit input"  = cache_read rate (no separate cache-write charge)
      #   - No tiered pricing (single rate regardless of context length)
      "kimi-k2.5" => {
        input: {
          default: 0.60,                  # $0.60/MTok cache miss
          over_200k: 0.60                 # no tiered pricing
        },
        output: {
          default: 3.00,                  # $3.00/MTok
          over_200k: 3.00
        },
        cache: {
          write: 0.60,                    # Kimi doesn't charge extra for writes; bill at miss rate
          read: 0.10                      # $0.10/MTok cache hit
        }
      },

      "kimi-k2.6" => {
        input: {
          default: 0.95,                  # $0.95/MTok cache miss
          over_200k: 0.95
        },
        output: {
          default: 4.00,                  # $4.00/MTok
          over_200k: 4.00
        },
        cache: {
          write: 0.95,                    # no separate write charge; bill at miss rate
          read: 0.16                      # $0.16/MTok cache hit
        }
      },

      # GLM (Zhipu / Z.ai) — USD per 1M tokens.
      # Source: https://docs.z.ai/guides/overview/pricing (Z.ai international).
      # Pricing policy: we always bill at the Z.ai international flat rate,
      # regardless of which endpoint (mainland bigmodel.cn vs intl z.ai) the
      # user configured. Rationale:
      #   1. Mainland GLM uses tiered pricing (≤32K / >32K / >128K) where the
      #      >32K tier is hit by the vast majority of real requests, and is
      #      actually a few RMB cheaper than Z.ai's flat rate — displaying the
      #      (slightly higher) Z.ai rate gives users a "displayed ≤ actual"
      #      experience which is psychologically safer than the reverse.
      #   2. Single flat rate keeps the table shape consistent with every
      #      other provider here (no special-case tier logic for just GLM).
      # Cache-write: same convention as DeepSeek/Kimi — OpenAI-compatible
      # endpoints don't charge separately for cache writes (Z.ai's page lists
      # "Cached Input Storage: Limited-time Free"), so bill writes at the
      # regular input miss rate for safe "displayed ≤ actual" behaviour.
      "glm-5.1" => {
        input:  { default: 1.40, over_200k: 1.40 },
        output: { default: 4.40, over_200k: 4.40 },
        cache:  { write: 1.40, read: 0.26 }
      },

      "glm-5" => {
        input:  { default: 1.00, over_200k: 1.00 },
        output: { default: 3.20, over_200k: 3.20 },
        cache:  { write: 1.00, read: 0.20 }
      },

      "glm-5-turbo" => {
        input:  { default: 1.20, over_200k: 1.20 },
        output: { default: 4.00, over_200k: 4.00 },
        cache:  { write: 1.20, read: 0.24 }
      },

      # GLM-5V-Turbo is the multimodal sibling of GLM-5-Turbo (vision capable,
      # see providers.rb model_capabilities override). Same input/output rate
      # as 5-Turbo per Z.ai's Vision Models table.
      "glm-5v-turbo" => {
        input:  { default: 1.20, over_200k: 1.20 },
        output: { default: 4.00, over_200k: 4.00 },
        cache:  { write: 1.20, read: 0.24 }
      },

      "glm-4.7" => {
        input:  { default: 0.60, over_200k: 0.60 },
        output: { default: 2.20, over_200k: 2.20 },
        cache:  { write: 0.60, read: 0.11 }
      },

      # MiniMax — USD per 1M tokens.
      # Source: https://platform.minimaxi.com (Pay-as-You-Go).
      # MiniMax pricing is identical across mainland (.com) and international
      # (.io) endpoints, verified by the team. Same cache-write convention as
      # DeepSeek/Kimi/GLM: bill writes at the input miss rate (OpenAI-compatible
      # usage responses from MiniMax don't reliably carry a separate
      # cache_creation_input_tokens field, so a distinct write rate would be
      # dead code in practice).
      # Note: providers.rb uses the capitalised "MiniMax-M2.x" model id, but
      # the pricing table keys are lowercased to stay consistent with the
      # rest of this file; normalize_model_name() lowercases incoming model
      # names before lookup.
      "minimax-m2.5" => {
        input:  { default: 0.30, over_200k: 0.30 },
        output: { default: 1.20, over_200k: 1.20 },
        cache:  { write: 0.30, read: 0.03 }
      },

      "minimax-m2.7" => {
        input:  { default: 0.30, over_200k: 0.30 },
        output: { default: 1.20, over_200k: 1.20 },
        cache:  { write: 0.30, read: 0.06 }
      },

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
      #   - cost: Cost in USD (Float) or nil if model pricing is unknown
      #   - source: Cost source (:price) or nil if unknown (Symbol or nil)
      def calculate_cost(model:, usage:)
        pricing_result = get_pricing_with_source(model)
        pricing = pricing_result[:pricing]
        source = pricing_result[:source]

        # If no pricing table matches this model, return nil cost.
        # Unknown models should display as N/A, never fall back to guesses.
        return { cost: nil, source: nil } unless pricing

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
      #   - pricing: Pricing structure or nil if model is unknown
      #   - source: :price (matched) or nil (unknown)
      def get_pricing_with_source(model)
        # Normalize model name (remove version suffixes, handle variations)
        normalized_model = normalize_model_name(model)

        if normalized_model
          # Found specific pricing for this model
          {
            pricing: PRICING_TABLE[normalized_model],
            source: :price
          }
        else
          # No matching pricing table entry — cost is unknown
          { pricing: nil, source: nil }
        end
      end
      
      
      # Normalize model name to match pricing table keys.
      # Returns the canonical key on match, or nil when no pricing is available.
      def normalize_model_name(model)
        return nil if model.nil? || model.empty?
        
        model = model.downcase.strip
        
        # Direct match
        return model if PRICING_TABLE.key?(model)
        
        # Check for Claude model variations
        # Support both dot and dash separators (e.g., "4.5", "4-5", "4-6")
        # Also handles Bedrock cross-region prefixes (e.g. "jp.anthropic.claude-sonnet-4-6")
        case model
        when /claude.*opus.*4[.-]?[5-9]/i
          "claude-opus-4.5"
        when /claude.*sonnet.*4[.-]?[5-9]/i
          "claude-sonnet-4.5"
        when /claude.*haiku.*4[.-]?[5-9]/i
          "claude-haiku-4.5"
        when /claude-3-5-sonnet-20241022/i
          "claude-3-5-sonnet-20241022"
        when /claude-3-5-sonnet-20240620/i
          "claude-3-5-sonnet-20240620"
        when /claude-3-5-haiku-20241022/i
          "claude-3-5-haiku-20241022"
        when /deepseek-v4-pro/i, /deepseek.*v4.*pro/i
          "deepseek-v4-pro"
        when /deepseek-v4-flash/i, /deepseek.*v4.*flash/i
          "deepseek-v4-flash"
        # Legacy aliases: deepseek-chat and deepseek-reasoner are being
        # deprecated on 2026-07-24 and map to deepseek-v4-flash's
        # non-thinking / thinking modes respectively. Bill at flash rates.
        when /^deepseek-chat$/i, /^deepseek-reasoner$/i
          "deepseek-v4-flash"
        # Kimi K2.5 / K2.6 — strict match only. K2 text-only models
        # (kimi-k2-0905-preview, kimi-k2-thinking, etc.) are not yet
        # registered in providers.rb and will be added in a follow-up
        # issue together with their model_capabilities overrides.
        when /^kimi-k2\.?5$/i
          "kimi-k2.5"
        when /^kimi-k2\.?6$/i
          "kimi-k2.6"
        # GLM (Zhipu / Z.ai) — the five models registered in providers.rb.
        # GLM-5V-Turbo is the vision variant; all five share the same Z.ai
        # international flat-rate pricing regardless of which endpoint
        # (mainland bigmodel.cn vs intl z.ai) the user configured.
        # Strict anchored match so unrelated strings like "glm-5-x-foo"
        # don't silently borrow a nearby model's rate.
        when /^glm-5\.1$/i
          "glm-5.1"
        when /^glm-5v-turbo$/i
          "glm-5v-turbo"
        when /^glm-5-turbo$/i
          "glm-5-turbo"
        when /^glm-5$/i
          "glm-5"
        when /^glm-4\.7$/i
          "glm-4.7"
        # MiniMax — model ids in providers.rb use capitalised "MiniMax-M2.x"
        # but we match case-insensitively and map to the lowercased table key.
        when /^minimax-m2\.5$/i
          "minimax-m2.5"
        when /^minimax-m2\.7$/i
          "minimax-m2.7"
        else
          nil  # No pricing available for this model — cost will show as N/A
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
