# frozen_string_literal: true

require_relative "../lib/order_calculator"

RSpec.describe SampleProject::OrderCalculator do
  let(:items) do
    [
      { price: 10.0, quantity: 2 },
      { price: 5.0, quantity: 3 }
    ]
  end

  subject { described_class.new(items) }

  describe "#calculateTotal" do
    it "returns the sum of all item prices times quantities" do
      expect(subject.calculateTotal).to eq(35.0)
    end
  end
end
