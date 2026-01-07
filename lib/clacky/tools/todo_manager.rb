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
          work_dir: {
            type: "string",
            description: "Working directory for storing todos (defaults to current directory)"
          }
        },
        required: ["action"]
      }

      def execute(action:, task: nil, tasks: nil, id: nil, work_dir: nil)
        @work_dir = work_dir || Dir.pwd
        @todo_file = File.join(@work_dir, ".clacky_todos.json")

        case action
        when "add"
          add_todos(task: task, tasks: tasks)
        when "list"
          list_todos
        when "complete"
          complete_todo(id)
        when "remove"
          remove_todo(id)
        when "clear"
          clear_todos
        else
          { error: "Unknown action: #{action}" }
        end
      end

      private

      def load_todos
        return [] unless File.exist?(@todo_file)

        JSON.parse(File.read(@todo_file), symbolize_names: true)
      rescue JSON::ParserError
        []
      end

      def save_todos(todos)
        File.write(@todo_file, JSON.pretty_generate(todos))
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

        # Build response with rules reminder
        response = {
          message: "Task marked as completed",
          todo: todo
        }

        # Add reminder to check project rules in system prompt
        rules_file = File.join(@work_dir, ".clackyrules")
        if File.exist?(rules_file)
          response[:reminder] = "⚠️ REMINDER: Check the PROJECT-SPECIFIC RULES section in your system prompt before continuing to the next task!"
        end

        response
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

        File.delete(@todo_file) if File.exist?(@todo_file)

        {
          message: "All TODOs cleared",
          cleared_count: count
        }
      end
    end
  end
end
