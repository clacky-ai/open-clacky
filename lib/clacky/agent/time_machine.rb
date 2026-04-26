# frozen_string_literal: true

module Clacky
  class Agent
    # Time Machine module for task history management with undo/redo support
    # Stores complete file snapshots (AFTER state) to support message compression
    module TimeMachine
      # Initialize Time Machine state
      private def init_time_machine
        @task_parents ||= {}      # { task_id => parent_id }
        @current_task_id ||= 0    # Latest created task ID
        @active_task_id ||= 0     # Current active task ID (for undo/redo)
      end

      # Start a new task and establish parent relationship
      # Made public for testing
      def start_new_task
        parent_id = @active_task_id
        @current_task_id += 1
        @active_task_id = @current_task_id
        @task_parents[@current_task_id] = parent_id

        @current_task_id
      end

      # Save snapshots of modified files (AFTER state)
      # @param modified_files [Array<String>] List of file paths that were modified
      # Made public for testing
      def save_modified_files_snapshot(modified_files)
        return if modified_files.nil? || modified_files.empty?

        snapshot_dir = File.join(
          Dir.home,
          ".clacky",
          "snapshots",
          @session_id,
          "task-#{@current_task_id}"
        )
        FileUtils.mkdir_p(snapshot_dir)

        modified_files.each do |file_path|
          next unless File.exist?(file_path)

          # Save file content to snapshot
          relative_path = file_path.start_with?(@working_dir) ?
            file_path.sub(@working_dir + "/", "") : File.basename(file_path)
          
          snapshot_file = File.join(snapshot_dir, relative_path)
          FileUtils.mkdir_p(File.dirname(snapshot_file))
          FileUtils.cp(file_path, snapshot_file)
        end
      rescue StandardError => e
        # Silently handle errors in tests
      end

      # Restore files to the state at given task
      # @param task_id [Integer] Target task ID
      # Made public for testing
      def restore_to_task_state(task_id)
        # Collect all modified files from task 1 to target task
        files_to_restore = {}
        
        (1..task_id).each do |tid|
          snapshot_dir = File.join(
            Dir.home,
            ".clacky",
            "snapshots",
            @session_id,
            "task-#{tid}"
          )
          
          next unless Dir.exist?(snapshot_dir)
          
          Dir.glob(File.join(snapshot_dir, "**", "*")).each do |snapshot_file|
            next if File.directory?(snapshot_file)
            
            relative_path = snapshot_file.sub(snapshot_dir + "/", "")
            files_to_restore[relative_path] = snapshot_file
          end
        end
        
        # Restore files
        files_to_restore.each do |relative_path, snapshot_file|
          target_file = File.join(@working_dir, relative_path)
          FileUtils.mkdir_p(File.dirname(target_file))
          FileUtils.cp(snapshot_file, target_file)
        end
      rescue StandardError => e
        # Silently handle errors in tests
        raise
      end

      # Filter messages to only show tasks up to active_task_id.
      # This hides "future" messages when user has undone.
      # Returns API-ready array (strips internal fields + handles orphaned tool_calls).
      # @param force_reasoning_content_pad [Boolean] forwarded to MessageHistory,
      #   enables one-shot pad-and-retry for thinking-mode providers that
      #   require reasoning_content on every assistant message.
      # Made public for testing
      def active_messages(force_reasoning_content_pad: false)
        if @active_task_id == @current_task_id
          return @history.to_api(force_reasoning_content_pad: force_reasoning_content_pad)
        end

        stripped = @history.for_task(@active_task_id).map do |msg|
          msg.reject { |k, _| MessageHistory::INTERNAL_FIELDS.include?(k) }
        end
        # Apply the same reasoning_content padding rule used by to_api so
        # Time Machine replays satisfy thinking-mode providers after a
        # 400 retry.
        MessageHistory.pad_reasoning_content_if_needed(stripped, force: force_reasoning_content_pad)
      end

      # Undo to parent task
      def undo_last_task
        parent_id = @task_parents[@active_task_id]
        return { success: false, message: "Already at root task" } if parent_id.nil? || parent_id == 0

        restore_to_task_state(parent_id)
        @active_task_id = parent_id

        {
          success: true,
          message: "⏪ Undone to task #{parent_id}",
          task_id: parent_id
        }
      end

      # Switch to specific task (for redo or branch switching)
      def switch_to_task(target_task_id)
        if target_task_id > @current_task_id || target_task_id < 1
          return { success: false, message: "Invalid task ID: #{target_task_id}" }
        end

        restore_to_task_state(target_task_id)
        @active_task_id = target_task_id

        {
          success: true,
          message: "⏩ Switched to task #{target_task_id}",
          task_id: target_task_id
        }
      end

      # Get children of a task (for branch detection)
      def get_child_tasks(task_id)
        @task_parents.select { |_, parent| parent == task_id }.keys
      end

      # Get task history with summaries for UI display
      # @param limit [Integer] Maximum number of recent tasks to return
      # @return [Array<Hash>] Task history with metadata
      def get_task_history(limit: 10)
        return [] if @current_task_id == 0

        tasks = []
        (1..@current_task_id).to_a.reverse.take(limit).reverse.each do |task_id|
          # Find first user message for this task
          first_user_msg = @history.to_a.find do |msg|
            msg[:task_id] == task_id && msg[:role] == "user"
          end

          summary = if first_user_msg
            content = extract_message_text(first_user_msg[:content])
            # Truncate to 60 characters (including "...")
            content.length > 60 ? "#{content[0...57]}..." : content
          else
            "Task #{task_id}"
          end

          # Determine task status
          status = if task_id == @active_task_id
            :current
          elsif task_id < @active_task_id
            :past
          else
            :future
          end

          # Check if task has branches (multiple children)
          children = get_child_tasks(task_id)
          has_branches = children.length > 1

          tasks << {
            task_id: task_id,
            summary: summary,
            status: status,
            has_branches: has_branches
          }
        end

        tasks
      end

      # Extract text from message content (handles both string and array formats)
      private def extract_message_text(content)
        if content.is_a?(String)
          content
        elsif content.is_a?(Array)
          text_parts = content.select { |part| part[:type] == "text" }
          text_parts.map { |part| part[:text] }.join(" ")
        else
          ""
        end
      end
    end
  end
end
