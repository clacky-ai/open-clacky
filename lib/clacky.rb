# frozen_string_literal: true

require_relative "clacky/version"
require_relative "clacky/message_format/anthropic"
require_relative "clacky/message_format/open_ai"
require_relative "clacky/message_format/bedrock"
require_relative "clacky/client"
require_relative "clacky/skill"
require_relative "clacky/skill_loader"

# Agent system
require_relative "clacky/message_history"
require_relative "clacky/agent_config"
require_relative "clacky/mcp_config"
require_relative "clacky/mcp_client"
require_relative "clacky/agent_profile"
require_relative "clacky/providers"
require_relative "clacky/session_manager"
require_relative "clacky/idle_compression_timer"

# Agent modules
require_relative "clacky/agent/message_compressor"
require_relative "clacky/agent/hook_manager"
require_relative "clacky/agent/tool_registry"

# UI modules
require_relative "clacky/ui2/thinking_verbs"
require_relative "clacky/ui2/progress_indicator"

# Utils
require_relative "clacky/utils/logger"
require_relative "clacky/utils/encoding"
require_relative "clacky/utils/model_pricing"
require_relative "clacky/utils/gitignore_parser"
require_relative "clacky/utils/limit_stack"
require_relative "clacky/utils/path_helper"
require_relative "clacky/utils/file_ignore_helper"
require_relative "clacky/utils/string_matcher"
require_relative "clacky/tools/base"
require_relative "clacky/utils/file_processor"

require_relative "clacky/tools/shell"
require_relative "clacky/tools/file_reader"
require_relative "clacky/tools/write"
require_relative "clacky/tools/edit"
require_relative "clacky/tools/glob"
require_relative "clacky/tools/grep"
require_relative "clacky/tools/web_search"
require_relative "clacky/tools/web_fetch"
require_relative "clacky/tools/todo_manager"
require_relative "clacky/tools/run_project"
require_relative "clacky/tools/safe_shell"
require_relative "clacky/tools/trash_manager"
require_relative "clacky/tools/request_user_feedback"
require_relative "clacky/tools/invoke_skill"
require_relative "clacky/tools/undo_task"
require_relative "clacky/tools/redo_task"
require_relative "clacky/tools/list_tasks"
require_relative "clacky/tools/browser"
require_relative "clacky/mcp_tool_adapter"
require_relative "clacky/agent"

require_relative "clacky/server/session_registry"
require_relative "clacky/server/web_ui_controller"
require_relative "clacky/server/browser_manager"
require_relative "clacky/cli"

module Clacky
  class AgentInterrupted < Exception; end  # Inherit from Exception to bypass rescue StandardError
  class AgentError < StandardError; end
  class RetryableError < StandardError; end  # Transient errors that should be retried (5xx, HTML response, rate limit)
  class ToolCallError < AgentError; end  # Raised when tool call fails due to invalid parameters
  # BrowserManager singleton: Clacky::BrowserManager.instance
end
