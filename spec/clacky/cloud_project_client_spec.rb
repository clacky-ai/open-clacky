# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/clacky/cloud_project_client"

# Helper: build a fake Faraday response object
def fake_project_response(status:, body:)
  double("Faraday::Response", status: status, body: body.is_a?(Hash) ? JSON.generate(body) : body.to_s)
end

RSpec.describe Clacky::CloudProjectClient do
  let(:workspace_key) { "clacky_ak_test_key" }
  let(:base_url)      { "https://api.clacky.ai" }
  let(:project_id)    { "019d41be-8a72-725d-b62b-2cb900ec139d" }

  subject(:client) { described_class.new(workspace_key, base_url: base_url) }

  # Shared sample project data returned by the API
  let(:sample_project) do
    {
      "id"           => project_id,
      "name"         => "my-app",
      "workspace_id" => "019b5377-7284-7996-bc33-e93d75dd21ed",
      "categorized_config" => {
        "auth"   => { "CLACKY_AUTH_CLIENT_ID" => "abc", "CLACKY_AUTH_CLIENT_SECRET" => "secret",
                      "CLACKY_AUTH_HOST" => "https://integrate-api.clackypaas.com" },
        "email"  => { "CLACKY_EMAIL_API_KEY" => "em-key", "CLACKY_EMAIL_SMTP_DOMAIN" => "mail.clacky.ai",
                      "CLACKY_EMAIL_SMTP_PORT" => 25 },
        "llm"    => { "CLACKY_LLM_API_KEY" => "sk-llm", "CLACKY_LLM_BASE_URL" => "https://proxy.clacky.ai" },
        "stripe" => { "CLACKY_STRIPE_SECRET_KEY" => "sk_test_xxx" }
      },
      "subscription" => { "status" => "PAID" }
    }
  end

  # ── Input validation (no HTTP calls) ──────────────────────────────────────

  describe "input validation" do
    context "when workspace_api_key is blank" do
      subject { described_class.new("", base_url: base_url) }

      it "returns failure on create_project" do
        result = subject.create_project(name: "test")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/required/i)
      end

      it "returns failure on get_project" do
        result = subject.get_project(project_id)
        expect(result[:success]).to be false
        expect(result[:error]).to match(/required/i)
      end

      it "returns failure on list_projects" do
        result = subject.list_projects
        expect(result[:success]).to be false
        expect(result[:error]).to match(/required/i)
      end
    end

    context "when base_url is blank" do
      subject { described_class.new(workspace_key, base_url: "") }

      it "returns failure on create_project" do
        result = subject.create_project(name: "test")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/required/i)
      end
    end
  end

  # ── #create_project ────────────────────────────────────────────────────────

  describe "#create_project" do
    let(:conn) { instance_double(Faraday::Connection) }

    # Build a fake Faraday request object that accepts headers/body assignment
    let(:fake_req) do
      req = double("Faraday::Request")
      allow(req).to receive(:headers).and_return({})
      allow(req).to receive(:body=)
      req
    end

    before { allow(client).to receive(:connection).and_return(conn) }

    context "when API returns success (code 0)" do
      before do
        allow(conn).to receive(:post).and_yield(fake_req).and_return(
          fake_project_response(status: 200, body: { "code" => 0, "message" => "success", "data" => sample_project })
        )
      end

      it "returns success: true" do
        result = client.create_project(name: "my-app")
        expect(result[:success]).to be true
      end

      it "returns the project data" do
        result = client.create_project(name: "my-app")
        expect(result[:project]["id"]).to eq(project_id)
        expect(result[:project]["name"]).to eq("my-app")
      end

      it "includes categorized_config in the project data" do
        result = client.create_project(name: "my-app")
        expect(result[:project]["categorized_config"]).to include("auth", "llm")
      end
    end

    context "when API returns success (code 200)" do
      before do
        allow(conn).to receive(:post).and_yield(fake_req).and_return(
          fake_project_response(status: 200, body: { "code" => 200, "message" => "success", "data" => sample_project })
        )
      end

      it "also returns success: true for code 200" do
        result = client.create_project(name: "my-app")
        expect(result[:success]).to be true
      end
    end

    context "when API returns an error code" do
      before do
        allow(conn).to receive(:post).and_yield(fake_req).and_return(
          fake_project_response(status: 200, body: { "code" => 400, "message" => "project name already exists" })
        )
      end

      it "returns failure with the API message" do
        result = client.create_project(name: "my-app")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/project name already exists/)
      end
    end

    context "when HTTP 401 is returned" do
      before do
        allow(conn).to receive(:post).and_yield(fake_req).and_return(
          fake_project_response(status: 401, body: { "message" => "Unauthorized" })
        )
      end

      it "returns failure with the HTTP status code" do
        result = client.create_project(name: "my-app")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/401/)
      end
    end

    context "when response body is not valid JSON" do
      before do
        allow(conn).to receive(:post).and_yield(fake_req).and_return(
          fake_project_response(status: 200, body: "<html>error</html>")
        )
      end

      it "returns failure" do
        result = client.create_project(name: "my-app")
        expect(result[:success]).to be false
      end
    end

    context "when a network error occurs" do
      before do
        allow(conn).to receive(:post).and_raise(Faraday::ConnectionFailed.new("Connection refused"))
      end

      it "returns failure with a network error message" do
        result = client.create_project(name: "my-app")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/network error/i)
      end
    end

    context "when the request times out" do
      before do
        allow(conn).to receive(:post).and_raise(Faraday::TimeoutError)
      end

      it "returns failure mentioning a timeout" do
        result = client.create_project(name: "my-app")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/network error|timed out|timeout/i)
      end
    end
  end

  # ── #get_project ───────────────────────────────────────────────────────────

  describe "#get_project" do
    let(:conn) { instance_double(Faraday::Connection) }

    before { allow(client).to receive(:connection).and_return(conn) }

    context "when API returns project with PAID subscription" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_project_response(status: 200, body: { "code" => 0, "data" => sample_project })
        )
      end

      it "returns success: true" do
        result = client.get_project(project_id)
        expect(result[:success]).to be true
      end

      it "includes subscription in the project data" do
        result = client.get_project(project_id)
        expect(result[:project]["subscription"]["status"]).to eq("PAID")
      end

      it "includes categorized_config" do
        result = client.get_project(project_id)
        expect(result[:project]["categorized_config"]).to be_a(Hash)
      end
    end

    context "when project has no subscription (null)" do
      let(:project_no_sub) { sample_project.merge("subscription" => nil) }

      before do
        allow(conn).to receive(:get).and_return(
          fake_project_response(status: 200, body: { "code" => 0, "data" => project_no_sub })
        )
      end

      it "returns success: true with nil subscription" do
        result = client.get_project(project_id)
        expect(result[:success]).to be true
        expect(result[:project]["subscription"]).to be_nil
      end
    end

    context "when project is not found (HTTP 404)" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_project_response(status: 404, body: { "message" => "project not found" })
        )
      end

      it "returns failure with 404 in the error" do
        result = client.get_project("nonexistent-id")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/404/)
      end
    end

    context "when a network error occurs" do
      before do
        allow(conn).to receive(:get).and_raise(Faraday::ConnectionFailed.new("Connection refused"))
      end

      it "returns failure" do
        result = client.get_project(project_id)
        expect(result[:success]).to be false
        expect(result[:error]).to match(/network error/i)
      end
    end
  end

  # ── #list_projects ─────────────────────────────────────────────────────────

  describe "#list_projects" do
    let(:conn) { instance_double(Faraday::Connection) }

    before { allow(client).to receive(:connection).and_return(conn) }

    context "when API returns a list of projects (array format)" do
      let(:projects_list) { [sample_project, sample_project.merge("id" => "other-id", "name" => "other-app")] }

      before do
        allow(conn).to receive(:get).and_return(
          fake_project_response(status: 200, body: { "code" => 0, "data" => projects_list })
        )
      end

      it "returns success: true" do
        result = client.list_projects
        expect(result[:success]).to be true
      end

      it "returns an array of projects" do
        result = client.list_projects
        expect(result[:projects]).to be_an(Array)
        expect(result[:projects].length).to eq(2)
      end

      it "includes project name and id in each item" do
        result = client.list_projects
        expect(result[:projects].first["name"]).to eq("my-app")
        expect(result[:projects].first["id"]).to eq(project_id)
      end
    end

    context "when API returns projects in a paginated hash format ({ list: [...] })" do
      let(:projects_list) { [sample_project] }

      before do
        allow(conn).to receive(:get).and_return(
          fake_project_response(
            status: 200,
            body: { "code" => 0, "data" => { "list" => projects_list, "total" => 1 } }
          )
        )
      end

      it "extracts the list array from the response" do
        result = client.list_projects
        expect(result[:success]).to be true
        expect(result[:projects]).to be_an(Array)
        expect(result[:projects].length).to eq(1)
      end
    end

    context "when workspace has no projects (empty array)" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_project_response(status: 200, body: { "code" => 0, "data" => [] })
        )
      end

      it "returns success with an empty array" do
        result = client.list_projects
        expect(result[:success]).to be true
        expect(result[:projects]).to eq([])
      end
    end

    context "when API returns an error" do
      before do
        allow(conn).to receive(:get).and_return(
          fake_project_response(status: 200, body: { "code" => 403, "message" => "forbidden" })
        )
      end

      it "returns failure" do
        result = client.list_projects
        expect(result[:success]).to be false
        expect(result[:error]).to match(/forbidden/)
      end
    end

    context "when a network error occurs" do
      before do
        allow(conn).to receive(:get).and_raise(Faraday::ConnectionFailed.new("Connection refused"))
      end

      it "returns failure" do
        result = client.list_projects
        expect(result[:success]).to be false
        expect(result[:error]).to match(/network error/i)
      end
    end
  end
end
