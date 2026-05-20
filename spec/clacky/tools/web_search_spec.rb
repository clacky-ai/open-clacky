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

    it "returns diagnostics when all providers raise errors" do
      allow(tool).to receive(:active_providers).and_return(%i[duckduckgo bing])
      allow(tool).to receive(:search_duckduckgo).and_raise(StandardError.new("ddg down"))
      allow(tool).to receive(:search_bing).and_raise(StandardError.new("bing down"))

      result = tool.execute(query: "test query")

      expect(result[:results]).to eq([])
      expect(result[:provider]).to be_nil
      expect(result[:error]).to include("All search providers failed")
      expect(result[:error]).to include("duckduckgo: error")
      expect(result[:error]).to include("bing: error")
      expect(result[:diagnostics].size).to eq(2)
      expect(result[:diagnostics].all? { |d| d[:status] == "error" }).to be(true)
    end

    it "returns no_results message when providers succeed but return empty" do
      allow(tool).to receive(:active_providers).and_return(%i[duckduckgo bing])
      allow(tool).to receive(:search_duckduckgo).and_return([[], { http_status: 200, body_size: 100 }])
      allow(tool).to receive(:search_bing).and_return([[], { http_status: 200, body_size: 120 }])

      result = tool.execute(query: "no result query")

      expect(result[:results]).to eq([])
      expect(result[:provider]).to be_nil
      expect(result[:error]).to include("No search results from providers")
      expect(result[:diagnostics].size).to eq(2)
      expect(result[:diagnostics].all? { |d| d[:status] == "no_results" }).to be(true)
    end

    it "returns first successful provider with diagnostics" do
      allow(tool).to receive(:active_providers).and_return(%i[duckduckgo bing])
      allow(tool).to receive(:search_duckduckgo).and_return([
        [{ title: "Hello", url: "https://example.com", snippet: "world" }],
        { http_status: 200, body_size: 256 }
      ])

      result = tool.execute(query: "ok query", max_results: 5)

      expect(result[:error]).to be_nil
      expect(result[:provider]).to eq("duckduckgo")
      expect(result[:count]).to eq(1)
      expect(result[:diagnostics].size).to eq(1)
      expect(result[:diagnostics].first[:status]).to eq("ok")
      expect(result[:diagnostics].first[:http_status]).to eq(200)
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
