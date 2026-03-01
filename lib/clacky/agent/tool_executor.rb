# frozen_string_literal: true

module Clacky
  class Agent
    # Tool execution and permission management
    # Handles tool confirmation, preview, and result building
    module ToolExecutor
      # Check if a tool should be auto-executed based on permission mode
      # @param tool_name [String] Name of the tool
      # @param tool_params [Hash, String] Tool parameters
      # @return [Boolean] true if should auto-execute
      def should_auto_execute?(tool_name, tool_params = {})
        case @config.permission_mode
        when :auto_approve
          true
        when :confirm_safes
          # Use SafeShell integration for safety check
          is_safe_operation?(tool_name, tool_params)
        when :plan_only
          false
        else
          false
        end
      end

      # Check if an operation is considered safe for auto-execution
      # @param tool_name [String] Name of the tool
      # @param tool_params [Hash, String] Tool parameters
      # @return [Boolean] true if safe operation
      def is_safe_operation?(tool_name, tool_params = {})
        # For shell commands, use SafeShell to check safety
        if tool_name.to_s.downcase == 'shell' || tool_name.to_s.downcase == 'safe_shell'
          params = tool_params.is_a?(String) ? JSON.parse(tool_params) : tool_params
          command = params[:command] || params['command']
          return false unless command

          return Tools::SafeShell.command_safe_for_auto_execution?(command)
        end

        if tool_name.to_s.downcase == 'edit' || tool_name.to_s.downcase == 'write'
          return false
        end

        true
      end

      # Request user confirmation for tool execution
      # Shows preview and returns approval status
      # @param call [Hash] Tool call with :name and :arguments
      # @return [Hash] { approved: Boolean, feedback: String, system_injected: Boolean }
      def confirm_tool_use?(call)
        # Show preview first and check for errors
        preview_error = show_tool_preview(call)

        # If preview detected an error, auto-deny and provide feedback
        if preview_error && preview_error[:error]
          feedback = build_preview_error_feedback(call[:name], preview_error)
          return { approved: false, feedback: feedback, system_injected: true }
        end

        # Request confirmation via UI
        if @ui
          prompt_text = format_tool_prompt(call)
          result = @ui.request_confirmation(prompt_text, default: true)

          case result
          when true
            { approved: true, feedback: nil }
          when false, nil
            # User denied - add visual marker based on tool type
            tool_name_capitalized = call[:name].capitalize
            @ui&.show_info("  ↳ #{tool_name_capitalized} cancelled", prefix_newline: false)
            { approved: false, feedback: nil }
          else
            # String feedback - also add visual marker
            tool_name_capitalized = call[:name].capitalize
            @ui&.show_info("  ↳ #{tool_name_capitalized} cancelled", prefix_newline: false)
            { approved: false, feedback: result.to_s }
          end
        else
          # Fallback: auto-approve if no UI
          { approved: true, feedback: nil }
        end
      end

      # Show preview for tool execution
      # @param call [Hash] Tool call with :name and :arguments
      # @return [Hash, nil] Error information if preview detected issues
      def show_tool_preview(call)
        return nil unless @ui

        begin
          args = JSON.parse(call[:arguments], symbolize_names: true)

          preview_error = nil
          case call[:name]
          when "write"
            preview_error = show_write_preview(args)
          when "edit"
            preview_error = show_edit_preview(args)
          # Shell and other tools don't need special preview
          # They will be shown via show_tool_call in the main flow
          end

          preview_error
        rescue JSON::ParserError
          nil
        end
      end

      # Format tool call for user confirmation prompt
      # @param call [Hash] Tool call with :name and :arguments
      # @return [String] Formatted prompt text
      def format_tool_prompt(call)
        begin
          args = JSON.parse(call[:arguments], symbolize_names: true)

          # Try to use tool's format_call method for better formatting
          tool = @tool_registry.get(call[:name]) rescue nil
          if tool
            formatted = tool.format_call(args) rescue nil
            return formatted if formatted
          end

          # Fallback to manual formatting for common tools
          case call[:name]
          when "edit"
            path = args[:path] || args[:file_path]
            filename = Utils::PathHelper.safe_basename(path)
            "Edit(#{filename})"
          when "write"
            filename = Utils::PathHelper.safe_basename(args[:path])
            if args[:path] && File.exist?(args[:path])
              "Write(#{filename}) - overwrite existing"
            else
              "Write(#{filename}) - create new"
            end
          when "shell", "safe_shell"
            cmd = args[:command] || ''
            display_cmd = cmd.length > 30 ? "#{cmd[0..27]}..." : cmd
            "#{call[:name]}(\"#{display_cmd}\")"
          else
            "Allow #{call[:name]}"
          end
        rescue JSON::ParserError
          "Allow #{call[:name]}"
        end
      end

      # Build success result for tool execution
      # @param call [Hash] Tool call
      # @param result [Object] Tool execution result
      # @return [Hash] Formatted result for LLM
      def build_success_result(call, result)
        # Try to get tool instance to use its format_result_for_llm method
        tool = @tool_registry.get(call[:name]) rescue nil

        formatted_result = if tool && tool.respond_to?(:format_result_for_llm)
          # Tool provides a custom LLM-friendly format
          tool.format_result_for_llm(result)
        else
          # Fallback: use the original result
          result
        end

        # Inject TODO reminder for non-todo_manager tools
        formatted_result = inject_todo_reminder(call[:name], formatted_result)

        {
          id: call[:id],
          content: JSON.generate(formatted_result)
        }
      end

      # Build error result for tool execution
      # @param call [Hash] Tool call
      # @param error_message [String] Error message
      # @return [Hash] Formatted error result
      def build_error_result(call, error_message)
        {
          id: call[:id],
          content: JSON.generate({ error: error_message })
        }
      end

      # Build denied result when user denies tool execution
      # @param call [Hash] Tool call
      # @param user_feedback [String, nil] User's feedback message
      # @param system_injected [Boolean] Whether this is a system-generated denial
      # @return [Hash] Formatted denial result
      def build_denied_result(call, user_feedback = nil, system_injected = false)
        if system_injected
          # System-generated feedback (e.g., from preview errors)
          tool_content = {
            error: "Tool #{call[:name]} denied: #{user_feedback}",
            system_injected: true
          }
        else
          # User manually denied or provided feedback
          # Clearly state the action was NOT performed so the LLM knows the change did not happen
          message = if user_feedback && !user_feedback.empty?
                      "Tool use denied by user. This action was NOT performed. User feedback: #{user_feedback}"
                    else
                      "Tool use denied by user. This action was NOT performed."
                    end

          tool_content = {
            error: message,
            action_performed: false,
            user_feedback: user_feedback
          }
        end

        {
          id: call[:id],
          content: JSON.generate(tool_content)
        }
      end

      # Build planned result for plan-only mode
      # @param call [Hash] Tool call
      # @return [Hash] Formatted planned result
      def build_planned_result(call)
        {
          id: call[:id],
          content: JSON.generate({ planned: true, message: "Tool execution skipped (plan mode)" })
        }
      end

      # Check if a tool is potentially slow and should show progress
      # @param tool_name [String] Name of the tool
      # @param args [Hash] Tool arguments
      # @return [Boolean] true if tool is potentially slow
      private def potentially_slow_tool?(tool_name, args)
        case tool_name.to_s.downcase
        when 'shell', 'safe_shell'
          # Check if the command is a slow command
          command = args[:command] || args['command']
          return false unless command

          # List of slow command patterns
          slow_patterns = [
            /bundle\s+(install|exec\s+rspec|exec\s+rake)/,
            /npm\s+(install|run\s+test|run\s+build)/,
            /yarn\s+(install|test|build)/,
            /pnpm\s+install/,
            /cargo\s+(build|test)/,
            /go\s+(build|test)/,
            /make\s+(test|build)/,
            /pytest/,
            /jest/,
            /sleep\s+\d+/  # sleep command with duration
          ]

          slow_patterns.any? { |pattern| command.match?(pattern) }
        when 'web_fetch', 'web_search'
          true  # Network operations can be slow
        else
          false  # Most file operations are fast
        end
      end

      # Build progress message for tool execution
      # @param tool_name [String] Name of the tool
      # @param args [Hash] Tool arguments
      # @return [String] Progress message
      private def build_tool_progress_message(tool_name, args)
        case tool_name.to_s.downcase
        when 'shell', 'safe_shell'
          "Running command"
        when 'web_fetch'
          "Fetching web page"
        when 'web_search'
          "Searching web"
        else
          "Executing #{tool_name}"
        end
      end

      # Inject TODO reminder into tool results for non-todo_manager tools
      # This helps AI remember to mark TODOs as complete after executing tasks
      # @param tool_name [String] Name of the tool
      # @param result [Object] Tool execution result
      # @return [Object] Result with optional TODO reminder
      private def inject_todo_reminder(tool_name, result)
        # Skip injection for todo_manager tool itself to avoid redundancy
        return result if tool_name == "todo_manager"

        # Get pending TODOs
        todo_tool = @tool_registry.get("todo_manager")
        return result unless todo_tool

        pending_todos = begin
          todo_result = todo_tool.execute(action: "list", todos_storage: @todos)
          if todo_result.is_a?(Hash) && todo_result[:todos]
            todo_result[:todos].select { |t| t[:status] == "pending" }
          else
            []
          end
        rescue
          []
        end

        # Only inject reminder if there are pending TODOs
        return result unless pending_todos && !pending_todos.empty?

        # Create a friendly reminder message
        reminder = "\n\n📋 REMINDER: You have #{pending_todos.length} pending TODO(s). " \
                   "After completing each task, remember to mark it as complete using " \
                   "todo_manager with action 'complete' and the task id."

        # Inject reminder based on result type
        case result
        when String
          result + reminder
        when Hash
          result.merge({ _todo_reminder: reminder.strip })
        when Array
          result + [{ _todo_reminder: reminder.strip }]
        else
          result
        end
      end

      # Build feedback message from preview error
      # @param tool_name [String] Name of the tool
      # @param error_info [Hash] Error information from preview
      # @return [String] Feedback message
      private def build_preview_error_feedback(tool_name, error_info)
        case tool_name
        when "edit"
          "Tool edit denied: The edit operation will fail because the old_string was not found in the file. " \
          "Please use file_reader to read '#{error_info[:path]}' first, " \
          "find the correct string to replace, and try again with the exact string (including whitespace)."
        else
          "Tool preview error: #{error_info[:error]}"
        end
      end

      # Show preview for write tool
      # @param args [Hash] Write tool arguments
      # @return [nil] Always returns nil (no errors for write)
      private def show_write_preview(args)
        path = args[:path] || args['path']
        new_content = args[:content] || args['content'] || ""

        is_new_file = !(path && File.exist?(path))
        @ui&.show_file_write_preview(path, is_new_file: is_new_file)

        if is_new_file
          @ui&.show_diff("", new_content, max_lines: 50)
        else
          old_content = File.read(path)
          @ui&.show_diff(old_content, new_content, max_lines: 50)
        end
        nil
      end

      # Show preview for edit tool
      # @param args [Hash] Edit tool arguments
      # @return [Hash, nil] Error information if preview detected issues
      private def show_edit_preview(args)
        path = args[:path] || args[:file_path] || args['path'] || args['file_path']
        old_string = args[:old_string] || args['old_string'] || ""
        new_string = args[:new_string] || args['new_string'] || ""
        replace_all = args[:replace_all] || args['replace_all'] || false

        @ui&.show_file_edit_preview(path)

        if !path || path.empty?
          @ui&.show_file_error("No file path provided")
          return { error: "No file path provided for edit operation" }
        end

        unless File.exist?(path)
          @ui&.show_file_error("File not found: #{path}")
          return { error: "File not found: #{path}", path: path }
        end

        if old_string.empty?
          @ui&.show_file_error("No old_string provided (nothing to replace)")
          return { error: "No old_string provided (nothing to replace)" }
        end

        file_content = File.read(path)

        # Use the same find_match logic as Edit tool to handle fuzzy matching
        # (trim, unescape, smart line matching) — prevents diff from being blank
        # when simple include? fails but Edit#execute's fuzzy match would succeed
        match_result = Utils::StringMatcher.find_match(file_content, old_string)

        unless match_result
          # Log debug info for troubleshooting
          @debug_logs << {
            timestamp: Time.now.iso8601,
            event: "edit_preview_failed",
            path: path,
            looking_for: old_string[0..500],
            file_content_preview: file_content[0..1000],
            file_size: file_content.length
          }

          @ui&.show_file_error("Edit file error")
          return {
            error: "String to replace not found in file",
            path: path,
            looking_for: old_string[0..200]
          }
        end

        # Use the actual matched string (may differ via trim/unescape) for replacement
        actual_old_string = match_result[:matched_string]

        # Use the same replace logic as the actual tool execution
        new_content = if replace_all
                        file_content.gsub(actual_old_string, new_string)
                      else
                        file_content.sub(actual_old_string, new_string)
                      end
        @ui&.show_diff(file_content, new_content, max_lines: 50)
        nil  # No error
      end

      # Show preview for shell tool
      # @param args [Hash] Shell tool arguments
      # @return [nil] Always returns nil
      private def show_shell_preview(args)
        command = args[:command] || ""
        @ui&.show_shell_preview(command)
        nil
      end
    end
  end
end
