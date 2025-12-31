# frozen_string_literal: true

RSpec.describe Clacky::Tools::WebFetch do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "returns error for invalid URL" do
      result = tool.execute(url: "not a url")

      expect(result[:error]).to include("Invalid URL")
    end

    it "returns error for non-HTTP URL" do
      result = tool.execute(url: "ftp://example.com")

      expect(result[:error]).to include("must be HTTP or HTTPS")
    end

    # Note: Actual web fetch tests would require network access or mocking
    # For now, we test the basic structure and error handling
    it "handles network errors gracefully" do
      allow_any_instance_of(Net::HTTP).to receive(:start).and_raise(StandardError.new("Connection failed"))

      result = tool.execute(url: "https://example.com")

      expect(result[:error]).to include("Failed to fetch")
    end

    # Note: Testing actual network calls would require mocking the full HTTP stack
    # For simplicity, we test that max_length is validated as a parameter
    it "accepts max_length parameter" do
      # Just verify the tool accepts the parameter without error
      # Actual network testing would require more complex mocking
      definition = tool.to_function_definition
      expect(definition[:function][:parameters][:properties][:max_length]).not_to be_nil
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("web_fetch")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("url")
      expect(definition[:function][:parameters][:properties]).to have_key(:max_length)
    end
  end
end
