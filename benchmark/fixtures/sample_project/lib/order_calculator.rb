# frozen_string_literal: true

module SampleProject
  class OrderCalculator
    def initialize(items)
      @items = items
    end

    def calculateTotal
      @items.sum { |item| item[:price] * item[:quantity] }
    end

    def calculateTotalWithTax(tax_rate)
      subtotal = calculateTotal
      subtotal * (1 + tax_rate)
    end

    def applyDiscount(discount_percent)
      total = calculateTotal
      total * (1 - discount_percent / 100.0)
    end
  end
end
