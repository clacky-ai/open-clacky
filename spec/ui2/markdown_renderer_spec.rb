# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/markdown_renderer"

RSpec.describe Clacky::UI2::MarkdownRenderer do
  describe ".render" do
    it "returns content unchanged when nil or empty" do
      expect(described_class.render(nil)).to be_nil
      expect(described_class.render("")).to eq("")
    end

    it "renders headers without raising" do
      expect { described_class.render("# Hello") }.not_to raise_error
      expect(described_class.render("# Hello")).to include("Hello")
    end

    # Regression: rouge 3.x calls CGI.parse internally, which was removed in Ruby 4.0.
    # Pinning rouge to >= 3.14, < 5.0 lets bundler pick rouge 4.x on Ruby >= 2.7,
    # which dropped the CGI.parse dependency. Without that pin, this test would
    # fail with NoMethodError on Ruby 4.0+.
    it "renders fenced code blocks without raising (rouge + Ruby 4.0 regression)" do
      markdown = <<~MD
        ```ruby
        def hello
          puts "world"
        end
        ```
      MD

      raised = nil
      original = TTY::Markdown.method(:parse)
      allow(TTY::Markdown).to receive(:parse) do |*args, **kwargs|
        begin
          original.call(*args, **kwargs)
        rescue StandardError, NoMethodError => e
          raised = e
          raise
        end
      end

      result = described_class.render(markdown)

      expect(raised).to be_nil,
        "TTY::Markdown.parse raised #{raised&.class}: #{raised&.message} — likely rouge/CGI.parse incompatibility"
      expect(result).to include("hello")
      expect(result).to include("world")
    end
  end

  describe ".markdown?" do
    it "detects code blocks" do
      expect(described_class.markdown?("```ruby\nx\n```")).to be true
    end

    it "detects headers" do
      expect(described_class.markdown?("# Title")).to be true
    end

    it "returns false for plain text" do
      expect(described_class.markdown?("just a plain sentence")).to be false
    end

    it "returns false for nil or empty" do
      expect(described_class.markdown?(nil)).to be false
      expect(described_class.markdown?("")).to be false
    end
  end
end
