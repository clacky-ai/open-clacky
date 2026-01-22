# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/components/output_area"

RSpec.describe Clacky::UI2::Components::OutputArea do
  let(:output_area) { described_class.new(height: 10) }

  before do
    # Suppress actual terminal output during tests
    allow(output_area).to receive(:print)
    allow(output_area).to receive(:flush)
  end

  describe "#append" do
    it "prints content to terminal" do
      expect(output_area).to receive(:print).with("Hello, World!")
      output_area.append("Hello, World!")
    end

    it "ignores nil content" do
      output_area.append(nil)
      # Should not raise and should not print
    end

    it "ignores empty content" do
      output_area.append("")
      # Should not raise and should not print
    end

    it "truncates long lines" do
      allow(TTY::Screen).to receive(:width).and_return(20)
      # Expect truncated output with "..."
      expect(output_area).to receive(:print) do |arg|
        expect(arg).to include("...")
        expect(arg.gsub(/\e\[[0-9;]*m/, "").length).to be <= 20
      end
      output_area.append("This is a very long line that exceeds the width")
    end
  end

  describe "#render" do
    it "is a no-op for natural scroll mode" do
      # render should not raise or do anything
      expect { output_area.render(start_row: 0) }.not_to raise_error
    end
  end

  describe "#clear" do
    it "is a no-op for natural scroll mode" do
      expect { output_area.clear }.not_to raise_error
    end
  end

  describe "legacy scroll methods" do
    it "scroll_up is a no-op" do
      expect { output_area.scroll_up(5) }.not_to raise_error
    end

    it "scroll_down is a no-op" do
      expect { output_area.scroll_down(5) }.not_to raise_error
    end

    it "scroll_to_top is a no-op" do
      expect { output_area.scroll_to_top }.not_to raise_error
    end

    it "scroll_to_bottom is a no-op" do
      expect { output_area.scroll_to_bottom }.not_to raise_error
    end
  end

  describe "#at_bottom?" do
    it "always returns true in natural scroll mode" do
      expect(output_area).to be_at_bottom
    end
  end

  describe "#scroll_percentage" do
    it "always returns 0.0 in natural scroll mode" do
      expect(output_area.scroll_percentage).to eq(0.0)
    end
  end

  describe "#visible_range" do
    it "returns range based on height" do
      range = output_area.visible_range
      expect(range[:start]).to eq(1)
      expect(range[:end]).to eq(10)
      expect(range[:total]).to eq(10)
    end
  end

  describe "#height" do
    it "can be read and written" do
      output_area.height = 20
      expect(output_area.height).to eq(20)
    end
  end
end
