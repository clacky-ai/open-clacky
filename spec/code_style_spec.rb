# frozen_string_literal: true

RSpec.describe "Code style: no standalone private keyword" do
  # Find all Ruby source files under lib/ and bin/
  RUBY_SOURCE_FILES = Dir.glob(File.expand_path("../../{lib,bin}/**/*.rb", __FILE__)).sort.freeze

  it "has at least one Ruby source file to check" do
    expect(RUBY_SOURCE_FILES).not_to be_empty
  end

  RUBY_SOURCE_FILES.each do |path|
    it "#{path.sub(Dir.pwd + "/", "")} has no standalone `private` keyword" do
      lines = File.readlines(path)
      violations = []

      lines.each_with_index do |line, index|
        # Match lines where `private` appears alone (possibly indented),
        # but NOT `private def`, `private attr_*`, `private_class_method`, etc.
        stripped = line.strip
        if stripped == "private" || stripped.match?(/^private\s*#/)
          violations << "  line #{index + 1}: #{line.rstrip}"
        end
      end

      expect(violations).to be_empty,
        "Found standalone `private` keyword — use `private def method_name` instead:\n#{violations.join("\n")}"
    end
  end
end
