# frozen_string_literal: true

module Clacky
  class ToolRegistry
    # Common aliases that LLMs frequently use instead of the registered tool names.
    # Keys are downcased aliases; values are the canonical registered names.
    TOOL_ALIASES = {
      # file_reader aliases
      "read" => "file_reader",
      "read_file" => "file_reader",
      "filereader" => "file_reader",
      "file_read" => "file_reader",
      "cat" => "file_reader",
      # write aliases
      "write_file" => "write",
      "create_file" => "write",
      "file_write" => "write",
      # edit aliases
      "file_edit" => "edit",
      "replace" => "edit",
      "replace_in_file" => "edit",
      "str_replace" => "edit",
      # terminal aliases
      "shell" => "terminal",
      "bash" => "terminal",
      "exec" => "terminal",
      "execute" => "terminal",
      "run_command" => "terminal",
      "run" => "terminal",
      "command" => "terminal",
      # web_search aliases
      "search" => "web_search",
      "websearch" => "web_search",
      "internet_search" => "web_search",
      "online_search" => "web_search",
      # web_fetch aliases
      "fetch" => "web_fetch",
      "webfetch" => "web_fetch",
      "browse" => "web_fetch",
      "url_fetch" => "web_fetch",
      "http_get" => "web_fetch",
      # grep aliases
      "search_files" => "grep",
      "search_in_files" => "grep",
      "find_in_files" => "grep",
      "search_code" => "grep",
      # glob aliases
      "find_files" => "glob",
      "list_files" => "glob",
      "file_glob" => "glob",
      "search_filenames" => "glob",
      # invoke_skill aliases
      "skill" => "invoke_skill",
      "run_skill" => "invoke_skill",
      # todo_manager aliases
      "todo" => "todo_manager",
      "task_manager" => "todo_manager",
      # request_user_feedback aliases
      "ask_user" => "request_user_feedback",
      "user_feedback" => "request_user_feedback",
      "ask" => "request_user_feedback",
      # undo_task aliases
      "undo" => "undo_task",
      # redo_task aliases
      "redo" => "redo_task",
      # list_tasks aliases
      "tasks" => "list_tasks",
      "task_history" => "list_tasks",
      # trash_manager aliases
      "trash" => "trash_manager",
      "delete" => "trash_manager",
      "rm" => "trash_manager",
      "remove" => "trash_manager",
    }.freeze

    def initialize
      @tools = {}
      # Downcased index for case-insensitive lookups
      @downcased_index = {}
    end

    def register(tool)
      @tools[tool.name] = tool
      @downcased_index[tool.name.downcase] = tool.name
    end

    def get(name)
      @tools[name] || raise(Clacky::ToolCallError, "Tool not found: #{name}")
    end

    # Resolve a tool name (possibly misspelt or aliased) to the canonical
    # registered name.  Resolution order:
    #   1. Exact match in the registry
    #   2. Case-insensitive match (e.g. "Read" → "file_reader")
    #   3. Alias lookup (e.g. "read_file" → "file_reader")
    # Returns the canonical tool name, or nil if nothing matched.
    def resolve(name)
      return name if @tools.key?(name)

      downcased = name.downcase

      # Case-insensitive match
      if @downcased_index.key?(downcased)
        return @downcased_index[downcased]
      end

      # Alias lookup
      if TOOL_ALIASES.key?(downcased)
        return TOOL_ALIASES[downcased]
      end

      # Fuzzy: try underscore / hyphen normalisation (e.g. "file-reader" → "file_reader")
      normalized = downcased.tr("-", "_")
      if normalized != downcased
        if @downcased_index.key?(normalized)
          return @downcased_index[normalized]
        end
        if TOOL_ALIASES.key?(normalized)
          return TOOL_ALIASES[normalized]
        end
      end

      nil
    end

    def all
      @tools.values
    end

    def all_definitions
      @tools.values.map(&:to_function_definition)
    end

    def allowed_definitions(allowed_tools = nil)
      return all_definitions if allowed_tools.nil? || allowed_tools.include?("all")

      @tools.select { |name, _| allowed_tools.include?(name) }
             .values
             .map(&:to_function_definition)
    end

    def allowed?(name, allowed_tools = nil)
      return true if allowed_tools.nil? || allowed_tools.include?("all")

      allowed_tools.include?(name.to_s)
    end

    def tool_names
      @tools.keys
    end

    def by_category(category)
      @tools.values.select { |tool| tool.category == category }
    end
  end
end
