# frozen_string_literal: true

require "json"
require "time"

module Clacky
  module Tools
    class TodoManager < Base
      self.tool_name = "todo_manager"
      self.tool_description = "Manage TODO items for task planning and tracking. IMPORTANT: This tool is ONLY for planning - after adding all TODOs, you MUST immediately start executing them using other tools (write, edit, shell, etc). DO NOT stop after adding TODOs!"
      self.tool_category = "task_management"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ["add", "list", "complete", "remove", "clear"],
            description: "Action to perform: 'add' (add new todo(s)), 'list' (show all todos), 'complete' (mark as done), 'remove' (delete todo), 'clear' (remove all todos)"
          },
          tasks: {
            type: "array",
            items: { type: "string" },
            description: "Array of task descriptions to add (for 'add' action). Example: ['Task 1', 'Task 2', 'Task 3']"
          },
          task: {
            type: "string",
            description: "Single task description (for 'add' action). Use 'tasks' array for adding multiple tasks at once."
          },
          id: {
            type: "integer",
            description: "The task ID (required for 'complete' and 'remove' actions)"
          },
          ids: {
            type: "array",
            items: { type: "integer" },
            description: "Array of task IDs for batch removal (for 'remove' action). Example: [1, 3, 5]"
          }
        },
        required: ["action"]
      }

      def execute(action:, task: nil, tasks: nil, id: nil, ids: nil, todos_storage: nil, working_dir: nil)
        # todos_storage is injected by Agent, stores todos in memory
        @todos = todos_storage || []

        case action
        when "add"
          add_todos(task: task, tasks: tasks)
        when "list"
          list_todos
        when "complete"
          complete_todo(id)
        when "remove"
          # Support both single ID and batch IDs
          if ids && ids.is_a?(Array)
            remove_todos(ids)
          else
            remove_todo(id)
          end
        when "clear"
          clear_todos
        else
          { error: "Unknown action: #{action}" }
        end
      end

      def format_call(args)
        action = args[:action] || args['action']
        case action
        when 'add'
          count = (args[:tasks] || args['tasks'])&.size || 1
          "TodoManager(add #{count} task#{count > 1 ? 's' : ''})"
        when 'complete'
          "TodoManager(complete ##{args[:id] || args['id']})"
        when 'list'
          "TodoManager(list)"
        when 'remove'
          ids = args[:ids] || args['ids']
          if ids && ids.is_a?(Array) && !ids.empty?
            "TodoManager(remove #{ids.size} tasks: #{ids.join(', ')})"
          else
            "TodoManager(remove ##{args[:id] || args['id']})"
          end
        when 'clear'
          "TodoManager(clear all)"
        else
          "TodoManager(#{action})"
        end
      end

      def format_result(result)
        return result[:error] if result[:error]

        if result[:message]
          result[:message]
        else
          "Done"
        end
      end

      private

      def load_todos
        @todos
      end

      def save_todos(todos)
        # Modify the array in-place so Agent's @todos is updated
        # Important: Don't use @todos.clear first because todos might be @todos itself!
        @todos.replace(todos)
      end

      def add_todos(task: nil, tasks: nil)
        # Determine which tasks to add
        tasks_to_add = []

        if tasks && tasks.is_a?(Array) && !tasks.empty?
          tasks_to_add = tasks.map(&:strip).reject(&:empty?)
        elsif task && !task.strip.empty?
          tasks_to_add = [task.strip]
        end

        return { error: "At least one task description is required" } if tasks_to_add.empty?

        existing_todos = load_todos
        next_id = existing_todos.empty? ? 1 : existing_todos.map { |t| t[:id] }.max + 1

        added_todos = []
        tasks_to_add.each_with_index do |task_desc, index|
          new_todo = {
            id: next_id + index,
            task: task_desc,
            status: "pending",
            created_at: Time.now.iso8601
          }
          existing_todos << new_todo
          added_todos << new_todo
        end

        save_todos(existing_todos)

        {
          message: added_todos.size == 1 ? "TODO added successfully" : "#{added_todos.size} TODOs added successfully",
          todos: added_todos,
          total: existing_todos.size,
          reminder: "⚠️ IMPORTANT: You have added TODO(s) but have NOT started working yet! You MUST now use other tools (write, edit, shell, etc.) to actually complete these tasks. DO NOT stop here!"
        }
      end

      def list_todos
        todos = load_todos

        if todos.empty?
          return {
            message: "No TODO items",
            todos: [],
            total: 0
          }
        end

        {
          message: "TODO list",
          todos: todos,
          total: todos.size,
          pending: todos.count { |t| t[:status] == "pending" },
          completed: todos.count { |t| t[:status] == "completed" }
        }
      end

      def complete_todo(id)
        return { error: "Task ID is required" } if id.nil?

        todos = load_todos
        todo = todos.find { |t| t[:id] == id }

        return { error: "Task not found: #{id}" } unless todo

        if todo[:status] == "completed"
          return { message: "Task already completed", todo: todo }
        end

        todo[:status] = "completed"
        todo[:completed_at] = Time.now.iso8601
        save_todos(todos)

        # Find the next pending task
        next_pending = todos.find { |t| t[:status] == "pending" }
        
        # Count statistics
        completed_count = todos.count { |t| t[:status] == "completed" }
        total_count = todos.size

        result = {
          message: "Task marked as completed",
          todo: todo,
          progress: "#{completed_count}/#{total_count}",
          reminder: "⚠️ REMINDER: Check the PROJECT-SPECIFIC RULES section in your system prompt before continuing to the next task"
        }

        if next_pending
          result[:next_task] = next_pending
          result[:next_task_info] = "✅ Progress: #{completed_count}/#{total_count}. Next task: ##{next_pending[:id]} - #{next_pending[:task]}"
        else
          result[:all_completed] = true
          result[:completion_message] = "🎉 All tasks completed! (#{completed_count}/#{total_count})"
        end

        result
      end

      def remove_todo(id)
        return { error: "Task ID is required" } if id.nil?

        todos = load_todos
        todo = todos.find { |t| t[:id] == id }

        return { error: "Task not found: #{id}" } unless todo

        todos.reject! { |t| t[:id] == id }
        save_todos(todos)

        {
          message: "Task removed",
          todo: todo,
          remaining: todos.size
        }
      end

      def clear_todos
        todos = load_todos
        count = todos.size

        # Clear the in-memory storage
        save_todos([])

        {
          message: "All TODOs cleared",
          cleared_count: count
        }
      end

      def remove_todos(ids)
        return { error: "Task IDs array is required" } if ids.nil? || ids.empty?

        todos = load_todos
        removed_todos = []
        not_found_ids = []

        ids.each do |id|
          todo = todos.find { |t| t[:id] == id }
          if todo
            removed_todos << todo
          else
            not_found_ids << id
          end
        end

        # Remove all found todos
        todos.reject! { |t| ids.include?(t[:id]) }
        save_todos(todos)

        result = {
          message: "#{removed_todos.size} task(s) removed",
          removed: removed_todos,
          remaining: todos.size
        }

        # Add warning about not found IDs
        result[:not_found] = not_found_ids unless not_found_ids.empty?

        result
      end
    end
  end
end
