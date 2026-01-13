# frozen_string_literal: true

require "pastel"

module Clacky
  module UI
    # Matrix/hacker-style output formatter
    class Formatter
      # Hacker-style symbols (no emoji)
      SYMBOLS = {
        user: "[>>]",
        assistant: "[<<]",
        tool_call: "[=>]",
        tool_result: "[<=]",
        tool_denied: "[!!]",
        tool_planned: "[??]",
        tool_error: "[XX]",
        thinking: "[..]",
        success: "[OK]",
        error: "[ER]",
        warning: "[!!]",
        info: "[--]",
        task: "[##]",
        progress: "[>>]"
      }.freeze

      def initialize
        @pastel = Pastel.new
      end

      # Format user message
      def user_message(content)
        symbol = @pastel.bright_blue(SYMBOLS[:user])
        text = @pastel.blue(content)
        puts "\n#{symbol} #{text}"
      end

      # Format assistant message
      def assistant_message(content)
        return if content.nil? || content.empty?
        
        symbol = @pastel.bright_green(SYMBOLS[:assistant])
        text = @pastel.white(content)
        puts "\n#{symbol} #{text}"
      end

      # Format tool call
      def tool_call(formatted_call)
        symbol = @pastel.bright_cyan(SYMBOLS[:tool_call])
        text = @pastel.cyan(formatted_call)
        puts "\n#{symbol} #{text}"
      end

      # Format tool result
      def tool_result(summary)
        symbol = @pastel.cyan(SYMBOLS[:tool_result])
        text = @pastel.white(summary)
        puts "#{symbol} #{text}"
      end

      # Format tool denied
      def tool_denied(tool_name)
        symbol = @pastel.bright_yellow(SYMBOLS[:tool_denied])
        text = @pastel.yellow("Tool denied: #{tool_name}")
        puts "\n#{symbol} #{text}"
      end

      # Format tool planned
      def tool_planned(tool_name)
        symbol = @pastel.bright_blue(SYMBOLS[:tool_planned])
        text = @pastel.blue("Planned: #{tool_name}")
        puts "\n#{symbol} #{text}"
      end

      # Format tool error
      def tool_error(error_message)
        symbol = @pastel.bright_red(SYMBOLS[:tool_error])
        text = @pastel.red("Error: #{error_message}")
        puts "\n#{symbol} #{text}"
      end

      # Format thinking indicator
      def thinking
        symbol = @pastel.dim(SYMBOLS[:thinking])
        # Output symbol on the same line, progress indicator will follow
        print "\n#{symbol} "
      end

      # Format success message
      def success(message)
        symbol = @pastel.bright_green(SYMBOLS[:success])
        text = @pastel.green(message)
        puts "#{symbol} #{text}"
      end

      # Format error message
      def error(message)
        symbol = @pastel.bright_red(SYMBOLS[:error])
        text = @pastel.red(message)
        puts "#{symbol} #{text}"
      end

      # Format warning message
      def warning(message)
        symbol = @pastel.bright_yellow(SYMBOLS[:warning])
        text = @pastel.yellow(message)
        puts "#{symbol} #{text}"
      end

      # Format info message
      def info(message)
        symbol = @pastel.bright_white(SYMBOLS[:info])
        text = @pastel.white(message)
        puts "#{symbol} #{text}"
      end

      # Format TODO status with progress bar
      def todo_status(todos)
        return if todos.empty?

        completed = todos.count { |t| t[:status] == "completed" }
        total = todos.size

        # Build progress bar with hacker style
        progress_bar = todos.map { |t| 
          t[:status] == "completed" ? @pastel.green("█") : @pastel.dim("░")
        }.join

        # Check if all completed
        if completed == total
          symbol = @pastel.bright_green(SYMBOLS[:success])
          puts "\n#{symbol} Tasks [#{completed}/#{total}]: #{progress_bar} #{@pastel.bright_green('COMPLETE')}"
          return
        end

        # Find current and next tasks
        current_task = todos.find { |t| t[:status] == "pending" }
        next_task_index = todos.index(current_task)
        next_task = next_task_index && todos[next_task_index + 1]

        symbol = @pastel.bright_yellow(SYMBOLS[:task])
        puts "\n#{symbol} Tasks [#{completed}/#{total}]: #{progress_bar}"
        
        if current_task
          puts "    #{@pastel.cyan('→')} Next: ##{current_task[:id]} - #{current_task[:task]}"
        end
        
        if next_task && next_task[:status] == "pending"
          puts "    #{@pastel.dim('⇢')} After: ##{next_task[:id]} - #{next_task[:task]}"
        end
      end

      # Format iteration indicator
      def iteration(number)
        symbol = @pastel.dim(SYMBOLS[:progress])
        text = @pastel.dim("Iteration #{number}")
        puts "\n#{symbol} #{text}"
      end

      # Format separator
      def separator(char = "─", width: 80)
        puts @pastel.dim(char * width)
      end

      # Format section header
      def section_header(title)
        puts
        separator("═")
        puts @pastel.bright_white(title.center(80))
        separator("═")
        puts
      end

      # Format confirmation prompt for tool use
      def tool_confirmation_prompt(formatted_call)
        symbol = @pastel.bright_yellow("[??]")
        puts "\n#{symbol} #{@pastel.yellow(formatted_call)}"
      end

      # Format conversation history message
      def history_message(role, content, index, total)
        case role
        when "user"
          symbol = @pastel.blue(SYMBOLS[:user])
          text = @pastel.white(truncate(content, 150))
          puts "#{symbol} You: #{text}"
        when "assistant"
          symbol = @pastel.green(SYMBOLS[:assistant])
          text = @pastel.white(truncate(content, 200))
          puts "#{symbol} Assistant: #{text}"
        end
      end

      private

      def truncate(content, max_length)
        return "" if content.nil? || content.empty?

        cleaned = content.strip.gsub(/\s+/, ' ')
        
        if cleaned.length > max_length
          cleaned[0...max_length] + "..."
        else
          cleaned
        end
      end
    end
  end
end
