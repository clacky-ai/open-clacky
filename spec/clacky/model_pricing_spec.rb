# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ModelPricing do
  describe ".calculate_cost" do
    context "with Claude Opus 4.5" do
      let(:model) { "claude-opus-4.5" }
      
      it "calculates cost for basic input/output" do
        usage = {
          prompt_tokens: 100_000,        # 100K tokens
          completion_tokens: 50_000       # 50K tokens
        }
        
        # Input: (100,000 / 1,000,000) * $5 = $0.50
        # Output: (50,000 / 1,000,000) * $25 = $1.25
        # Total: $1.75
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.75)
        expect(result[:source]).to eq(:price)
      end
      
      it "calculates cost with cache write and read" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,  # Cache write
          cache_read_input_tokens: 30_000       # Cache read
        }
        
        # Regular input (non-cached): (70,000 / 1,000,000) * $5 = $0.35
        # Output: (50,000 / 1,000,000) * $25 = $1.25
        # Cache write: (20,000 / 1,000,000) * $6.25 = $0.125
        # Cache read: (30,000 / 1,000,000) * $0.50 = $0.015
        # Total: $1.74
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.74)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with Claude Sonnet 4.5" do
      let(:model) { "claude-sonnet-4.5" }
      
      it "uses default pricing for prompts ≤ 200K tokens" do
        usage = {
          prompt_tokens: 100_000,        # 100K tokens (under threshold)
          completion_tokens: 50_000
        }
        
        # Input: (100,000 / 1,000,000) * $3 = $0.30
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Total: $1.05
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.05)
        expect(result[:source]).to eq(:price)
      end
      
      it "uses over_200k pricing for large prompts" do
        usage = {
          prompt_tokens: 250_000,        # 250K tokens (over threshold)
          completion_tokens: 50_000
        }
        
        # Input: (250,000 / 1,000,000) * $6 = $1.50
        # Output: (50,000 / 1,000,000) * $22.50 = $1.125
        # Total: $2.625
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(2.625)
        expect(result[:source]).to eq(:price)
      end
      
      it "uses tiered cache pricing" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,
          cache_read_input_tokens: 30_000
        }
        
        # Regular input (non-cached): (70,000 / 1,000,000) * $3 = $0.21
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Cache write (default): (20,000 / 1,000,000) * $3.75 = $0.075
        # Cache read (default): (30,000 / 1,000,000) * $0.30 = $0.009
        # Total: $1.044
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.044)
        expect(result[:source]).to eq(:price)
      end
      
      it "uses over_200k cache pricing for large prompts" do
        usage = {
          prompt_tokens: 250_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,
          cache_read_input_tokens: 30_000
        }
        
        # Total input tokens: 250,000 + 20,000 = 270,000 (over threshold)
        # Regular input (non-cached): (220,000 / 1,000,000) * $6 = $1.32
        # Output: (50,000 / 1,000,000) * $22.50 = $1.125
        # Cache write (over 200k): (20,000 / 1,000,000) * $7.50 = $0.15
        # Cache read (over 200k): (30,000 / 1,000,000) * $0.60 = $0.018
        # Total: $2.613
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(2.613)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with Claude Haiku 4.5" do
      let(:model) { "claude-haiku-4.5" }
      
      it "calculates cost correctly" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        # Input: (100,000 / 1,000,000) * $1 = $0.10
        # Output: (50,000 / 1,000,000) * $5 = $0.25
        # Total: $0.35
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(0.35)
        expect(result[:source]).to eq(:price)
      end
      
      it "calculates cache costs" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,
          cache_read_input_tokens: 30_000
        }
        
        # Regular input (non-cached): (70,000 / 1,000,000) * $1 = $0.07
        # Output: (50,000 / 1,000,000) * $5 = $0.25
        # Cache write: (20,000 / 1,000,000) * $1.25 = $0.025
        # Cache read: (30,000 / 1,000,000) * $0.10 = $0.003
        # Total: $0.348
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(0.348)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with DeepSeek V4 models" do
      it "calculates deepseek-v4-flash basic cost" do
        usage = {
          prompt_tokens: 100_000,         # 100K tokens
          completion_tokens: 50_000        # 50K tokens
        }

        # Input: (100,000 / 1,000,000) * $0.14 = $0.014
        # Output: (50,000 / 1,000,000) * $0.28 = $0.014
        # Total: $0.028
        result = described_class.calculate_cost(model: "deepseek-v4-flash", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.028)
        expect(result[:source]).to eq(:price)
      end

      it "calculates deepseek-v4-pro with cache read (cache hit billing)" do
        usage = {
          prompt_tokens: 100_000,          # includes cache reads per OpenAI-style counting
          completion_tokens: 50_000,
          cache_read_input_tokens: 30_000  # cache hit portion
        }

        # Regular input (non-cached): ((100_000 - 30_000) / 1_000_000) * $1.74 = $0.1218
        # Output:                     (50_000 / 1_000_000)             * $3.48 = $0.174
        # Cache read:                 (30_000 / 1_000_000)             * $0.145 = $0.00435
        # Total: $0.30015
        result = described_class.calculate_cost(model: "deepseek-v4-pro", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.30015)
        expect(result[:source]).to eq(:price)
      end

      it "maps legacy deepseek-chat alias to flash pricing" do
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        result = described_class.calculate_cost(model: "deepseek-chat", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.028)
        expect(result[:source]).to eq(:price)
      end

      it "maps legacy deepseek-reasoner alias to flash pricing" do
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        result = described_class.calculate_cost(model: "deepseek-reasoner", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.028)
        expect(result[:source]).to eq(:price)
      end
    end

    context "with Kimi K2 multimodal models" do
      it "calculates kimi-k2.5 basic cost" do
        usage = {
          prompt_tokens: 100_000,          # 100K tokens
          completion_tokens: 50_000         # 50K tokens
        }

        # Input:  (100_000 / 1_000_000) * $0.60 = $0.060
        # Output: (50_000  / 1_000_000) * $3.00 = $0.150
        # Total:  $0.210
        result = described_class.calculate_cost(model: "kimi-k2.5", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.210)
        expect(result[:source]).to eq(:price)
      end

      it "calculates kimi-k2.6 with cache read (cache hit billing)" do
        usage = {
          prompt_tokens: 100_000,          # includes cache reads per OpenAI-style counting
          completion_tokens: 50_000,
          cache_read_input_tokens: 30_000  # cache hit portion
        }

        # Regular input (non-cached): ((100_000 - 30_000) / 1_000_000) * $0.95 = $0.0665
        # Output:                     (50_000 / 1_000_000)             * $4.00 = $0.200
        # Cache read:                 (30_000 / 1_000_000)             * $0.16 = $0.0048
        # Total: $0.2713
        result = described_class.calculate_cost(model: "kimi-k2.6", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.2713)
        expect(result[:source]).to eq(:price)
      end

      it "matches kimi-k2.5 case-insensitively" do
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        result = described_class.calculate_cost(model: "Kimi-K2.5", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.210)
        expect(result[:source]).to eq(:price)
      end

      it "does not match unregistered k2 text-only variants" do
        # K2 text-only models (kimi-k2-0905-preview, kimi-k2-thinking, etc.)
        # are not in the pricing table yet — they must return N/A, not
        # accidentally bill at k2.5/k2.6 rates via a loose regex.
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        %w[kimi-k2-0905-preview kimi-k2-thinking kimi-k2-turbo-preview].each do |model|
          result = described_class.calculate_cost(model: model, usage: usage)
          expect(result[:cost]).to be_nil
          expect(result[:source]).to be_nil
        end
      end
    end

    context "with Claude 3.5 models" do
      it "supports claude-3-5-sonnet-20241022" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "claude-3-5-sonnet-20241022", usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.05)
        expect(result[:source]).to eq(:price)
      end
      
      it "supports claude-3-5-haiku-20241022" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "claude-3-5-haiku-20241022", usage: usage)
        expect(result[:cost]).to be_within(0.001).of(0.35)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with unknown model" do
      it "returns nil cost (no default fallback)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "unknown-model", usage: usage)
        expect(result[:cost]).to be_nil
        expect(result[:source]).to be_nil
      end
    end
    
    context "with case variations" do
      it "normalizes model names (uppercase)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "CLAUDE-OPUS-4.5", usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.75)
        expect(result[:source]).to eq(:price)
      end
      
      it "normalizes model names (with spaces)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "claude opus 4.5", usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.75)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with AWS Bedrock model names" do
      it "recognizes bedrock claude-sonnet-4-5 with dash separator" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        model = "bedrock/jp.anthropic.claude-sonnet-4-5-20250929-v1:0:region/ap-northeast-1"
        result = described_class.calculate_cost(model: model, usage: usage)
        # Should use claude-sonnet-4.5 pricing: $3/MTok input, $15/MTok output
        # Input: (100,000 / 1,000,000) * $3 = $0.30
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Total: $1.05
        expect(result[:cost]).to be_within(0.001).of(1.05)
        expect(result[:source]).to eq(:price)
      end
      
      it "recognizes bedrock claude-opus-4-5 format" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        model = "bedrock/us.anthropic.claude-opus-4-5-20250101-v1:0"
        result = described_class.calculate_cost(model: model, usage: usage)
        # Should use claude-opus-4.5 pricing
        expect(result[:cost]).to be_within(0.001).of(1.75)
        expect(result[:source]).to eq(:price)
      end
      
      it "recognizes bedrock claude-haiku-4-5 format" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        model = "bedrock/eu.anthropic.claude-haiku-4-5-20250101-v1:0"
        result = described_class.calculate_cost(model: model, usage: usage)
        # Should use claude-haiku-4.5 pricing
        expect(result[:cost]).to be_within(0.001).of(0.35)
        expect(result[:source]).to eq(:price)
      end
    end
  end
  
  describe ".get_pricing" do
    it "returns pricing for known models" do
      pricing = described_class.get_pricing("claude-opus-4.5")
      expect(pricing[:input][:default]).to eq(5.00)
      expect(pricing[:output][:default]).to eq(25.00)
    end
    
    it "returns nil for unknown models" do
      pricing = described_class.get_pricing("gpt-4")
      expect(pricing).to be_nil
    end
    
    it "returns nil for nil model" do
      pricing = described_class.get_pricing(nil)
      expect(pricing).to be_nil
    end
  end

  # GLM (Zhipu / Z.ai) pricing — always bill at Z.ai international flat rate,
  # regardless of mainland-vs-intl endpoint. Flat-rate (no tiered billing).
  # Source: https://docs.z.ai/guides/overview/pricing
  describe "GLM pricing" do
    it "bills glm-5.1 at the Z.ai flat rate" do
      usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
      result = described_class.calculate_cost(model: "glm-5.1", usage: usage)
      # (100_000/1M)*$1.4 + (50_000/1M)*$4.4 = 0.14 + 0.22 = $0.36
      expect(result[:cost]).to be_within(0.0001).of(0.36)
      expect(result[:source]).to eq(:price)
    end

    it "bills glm-5 at the Z.ai flat rate" do
      usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      result = described_class.calculate_cost(model: "glm-5", usage: usage)
      # $1 + $3.2 = $4.20
      expect(result[:cost]).to be_within(0.0001).of(4.20)
    end

    it "bills glm-5-turbo separately from glm-5v-turbo (they share rates but not row)" do
      usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      text_cost   = described_class.calculate_cost(model: "glm-5-turbo", usage: usage)[:cost]
      vision_cost = described_class.calculate_cost(model: "glm-5v-turbo", usage: usage)[:cost]
      # GLM-5-Turbo and GLM-5V-Turbo happen to share the same input/output rate
      # on Z.ai's pricing page, but they are distinct rows — they must both
      # resolve to :price (not N/A) and produce the same cost.
      expect(text_cost).to   be_within(0.0001).of(5.20)  # $1.2 + $4 = $5.2
      expect(vision_cost).to be_within(0.0001).of(5.20)
    end

    it "bills glm-4.7 at its lower flat rate" do
      usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      result = described_class.calculate_cost(model: "glm-4.7", usage: usage)
      # $0.6 + $2.2 = $2.80
      expect(result[:cost]).to be_within(0.0001).of(2.80)
    end

    it "does NOT apply tiered pricing for prompts over 200K (GLM is flat-rate)" do
      small = described_class.calculate_cost(
        model: "glm-5.1",
        usage: { prompt_tokens: 10_000, completion_tokens: 0 }
      )[:cost]
      large = described_class.calculate_cost(
        model: "glm-5.1",
        usage: { prompt_tokens: 250_000, completion_tokens: 0 }
      )[:cost]
      # Per-token rate must be identical — rules out accidental tiered cost.
      expect(small / 10_000).to be_within(0.0000001).of(large / 250_000)
    end

    it "bills cache reads at $0.26/MTok and cache writes at the input miss rate for glm-5.1" do
      usage = {
        prompt_tokens: 100_000,
        completion_tokens: 0,
        cache_read_input_tokens: 50_000,
        cache_creation_input_tokens: 50_000
      }
      result = described_class.calculate_cost(model: "glm-5.1", usage: usage)
      # Regular input: (100_000 - 50_000) / 1M * $1.4  = $0.07
      # Cache read:     50_000 / 1M * $0.26            = $0.013
      # Cache write:    50_000 / 1M * $1.40 (miss rate)= $0.07
      # Total: $0.153
      expect(result[:cost]).to be_within(0.0001).of(0.153)
    end

    it "is case-insensitive for GLM model names" do
      result = described_class.calculate_cost(
        model: "GLM-5.1",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
      )
      expect(result[:cost]).to be_within(0.0001).of(1.40)
      expect(result[:source]).to eq(:price)
    end
  end

  # MiniMax pricing — identical across mainland (.com) and international (.io)
  # endpoints per the team's verification.
  # Source: https://platform.minimaxi.com (Pay-as-You-Go)
  describe "MiniMax pricing" do
    it "bills MiniMax-M2.5 with its distinct cache-read rate" do
      usage = {
        prompt_tokens: 100_000,
        completion_tokens: 50_000,
        cache_read_input_tokens: 20_000
      }
      result = described_class.calculate_cost(model: "MiniMax-M2.5", usage: usage)
      # Regular input: (100_000 - 20_000) / 1M * $0.30  = $0.024
      # Cache read:     20_000 / 1M * $0.03             = $0.0006
      # Output:         50_000 / 1M * $1.20             = $0.06
      # Total: $0.0846
      expect(result[:cost]).to be_within(0.0001).of(0.0846)
      expect(result[:source]).to eq(:price)
    end

    it "bills MiniMax-M2.7 with its higher cache-read rate" do
      usage = {
        prompt_tokens: 1_000_000,
        completion_tokens: 1_000_000,
        cache_read_input_tokens: 500_000
      }
      result = described_class.calculate_cost(model: "MiniMax-M2.7", usage: usage)
      # Regular input: 500_000 / 1M * $0.30 = $0.15
      # Cache read:    500_000 / 1M * $0.06 = $0.03
      # Output:      1_000_000 / 1M * $1.20 = $1.20
      # Total: $1.38
      expect(result[:cost]).to be_within(0.0001).of(1.38)
    end

    it "handles the capitalised MiniMax- prefix from providers.rb" do
      # providers.rb uses "MiniMax-M2.7" (capitalised), but the pricing table
      # key is lowercase — normalize_model_name must bridge the two.
      result = described_class.calculate_cost(
        model: "MiniMax-M2.7",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
      )
      expect(result[:cost]).to be_within(0.0001).of(0.30)
      expect(result[:source]).to eq(:price)
    end

    it "is also case-insensitive (lowercased input works)" do
      result = described_class.calculate_cost(
        model: "minimax-m2.7",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
      )
      expect(result[:source]).to eq(:price)
    end
  end

  # Guards against accidentally billing unrelated model names at a
  # neighbouring model's rate — the anchored ^...$ regex in normalize_model_name
  # should reject fuzzy matches and fall through to nil (cost=N/A).
  describe "strict matching for GLM/MiniMax" do
    it "returns nil cost for unregistered GLM variants" do
      %w[glm-4.7-flash glm-4.6 glm-4.5-air glm-ocr glm-4.6v].each do |m|
        result = described_class.calculate_cost(
          model: m,
          usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
        )
        expect(result[:cost]).to be_nil,   "expected N/A for #{m}, got #{result[:cost]}"
        expect(result[:source]).to be_nil, "expected nil source for #{m}, got #{result[:source]}"
      end
    end

    it "returns nil cost for unregistered MiniMax variants" do
      %w[minimax-m2.5-highspeed m2-her minimax-abab6].each do |m|
        result = described_class.calculate_cost(
          model: m,
          usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
        )
        expect(result[:cost]).to be_nil,   "expected N/A for #{m}, got #{result[:cost]}"
        expect(result[:source]).to be_nil, "expected nil source for #{m}, got #{result[:source]}"
      end
    end
  end
end
