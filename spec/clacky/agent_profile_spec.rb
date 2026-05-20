# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::AgentProfile do
  describe "admin profile" do
    let(:profile) { described_class.load("admin") }

    it "loads an explicit tool allowlist" do
      expect(profile.allowed_tools).to include("nokno_admin")
      expect(profile.allowed_tools).not_to include("terminal")
    end

    it "enforces tool access by profile" do
      expect(profile.tool_allowed?("nokno_admin")).to be true
      expect(profile.tool_allowed?("terminal")).to be false
    end
  end
end
