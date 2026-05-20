# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Clacky::Tools::NoknoAdmin do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "validates required fields for build_release" do
      expect do
        tool.execute(action: "build_release")
      end.to raise_error(Clacky::ToolCallError, /image_tag is required/)
    end

    it "runs the helper script with structured environment" do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(anything).and_return(true)
      allow(Open3).to receive(:capture3).and_return([
        JSON.generate({ ok: true, message: "built" }),
        "",
        instance_double(Process::Status, success?: true)
      ])

      result = tool.execute(action: "build_release", image_tag: "oc-v1.2.3-nokno.1")

      expect(result[:ok]).to be true
      expect(result[:message]).to eq("built")
      expect(Open3).to have_received(:capture3).with(
        hash_including(
          "NOKNO_ADMIN_ACTION" => "build_release",
          "NOKNO_IMAGE_TAG" => "oc-v1.2.3-nokno.1"
        ),
        "bash",
        anything
      )
    end

    it "raises a tool error when helper execution fails" do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(anything).and_return(true)
      allow(Open3).to receive(:capture3).and_return([
        "",
        "helper failed",
        instance_double(Process::Status, success?: false)
      ])

      expect do
        tool.execute(action: "release_status")
      end.to raise_error(Clacky::ToolCallError, /helper failed/)
    end

    it "supports health_audit without requiring an image tag" do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(anything).and_return(true)
      allow(Open3).to receive(:capture3).and_return([
        JSON.generate({ ok: true, message: "audit ok", failed_users: [] }),
        "",
        instance_double(Process::Status, success?: true)
      ])

      result = tool.execute(action: "health_audit", target_users: %w[demo alice])

      expect(result[:ok]).to be true
      expect(result[:message]).to eq("audit ok")
      expect(Open3).to have_received(:capture3).with(
        hash_including(
          "NOKNO_ADMIN_ACTION" => "health_audit",
          "NOKNO_TARGET_USERS_JSON" => JSON.generate(%w[demo alice])
        ),
        "bash",
        anything
      )
    end
  end
end
