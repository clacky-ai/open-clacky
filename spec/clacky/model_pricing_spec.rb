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
end
