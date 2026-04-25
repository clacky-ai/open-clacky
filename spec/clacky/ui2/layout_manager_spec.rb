# frozen_string_literal: true

require "clacky/ui2/layout_manager"

RSpec.describe Clacky::UI2::LayoutManager do
  # Tiny stub standing in for Components::InputArea during tests.
  # The only layout-relevant method is +required_height+; everything else
  # is a no-op since we're testing output-area paint semantics, not input
  # rendering.
  let(:stub_input_area) do
    Class.new do
      attr_accessor :row
      def initialize(height: 2); @height = height; end
      def required_height; @height; end
      def paused?; false; end
      def clear; end
      def set_tips(*); end
      def render(start_row:, width: nil); end
      def update_sessionbar(**_); end
      def set_skill_loader(_, _); end
      def set_agent(_, _); end
      def handle_key(_); { action: nil }; end
      def empty?; true; end
      def pause; end
      def resume; end
      def show_user_tip(**_); end
      def clear_user_tip; end
    end.new
  end

  # Replace the manager's screen with a controlled instance, and capture
  # every raw byte the manager writes to $stdout so we can assert on the
  # exact sequence of paints / cursor moves.
  let(:captured_writes) { [] }

  def build_manager(width: 80, height: 20)
    lm = described_class.new(input_area: stub_input_area)
    lm.screen.instance_variable_set(:@width, width)
    lm.screen.instance_variable_set(:@height, height)
    lm.send(:calculate_layout)
    lm
  end

  around(:each) do |ex|
    @captured = []
    captured = @captured
    # Intercept Kernel#print globally so every print — including the
    # implicit one inside ScreenBuffer.move_cursor — is recorded.
    Kernel.send(:alias_method, :__orig_print_for_spec, :print)
    Kernel.send(:define_method, :print) do |*args|
      args.each { |a| captured << a.to_s }
    end
    begin
      ex.run
    ensure
      Kernel.send(:alias_method, :print, :__orig_print_for_spec)
      Kernel.send(:remove_method, :__orig_print_for_spec)
    end
  end

  # Extract only the strings that look like real content (not ANSI escapes,
  # not bare newlines) in the order they were printed.
  def printed_content
    @captured.reject { |w| w.start_with?("\e") || w == "\n" }
  end

  describe "#replace_entry on a non-tail entry" do
    it "does not clobber entries appended after it (duplicate-output regression)" do
      # Scenario: the progress-ticker bug.
      #   1. tool_call line is appended (row N)
      #   2. a progress line is appended (row N+1) — currently the tail
      #   3. a tool_result line is appended (row N+2) — now progress is NOT the tail
      #   4. progress ticker fires and calls replace_entry on the progress id
      #
      # Before the fix, step 4 computed start_row = @output_row - old_n,
      # which pointed at the *tool_result* row instead of the progress
      # row. The new progress frame was painted there, clobbering the
      # tool_result visually; when the output area later scrolled, both
      # the stale progress line and the overwritten tool_result ended up
      # in terminal scrollback — the user saw every line appear twice.
      lm = build_manager

      _tool_call_id = lm.append("[->] grep('x') in .")
      progress_id   = lm.append("[.] Running... (0s)")
      _result_id    = lm.append("[OK] Found 2 matches")

      @captured.clear  # Focus on writes produced by the replace call.
      lm.replace_entry(progress_id, "[.] Running... (1s)")

      content = printed_content
      # After the ticker fires, all three logical entries must still be
      # visible on screen (even if the manager chose to full-repaint to
      # preserve correctness).
      expect(content).to include("[->] grep('x') in .")
      expect(content).to include("[.] Running... (1s)")
      expect(content).to include("[OK] Found 2 matches")
      # And the stale progress frame must NOT be written again.
      expect(content).not_to include("[.] Running... (0s)")
    end

    it "preserves the original tail's @output_row so subsequent appends go below it" do
      lm = build_manager

      lm.append("A")
      progress_id = lm.append("P-0s")
      lm.append("B")
      row_before = lm.instance_variable_get(:@output_row)

      lm.replace_entry(progress_id, "P-1s")
      row_after = lm.instance_variable_get(:@output_row)

      # The tail hasn't moved; @output_row still points one past "B",
      # not back to where the non-tail progress ended. A regression here
      # means the next append will overlap existing lines.
      expect(row_after).to eq(row_before)
    end
  end

  describe "#replace_entry on the tail entry" do
    it "still uses the fast in-place repaint (no full rebuild)" do
      lm = build_manager

      lm.append("A")
      tail_id = lm.append("B")

      @captured.clear
      lm.replace_entry(tail_id, "B-updated")

      content = printed_content
      # Tail replace should only re-emit the changed entry (plus the
      # fixed-area repaint), not every live entry. "A" must not appear.
      expect(content).to include("B-updated")
      expect(content).not_to include("A")
    end
  end
end
