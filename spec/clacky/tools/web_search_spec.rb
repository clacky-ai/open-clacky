# frozen_string_literal: true

RSpec.describe Clacky::Tools::WebSearch do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "returns error for empty query" do
      result = tool.execute(query: "")

      expect(result[:error]).to include("cannot be empty")
    end

    it "returns error for nil query" do
      result = tool.execute(query: nil)

      expect(result[:error]).to include("cannot be empty")
    end

    # Note: Actual web search tests would require network access or mocking
    # For now, we test the basic structure and error handling
    it "handles network errors gracefully" do
      allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(StandardError.new("Network error"))

      result = tool.execute(query: "test query")

      # Should return fallback results with error info
      expect(result[:error]).to be_nil  # The tool handles errors internally
      expect(result[:results]).not_to be_empty
      expect(result[:results].first[:snippet]).to include("Error:")
    end

    it "respects max_results parameter" do
      result = tool.execute(query: "ruby programming", max_results: 5)

      expect(result[:query]).to eq("ruby programming")
      # Count should not exceed max_results
      expect(result[:count]).to be <= 5
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("web_search")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("query")
      expect(definition[:function][:parameters][:properties]).to have_key(:max_results)
    end
  end
end
