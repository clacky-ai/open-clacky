# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/clacky/clacky_auth_client"

# Helper: build a fake Faraday response object
def fake_faraday_response(status:, body:)
  double("Faraday::Response", status: status, body: body.is_a?(Hash) ? JSON.generate(body) : body.to_s)
end

RSpec.describe Clacky::ClackyAuthClient do
  let(:workspace_key) { "clacky_ak_test_workspace_key" }
  let(:base_url)      { "https://api.clacky.ai" }

  subject(:client) { described_class.new(workspace_key, base_url: base_url) }

  # ── Input validation (no HTTP calls) ──────────────────────────────────────

  describe "input validation" do
    context "when workspace_api_key is blank" do
      subject { described_class.new("", base_url: base_url) }

      it "returns a failure with a meaningful error" do
        result = subject.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/required/i)
      end
    end

    context "when workspace_api_key has wrong prefix" do
      subject { described_class.new("sk-wrong-prefix", base_url: base_url) }

      it "returns a failure mentioning prefix requirement" do
        result = subject.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/clacky_ak_/i)
      end
    end

    context "when base_url is blank" do
      subject { described_class.new(workspace_key, base_url: "") }

      it "returns a failure with a meaningful error" do
        result = subject.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/required/i)
      end
    end

    context "when base_url has invalid scheme" do
      subject { described_class.new(workspace_key, base_url: "ftp://invalid") }

      it "returns a failure mentioning http/https requirement" do
        result = subject.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/http/i)
      end
    end
  end

  # ── Successful responses ───────────────────────────────────────────────────

  describe "#fetch_workspace_keys — success" do
    let(:conn) { instance_double(Faraday::Connection) }

    before { allow(client).to receive(:connection).and_return(conn) }

    context "when the API returns llm_key with raw_key and host (current format)" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_faraday_response(
            status: 200,
            body: {
              code: 200,
              msg: "success",
              data: {
                llm_key: { raw_key: "ABSK1abc123", host: "https://develop.api.clackyai.com" }
              }
            }
          )
        )
      end

      it "returns success with raw_key as llm_key" do
        result = client.fetch_workspace_keys
        expect(result[:success]).to be true
        expect(result[:llm_key]).to eq("ABSK1abc123")
      end

      it "sets anthropic_format to false (ABSK keys use Bedrock Converse format)" do
        expect(client.fetch_workspace_keys[:anthropic_format]).to be false
      end

      it "sets a non-nil model_name string" do
        result = client.fetch_workspace_keys
        expect(result[:model_name]).to be_a(String)
        expect(result[:model_name]).not_to be_empty
      end

      it "sets base_url from the host field in the response" do
        result = client.fetch_workspace_keys
        expect(result[:base_url]).to eq("https://develop.api.clackyai.com")
      end
    end

    context "when llm_key is a plain string" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_faraday_response(
            status: 200,
            body: {
              code: 200,
              msg: "success",
              data: { llm_key: "sk-raw-token-abc123" }
            }
          )
        )
      end

      it "uses the string value directly as llm_key" do
        result = client.fetch_workspace_keys
        expect(result[:success]).to be true
        expect(result[:llm_key]).to eq("sk-raw-token-abc123")
      end
    end

    context "when llm_key hash contains raw_key field" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_faraday_response(
            status: 200,
            body: {
              code: 200,
              msg: "success",
              data: {
                llm_key: { key_id: "kid_001", name: "default", raw_key: "lk_raw_secret" }
              }
            }
          )
        )
      end

      it "prefers raw_key over key_id when both present" do
        result = client.fetch_workspace_keys
        expect(result[:success]).to be true
        expect(result[:llm_key]).to eq("lk_raw_secret")
      end
    end
  end

  # ── API-level failure responses ────────────────────────────────────────────

  describe "#fetch_workspace_keys — API errors" do
    let(:conn) { instance_double(Faraday::Connection) }

    before { allow(client).to receive(:connection).and_return(conn) }

    context "when the API returns code != 200" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_faraday_response(status: 200, body: { code: 400, msg: "workspace not found" })
        )
      end

      it "returns failure with the API msg" do
        result = client.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/workspace not found/)
      end
    end

    context "when llm_key is null in the response data" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_faraday_response(
            status: 200,
            body: { code: 200, msg: "success", data: { llm_key: nil } }
          )
        )
      end

      it "returns failure describing the missing key" do
        result = client.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/no llm key/i)
      end
    end

    context "when HTTP 401 is returned" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_faraday_response(status: 401, body: { msg: "Unauthorized" })
        )
      end

      it "returns failure with the HTTP status code" do
        result = client.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/401/)
      end
    end

    context "when the response is not valid JSON" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_faraday_response(status: 200, body: "<html>error page</html>")
        )
      end

      it "returns failure with a JSON-related error message" do
        result = client.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/json/i)
      end
    end
  end

  # ── Network / transport errors ─────────────────────────────────────────────

  describe "#fetch_workspace_keys — network errors" do
    let(:conn) { instance_double(Faraday::Connection) }

    before { allow(client).to receive(:connection).and_return(conn) }

    context "when the connection is refused" do
      before do
        allow(conn).to receive(:get).and_raise(Faraday::ConnectionFailed.new("Connection refused"))
      end

      it "returns failure with a connection error message" do
        result = client.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/connection/i)
      end
    end

    context "when the request times out" do
      before do
        allow(conn).to receive(:get).and_raise(Faraday::TimeoutError)
      end

      it "returns failure mentioning a timeout" do
        result = client.fetch_workspace_keys
        expect(result[:success]).to be false
        expect(result[:error]).to match(/timed out|timeout/i)
      end
    end
  end
end
