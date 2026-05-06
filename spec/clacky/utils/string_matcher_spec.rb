# frozen_string_literal: true

RSpec.describe Clacky::Utils::StringMatcher do
  describe ".find_match" do
    it "returns nil when nothing matches" do
      expect(described_class.find_match("hello world", "xyz")).to be_nil
    end

    it "matches exact substrings and counts occurrences" do
      result = described_class.find_match("foo bar foo baz foo", "foo")
      expect(result[:matched_string]).to eq("foo")
      expect(result[:occurrences]).to eq(3)
    end

    it "counts needles containing regex metacharacters correctly" do
      # If the counter used Regexp without escaping, "." would be treated as
      # 'any character' and the count would be wrong.
      content = "a.b a.b a*b"
      result = described_class.find_match(content, "a.b")
      expect(result[:occurrences]).to eq(2)
    end

    it "falls back to trim when old_string has stray whitespace" do
      content = "alpha beta gamma"
      result = described_class.find_match(content, "  beta  ")
      expect(result[:matched_string]).to eq("beta")
    end

    it "does not raise on content with invalid UTF-8 bytes" do
      # \xFF is not a valid UTF-8 lead byte.
      bad = (+"prefix \xFF needle tail").force_encoding("UTF-8")
      expect(bad.valid_encoding?).to be false

      expect {
        described_class.find_match(bad, "needle")
      }.not_to raise_error

      result = described_class.find_match(bad, "needle")
      expect(result[:matched_string]).to eq("needle")
      expect(result[:occurrences]).to eq(1)
    end

    it "does not raise when old_string itself has invalid UTF-8 bytes" do
      bad_needle = (+"needle\xFF").force_encoding("UTF-8")
      expect {
        described_class.find_match("haystack without it", bad_needle)
      }.not_to raise_error
    end

    it "performs smart line matching across indentation differences" do
      content = "def foo\n    do_work\nend\n"
      old     = "def foo\n  do_work\nend\n"
      result  = described_class.find_match(content, old)
      expect(result).not_to be_nil
      expect(result[:matched_string]).to include("do_work")
    end
  end

  describe ".count_occurrences" do
    it "returns 0 for empty needle" do
      expect(described_class.count_occurrences("abc", "")).to eq(0)
    end

    it "counts non-overlapping matches" do
      expect(described_class.count_occurrences("aaaa", "aa")).to eq(2)
    end

    it "treats regex metacharacters literally" do
      expect(described_class.count_occurrences("a.b a.b axb", "a.b")).to eq(2)
    end
  end
end
