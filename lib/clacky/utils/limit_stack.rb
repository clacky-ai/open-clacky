# frozen_string_literal: true

module Clacky
  module Utils
    # Auto-rolling fixed-size array
    # Automatically discards oldest elements when size limit is exceeded
    class LimitStack
      attr_reader :max_size, :items

      def initialize(max_size: 5000)
        @max_size = max_size
        @items = []
      end

      # Add elements (supports single or multiple)
      def push(*elements)
        elements.each do |element|
          @items << element
          trim_if_needed
        end
        self
      end
      alias_method :<<, :push

      # Add multi-line text (split by lines and add)
      def push_lines(text)
        return self if text.nil? || text.empty?

        lines = text.is_a?(Array) ? text : text.lines
        lines.each { |line| push(line) }
        self
      end

      # Remove and return the last element
      def pop
        @items.pop
      end

      # Get last N elements
      def last(n = nil)
        n ? @items.last(n) : @items.last
      end

      # Get all elements
      def to_a
        @items.dup
      end

      # Convert to string (for text content)
      def to_s
        @items.join
      end

      # Current size
      def size
        @items.size
      end

      # Check if empty
      def empty?
        @items.empty?
      end

      # Clear all elements
      def clear
        @items.clear
        self
      end

      # Iterate over elements
      def each(&block)
        @items.each(&block)
      end


      def trim_if_needed
        if @items.size > @max_size
          # Remove oldest elements, keep only the latest max_size items
          @items.shift(@items.size - @max_size)
        end
      end
    end
  end
end
