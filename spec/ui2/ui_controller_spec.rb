# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Clacky::UI2::UIController do
  describe '#stop' do
    it 'passes clear_screen through to layout cleanup' do
      controller = described_class.new
      layout = instance_double(Clacky::UI2::LayoutManager)
      controller.instance_variable_set(:@layout, layout)

      expect(layout).to receive(:cleanup_screen).with(clear_screen: true)

      controller.stop(clear_screen: true)
    end
  end

  describe '#filter_thinking_tags' do
    let(:controller) { described_class.new }

    it 'removes <think>...</think> tags' do
      content = "<think>\nThe user is asking about X\n</think>\n\nHere is my response."
      result = controller.send(:filter_thinking_tags, content)
      expect(result).to eq("Here is my response.")
    end

    it 'removes <thinking>...</thinking> tags' do
      content = "<thinking>\nLet me think about this\n</thinking>\n\nThe answer is 42."
      result = controller.send(:filter_thinking_tags, content)
      expect(result).to eq("The answer is 42.")
    end

    it 'handles multiline thinking content' do
      content = "<think>\nLine 1\nLine 2\nLine 3\n</think>\n\nActual content here."
      result = controller.send(:filter_thinking_tags, content)
      expect(result).to eq("Actual content here.")
    end

    it 'returns original content when no thinking tags present' do
      content = "Just a normal response without thinking tags."
      result = controller.send(:filter_thinking_tags, content)
      expect(result).to eq(content)
    end

    it 'handles nil content' do
      result = controller.send(:filter_thinking_tags, nil)
      expect(result).to be_nil
    end

    it 'handles empty content' do
      result = controller.send(:filter_thinking_tags, "")
      expect(result).to eq("")
    end

    it 'handles content with only thinking tags' do
      content = "<think>Just thinking here</think>"
      result = controller.send(:filter_thinking_tags, content)
      expect(result).to eq("")
    end
  end
end
