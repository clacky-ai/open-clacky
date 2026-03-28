# frozen_string_literal: true

module Clacky
  class ProgressIndicator
    def initialize(verbose: false, message: nil)
      @verbose = verbose
      @start_time = nil
      @custom_message = message
      @thinking_verb = message || THINKING_VERBS.sample
      @running = false
      @update_thread = nil
    end

    def start
      @start_time = Time.now
      @running = true
      # Save cursor position after the [..] symbol
      print "\e[s"  # Save cursor position
      print_thinking_status("#{@thinking_verb}… (ctrl+c to interrupt)")

      # Start background thread to update elapsed time
      @update_thread = Thread.new do
        while @running
          sleep 0.1
          update if @running
        end
      end
    end

    def update
      return unless @start_time

      elapsed = (Time.now - @start_time).to_i
      print_thinking_status("#{@thinking_verb}… (ctrl+c to interrupt · #{elapsed}s)")
    end

    def finish
      @running = false
      @update_thread&.join
      # Restore cursor and clear to end of line
      print "\e[u"     # Restore cursor position
      print "\e[K"     # Clear to end of line
      puts ""          # Add newline after finishing
    end


    def print_thinking_status(text)
      print "\e[u"     # Restore cursor position (to after [..] symbol)
      print "\e[K"     # Clear to end of line from cursor
      print text
      print " "
      $stdout.flush
    end
  end
end
