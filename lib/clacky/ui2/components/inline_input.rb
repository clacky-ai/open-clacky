# frozen_string_literal: true

require_relative "../line_editor"

module Clacky
  module UI2
    module Components
      # InlineInput provides inline input for confirmations and simple prompts
      # Renders at the end of output area, not at fixed bottom position
      class InlineInput
        include LineEditor

        attr_reader :prompt, :default_value

        def initialize(prompt: "", default: nil)
          initialize_line_editor
          @prompt = prompt
          @default_value = default
          @active = false
          @result_queue = nil
          @paste_counter = 0
          @paste_placeholders = {}
        end

        # Activate inline input and wait for user input
        # @return [String] User input
        def collect
          @active = true
          @result_queue = Queue.new
          # Don't set default as initial text - start empty
          @result_queue.pop
        end

        # Check if active
        def active?
          @active
        end

        # Handle keyboard input
        # @param key [Symbol, String] Key input
        # @return [Hash] Result with action
        def handle_key(key)
          return { action: nil } unless @active

          case key
          when Hash
            if key[:type] == :rapid_input
              # Handle multi-line paste with placeholder
              pasted_text = key[:text]
              pasted_lines = pasted_text.split(/\r\n|\r|\n/)

              if pasted_lines.size > 1
                # Multi-line paste - use placeholder
                @paste_counter += 1
                placeholder = "[##{@paste_counter} Paste Text]"
                @paste_placeholders[placeholder] = pasted_text
                insert_text(placeholder)
              else
                # Single line - insert directly
                insert_text(pasted_text)
              end
            end
            { action: :update }
          when :enter
            handle_enter
          when :backspace
            backspace
            { action: :update }
          when :delete
            delete_char
            { action: :update }
          when :left_arrow, :ctrl_b
            cursor_left
            { action: :update }
          when :right_arrow, :ctrl_f
            cursor_right
            { action: :update }
          when :home, :ctrl_a
            cursor_home
            { action: :update }
          when :end, :ctrl_e
            cursor_end
            { action: :update }
          when :ctrl_k
            kill_to_end
            { action: :update }
          when :ctrl_u
            kill_to_start
            { action: :update }
          when :ctrl_w
            kill_word
            { action: :update }
          when :shift_tab
            handle_shift_tab
          when :ctrl_c
            handle_cancel
          when :escape
            handle_cancel
          else
            if key.is_a?(String) && key.length >= 1 && key.ord >= 32
              insert_char(key)
              { action: :update }
            else
              { action: nil }
            end
          end
        end

        # Render inline input with prompt and cursor
        # @return [String] Rendered line
        def render
          "#{@prompt}#{render_line_with_cursor}"
        end

        # Get cursor column position
        # @return [Integer] Column position
        def cursor_col
          cursor_column(@prompt)
        end

        # Deactivate inline input
        def deactivate
          @active = false
          @result_queue = nil
        end

        private

        def handle_enter
          result = expand_placeholders(current_line)
          # If empty and has default, use default
          result = @default_value.to_s if result.empty? && @default_value

          queue = @result_queue
          deactivate
          queue&.push(result)

          { action: :submit, result: result }
        end

        def expand_placeholders(text)
          super(text, @paste_placeholders)
        end

        def handle_cancel
          queue = @result_queue
          deactivate
          queue&.push(nil)

          { action: :cancel }
        end

        def handle_shift_tab
          # Auto-confirm as yes (or use default if it's true)
          result = if @default_value == true || @default_value.to_s.downcase == "yes"
            @default_value.to_s
          else
            "yes"
          end

          queue = @result_queue
          deactivate
          queue&.push(result)

          { action: :toggle_mode }
        end
      end
    end
  end
end
