# frozen_string_literal: true

require_relative "screen_buffer"
require_relative "output_buffer"
require_relative "../utils/encoding"

module Clacky
  module UI2
    # LayoutManager coordinates the split-screen layout:
    #   [ scrollable output area ]
    #   [ gap / todo / input (fixed) ]
    #
    # Responsibilities:
    # - Own an OutputBuffer (logical source of truth for output content).
    # - Translate buffer mutations into screen paints, handling:
    #   * Native terminal scrolling when output overflows the output area.
    #   * Committing scrolled lines to the buffer (so they are never repainted
    #     from the buffer again — prevents the classic "double render on
    #     scroll up" bug).
    # - Keep the fixed area (gap + todo + input) pinned at the bottom of the
    #   screen, repainting it only when it is dirty.
    #
    # Public API (id-based, preferred):
    #   append(content, kind: :text) -> id     # add entry, returns id
    #   replace_entry(id, content)              # edit entry's content
    #   remove_entry(id)                        # drop entry
    #
    # Legacy API (shims, still used by InlineInput / progress):
    #   append_output(content) -> id            # alias for append
    #   update_last_line(content, old_n, id: nil)  # uses id if given
    #   remove_last_line(n, id: nil)               # uses id if given
    class LayoutManager
      attr_reader :screen, :input_area, :todo_area, :buffer

      def initialize(input_area:, todo_area: nil)
        @screen       = ScreenBuffer.new
        @input_area   = input_area
        @todo_area    = todo_area
        @buffer       = OutputBuffer.new
        @render_mutex = Mutex.new

        @output_row              = 0  # Next output row to paint into
        @last_fixed_area_height  = 0
        @fullscreen_mode         = false
        @resize_pending          = false

        # Tracks the most recent append's id so the legacy
        # update_last_line / remove_last_line shims still work without the
        # caller threading an id through.
        @last_append_id          = nil

        calculate_layout
        setup_resize_handler
      end

      # -----------------------------------------------------------------------
      # Layout math
      # -----------------------------------------------------------------------

      def calculate_layout
        todo_height  = @todo_area&.height || 0
        input_height = @input_area.required_height
        gap_height   = 1

        @output_height = screen.height - gap_height - todo_height - input_height
        @output_height = [1, @output_height].max

        @gap_row   = @output_height
        @todo_row  = @gap_row + gap_height
        @input_row = @todo_row + todo_height

        @input_area.row = @input_row
      end

      def fixed_area_height
        todo_h  = @todo_area&.height || 0
        input_h = @input_area.required_height
        1 + todo_h + input_h
      end

      def fixed_area_start_row
        screen.height - fixed_area_height
      end

      # -----------------------------------------------------------------------
      # Public output API (id-based)
      # -----------------------------------------------------------------------

      # Append an output entry. Returns the entry id so callers can later
      # replace_entry / remove_entry. Multi-line content is wrapped and
      # stored as one logical entry.
      def append(content, kind: :text)
        return nil if content.nil?
        content = sanitize(content)

        @render_mutex.synchronize do
          lines = wrap_content_to_lines(content)
          id    = @buffer.append(lines, kind: kind)
          @last_append_id = id

          paint_new_lines(lines) unless @fullscreen_mode
          render_fixed_areas
          screen.flush
          id
        end
      end

      # Legacy: append, return id (callers that ignore it still work).
      def append_output(content)
        append(content)
      end

      # Replace an existing entry's content. The screen is updated in place
      # if the entry still lives in the output area; otherwise (committed
      # to scrollback) this is a silent no-op.
      def replace_entry(id, content)
        return if id.nil? || content.nil?
        content = sanitize(content)

        @render_mutex.synchronize do
          entry = @buffer.entry_by_id(id)
          return if entry.nil? || entry.committed

          old_lines = entry.lines.dup
          new_lines = wrap_content_to_lines(content)
          @buffer.replace(id, new_lines)

          unless @fullscreen_mode
            # repaint_entry_in_place relies on the entry being the tail of
            # live entries (it computes the entry's top row from @output_row
            # and old height). When the entry is NOT the tail — e.g. a
            # background progress ticker fires after a newer entry was
            # appended — that assumption silently corrupts the screen:
            # the new frame gets painted at the tail's row, clobbering the
            # latest log line, and @output_row is reset to a position that
            # predates appended-but-still-live entries. On next scroll,
            # those stale-now-present rows end up in terminal scrollback as
            # duplicated lines (the user-visible "output repeats" bug).
            #
            # For non-tail replaces, fall back to a full rebuild of the
            # output area from the buffer. Slower, but correct regardless
            # of where the entry lives.
            is_tail = @buffer.live_entries.last&.id == id
            if is_tail
              repaint_entry_in_place(entry, old_lines, new_lines)
            else
              render_output_from_buffer
            end
          end
          render_fixed_areas
          screen.flush
        end
      end

      # Is this id still a live (not yet committed to scrollback) entry?
      # Cheap probe callers use before deciding between replace vs append.
      def live_entry?(id)
        return false if id.nil?
        @buffer.live?(id)
      end

      # Remove an entry. If it's the last live entry, the screen area it
      # occupied is cleared and the output cursor rolls back.
      def remove_entry(id)
        return if id.nil?

        @render_mutex.synchronize do
          entry = @buffer.entry_by_id(id)
          return if entry.nil? || entry.committed

          height = entry.height
          # Check whether this entry is the tail of live entries. Only tail
          # removal is cheap — mid-buffer removal would require a full
          # output repaint. In practice only the progress / inline-input
          # entries are removed, and they are always the tail.
          is_tail = @buffer.live_entries.last&.id == id

          @buffer.remove(id)
          @last_append_id = nil if @last_append_id == id

          unless @fullscreen_mode
            if is_tail
              clear_tail_rows(height)
            else
              # Non-tail removal: rebuild the entire output area from buffer
              render_output_from_buffer
            end
          end

          render_fixed_areas
          screen.flush
        end
      end

      # -----------------------------------------------------------------------
      # Legacy shims (kept for InlineInput + other callers that don't carry ids)
      # -----------------------------------------------------------------------

      # Update the most recently appended entry. Prefer passing +id:+; when
      # omitted the last-append id is used. +old_line_count+ is ignored
      # (buffer knows the true height).
      def update_last_line(content, old_line_count = nil, id: nil)
        target = id || @last_append_id
        replace_entry(target, content) if target
      end

      # Remove the most recently appended entry (or the given id).
      def remove_last_line(line_count = 1, id: nil)
        target = id || @last_append_id
        remove_entry(target) if target
      end

      # -----------------------------------------------------------------------
      # Paint primitives (private)
      # -----------------------------------------------------------------------

      # Paint fresh lines into the output area, scrolling via native \n when
      # we reach the fixed area. CRUCIAL INVARIANT: every time we scroll,
      # we tell the buffer "N oldest live lines just moved into scrollback"
      # so they are NEVER re-painted from the buffer again. This is what
      # eliminates the double-render bug.
      private def paint_new_lines(lines)
        max_output_row = fixed_area_start_row

        lines.each do |line|
          if @output_row >= max_output_row
            # Scroll the terminal by emitting a real \n at the very bottom.
            # That pushes the top visible row into the native scrollback
            # buffer — exactly where the user will see it on scroll-up.
            screen.move_cursor(screen.height - 1, 0)
            print "\n"

            # Tell the buffer one line of live content just left the screen.
            # Committed entries become untouchable, so a later full repaint
            # (resize, fixed-area height change, fullscreen exit) will NOT
            # re-emit them and duplicate them in scrollback.
            @buffer.commit_oldest_lines(1)

            @output_row = max_output_row - 1

            # The fixed area got scrolled up too — restore it. Don't trigger
            # an output rebuild; the buffer's tail hasn't changed.
            render_fixed_areas(skip_buffer_rerender: true)
          end

          screen.move_cursor(@output_row, 0)
          screen.clear_line
          print line
          @output_row += 1
        end
      end

      # Repaint a single entry in place after its content changed.
      # Handles both grow and shrink. If the new content would overflow
      # into the fixed area, we scroll up to make room (same rules as
      # paint_new_lines — scrolled rows get committed to scrollback).
      private def repaint_entry_in_place(entry, old_lines, new_lines)
        old_n = old_lines.length
        new_n = new_lines.length
        return if @output_row == 0

        start_row = @output_row - old_n
        start_row = 0 if start_row < 0

        max_output_row = fixed_area_start_row

        # Grow + would overflow → scroll first
        if new_n > old_n
          needed_end = start_row + new_n
          if needed_end > max_output_row
            overflow = needed_end - max_output_row
            overflow.times do
              screen.move_cursor(screen.height - 1, 0)
              print "\n"
              @buffer.commit_oldest_lines(1)
            end
            start_row      -= overflow
            start_row       = 0 if start_row < 0
            @output_row     = [start_row + old_n, max_output_row].min
            render_fixed_areas(skip_buffer_rerender: true)
          end
        end

        # Clear the rows the entry currently occupies
        (start_row...@output_row).each do |row|
          screen.move_cursor(row, 0)
          screen.clear_line
        end

        # Paint the new content
        cur = start_row
        new_lines.each do |line|
          screen.move_cursor(cur, 0)
          print line
          cur += 1
        end
        @output_row = start_row + new_n

        # If content shrank, extra rows below may still hold the old content
        # if they were outside the cleared range — but since we cleared the
        # full old span above, nothing extra is needed here.
      end

      # Clear the last N rows of the output area (used by remove_entry on tail).
      private def clear_tail_rows(n)
        return if n <= 0 || @output_row == 0

        start_row = @output_row - n
        start_row = 0 if start_row < 0

        (start_row...@output_row).each do |row|
          screen.move_cursor(row, 0)
          screen.clear_line
        end
        @output_row = start_row
      end

      # Repaint the entire output area from the buffer's live entries.
      # Only called on layout changes (resize, fixed-area height change,
      # /clear, fullscreen exit) — never on a normal append path.
      private def render_output_from_buffer
        max_output_row = fixed_area_start_row

        # Wipe the output area
        (0...max_output_row).each do |row|
          screen.move_cursor(row, 0)
          screen.clear_line
        end

        # Fill from the buffer's tail (live lines only — committed lines
        # are already in terminal scrollback and MUST NOT be repainted).
        lines = @buffer.tail_lines(max_output_row)
        @output_row = 0
        lines.each do |line|
          screen.move_cursor(@output_row, 0)
          print line
          @output_row += 1
        end
      end

      # Wrap user content into screen-width visual lines using the existing
      # ANSI-aware helper. Guarantees at least one line (possibly empty).
      private def wrap_content_to_lines(content)
        raw_lines = content.split("\n", -1)
        wrapped   = []
        raw_lines.each do |rl|
          wrapped.concat(wrap_long_line(rl))
        end
        wrapped = [""] if wrapped.empty?
        wrapped
      end

      private def sanitize(content)
        return content if content.valid_encoding?
        Clacky::Utils::Encoding.sanitize_utf8(content)
      end

      # -----------------------------------------------------------------------
      # Lifecycle + layout
      # -----------------------------------------------------------------------

      def initialize_screen
        screen.clear_screen
        screen.hide_cursor
        @output_row = 0
        render_all
      end

      def cleanup_screen
        @render_mutex.synchronize do
          fixed_start = fixed_area_start_row
          (fixed_start...screen.height).each do |row|
            screen.move_cursor(row, 0)
            screen.clear_line
          end
          screen.move_cursor([@output_row, 0].max, 0)
          print "\r"
          screen.show_cursor
          screen.flush
        end
      end

      # /clear: wipe output area + buffer, keep fixed area.
      def clear_output
        @render_mutex.synchronize do
          max_row = fixed_area_start_row
          (0...max_row).each do |row|
            screen.move_cursor(row, 0)
            screen.clear_line
          end
          @output_row     = 0
          @last_append_id = nil
          @buffer.clear
          render_fixed_areas
          screen.flush
        end
      end

      # Recalculate layout after input height changed. If the layout moved,
      # clear the old fixed area rows and re-render at the new position.
      def recalculate_layout
        @render_mutex.synchronize do
          old_gap_row   = @gap_row
          old_input_row = @input_row

          calculate_layout

          if @input_row != old_input_row
            ([old_gap_row, 0].max...screen.height).each do |row|
              screen.move_cursor(row, 0)
              screen.clear_line
            end

            if input_area.paused?
              # Input paused (InlineInput active) — fixed area shrank, so the
              # cleared rows are now part of the output area. Repaint from
              # buffer to fill them in.
              render_output_from_buffer
            else
              render_fixed_areas
            end
            screen.flush
          end
        end
      end

      def render_all
        @render_mutex.synchronize { render_all_internal }
      end

      def render_output
        @render_mutex.synchronize do
          render_fixed_areas
          screen.flush
        end
      end

      def render_input
        @render_mutex.synchronize do
          render_fixed_areas
          screen.flush
        end
      end

      def rerender_all
        @render_mutex.synchronize do
          screen.clear_screen
          render_output_from_buffer
          render_fixed_areas
          screen.flush
        end
      end

      # Restore cursor to input area (used after dialogs).
      def restore_cursor_to_input
        input_row = fixed_area_start_row + 1 + (@todo_area&.height || 0)
        input_area.position_cursor(input_row)
        screen.show_cursor
      end

      # Position cursor for inline input in output area.
      def position_inline_input_cursor(inline_input)
        return unless inline_input
        width = screen.width
        wrap_row, wrap_col = inline_input.cursor_position_for_display(width)
        line_count = inline_input.line_count(width)

        cursor_row = @output_row - line_count + wrap_row
        cursor_col = wrap_col
        screen.move_cursor(cursor_row, cursor_col)
        screen.flush
      end

      # Update todos display; recalculates layout if height changed.
      def update_todos(todos)
        return unless @todo_area

        @render_mutex.synchronize do
          old_height  = @todo_area.height
          old_gap_row = @gap_row

          @todo_area.update(todos)
          new_height = @todo_area.height

          if old_height != new_height
            calculate_layout
            ([old_gap_row, 0].max...screen.height).each do |row|
              screen.move_cursor(row, 0)
              screen.clear_line
            end
          end

          render_fixed_areas
          screen.flush
        end
      end



      # -----------------------------------------------------------------------
      # Fixed area (gap + todo + input) rendering
      # -----------------------------------------------------------------------

      # Repaint gap + todo + input at the bottom of the screen.
      #
      # @param skip_buffer_rerender [Boolean] When true, skip repainting the
      #   output area from the buffer even if the fixed-area height changed.
      #   Used by the scroll path in paint_new_lines — the caller has just
      #   written the correct content directly; a full buffer repaint would
      #   duplicate it in terminal scrollback.
      def render_fixed_areas(skip_buffer_rerender: false)
        # When input is paused (InlineInput active), the "input area" is
        # rendered inline with output. Nothing to paint down here.
        return if input_area.paused?
        return if @fullscreen_mode

        current_fixed_height = fixed_area_height
        start_row            = fixed_area_start_row
        gap_row              = start_row
        todo_row             = gap_row + 1

        # Fixed-area height changed (e.g. multi-line input appeared or
        # command-suggestions popped) → repaint the output from buffer so
        # nothing is hidden.
        if !skip_buffer_rerender &&
           @last_fixed_area_height > 0 &&
           @last_fixed_area_height != current_fixed_height
          render_output_from_buffer
        end
        @last_fixed_area_height = current_fixed_height

        # gap line
        screen.move_cursor(gap_row, 0)
        screen.clear_line

        # todo
        @todo_area.render(start_row: todo_row) if @todo_area&.visible?

        # input (renders its own visual cursor)
        input_row = todo_row + (@todo_area&.height || 0)
        input_area.render(start_row: input_row, width: screen.width)
      end

      private def render_all_internal
        render_fixed_areas
        screen.flush
      end

      # Legacy no-ops — terminal handles native scroll natively.
      def scroll_output_up(_lines = 1); end
      def scroll_output_down(_lines = 1); end



      # -----------------------------------------------------------------------
      # Wrapping helpers (ANSI-aware, East-Asian-width aware)
      # -----------------------------------------------------------------------

      # Wrap a long line into multiple lines based on terminal width.
      # Considers display width of multi-byte characters (e.g., Chinese characters).
      def wrap_long_line(line)
        return [""] if line.nil? || line.empty?

        max_width = screen.width
        return [line] if max_width <= 0

        # Strip ANSI codes for width calculation
        visible_line = line.gsub(/\e\[[0-9;]*m/, '')

        display_width = calculate_display_width(visible_line)
        return [line] if display_width <= max_width

        wrapped      = []
        current_line = ""
        current_width = 0
        ansi_codes   = []

        segments = line.split(/(\e\[[0-9;]*m)/)

        segments.each do |segment|
          if segment =~ /^\e\[[0-9;]*m$/
            ansi_codes << segment
            current_line += segment
          else
            segment.each_char do |char|
              char_width = char_display_width(char)
              if current_width + char_width > max_width && !current_line.empty?
                wrapped << current_line
                current_line = ansi_codes.join
                current_width = 0
              end
              current_line += char
              current_width += char_width
            end
          end
        end

        wrapped << current_line unless current_line.empty? || current_line == ansi_codes.join
        wrapped.empty? ? [""] : wrapped
      end

      def char_display_width(char)
        code = char.ord
        if (code >= 0x1100 && code <= 0x115F) ||
           (code >= 0x2329 && code <= 0x232A) ||
           (code >= 0x2E80 && code <= 0x303E) ||
           (code >= 0x3040 && code <= 0xA4CF) ||
           (code >= 0xAC00 && code <= 0xD7A3) ||
           (code >= 0xF900 && code <= 0xFAFF) ||
           (code >= 0xFE10 && code <= 0xFE19) ||
           (code >= 0xFE30 && code <= 0xFE6F) ||
           (code >= 0xFF00 && code <= 0xFF60) ||
           (code >= 0xFFE0 && code <= 0xFFE6) ||
           (code >= 0x1F300 && code <= 0x1F9FF) ||
           (code >= 0x20000 && code <= 0x2FFFD) ||
           (code >= 0x30000 && code <= 0x3FFFD)
          2
        else
          1
        end
      end

      def calculate_display_width(text)
        width = 0
        text.each_char { |c| width += char_display_width(c) }
        width
      end

      # -----------------------------------------------------------------------
      # Resize handling
      # -----------------------------------------------------------------------

      private def handle_resize
        old_height = screen.height
        old_width  = screen.width

        screen.update_dimensions
        calculate_layout

        shrinking = screen.height < old_height || screen.width < old_width
        screen.clear_screen(mode: shrinking ? :reset : :current)

        # Repaint from buffer — only live (uncommitted) lines, which is
        # exactly what we want: committed content already sits in the
        # native scrollback above.
        render_output_from_buffer

        # Sync so render_fixed_areas won't think height changed and
        # trigger a second repaint.
        @last_fixed_area_height = fixed_area_height
        render_fixed_areas
        screen.flush
      end

      private def setup_resize_handler
        Signal.trap("WINCH") { @resize_pending = true }
      rescue ArgumentError => e
        warn "WINCH signal already trapped: #{e.message}"
      end

      def process_pending_resize
        return unless @resize_pending
        @resize_pending = false
        handle_resize_safely
      end

      private def handle_resize_safely
        @render_mutex.synchronize { handle_resize }
      rescue => e
        warn "Resize error: #{e.message}"
        warn e.backtrace.first(5).join("\n") if e.backtrace
      end

      # -----------------------------------------------------------------------
      # Fullscreen (alternate screen buffer)
      # -----------------------------------------------------------------------

      def fullscreen_mode?
        @fullscreen_mode
      end

      def enter_fullscreen(lines, hint: "Press Ctrl+O to return")
        @render_mutex.synchronize do
          return if @fullscreen_mode
          @fullscreen_mode = true
          @fullscreen_hint = hint

          # Switch to alternate screen, clear it, position top-left.
          print "\e[?1049h\e[2J\e[H"
          $stdout.flush
          render_fullscreen_content(lines)
        end
      end

      def refresh_fullscreen(lines)
        @render_mutex.synchronize do
          return unless @fullscreen_mode
          print "\e[2J\e[H"
          render_fullscreen_content(lines)
        end
      end

      def exit_fullscreen
        @render_mutex.synchronize do
          return unless @fullscreen_mode
          @fullscreen_mode = false
          @fullscreen_hint = nil
          print "\e[?1049l"
          $stdout.flush
        end
      end

      def restore_screen
        @render_mutex.synchronize do
          screen.clear_screen
          screen.hide_cursor
          render_all_internal
        end
      end

      private def render_fullscreen_content(lines)
        term_height = screen.height
        term_width  = screen.width

        content_rows  = term_height - 1
        display_lines = lines.first(content_rows)

        display_lines.each do |line|
          visible = line.chomp.gsub(/\e\[[0-9;]*m/, "")
          padding = [term_width - visible.length, 0].max
          print line.chomp + (" " * padding) + "\r\n"
        end

        blank_row = " " * term_width
        (display_lines.length...content_rows).each { print blank_row + "\r\n" }

        hint_text = "\e[36m#{@fullscreen_hint}\e[0m"
        print "\e[#{term_height};1H#{hint_text}\e[0K"
        $stdout.flush
      end

    end
  end
end
