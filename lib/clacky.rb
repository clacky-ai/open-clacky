# frozen_string_literal: true

# ── Global encoding defaults ──────────────────────────────────────────────────
# Force UTF-8 as the default external/internal encoding for all IO operations
# (File.read, Open3.capture3, HTTP bodies, etc.) so that binary-encoded strings
# from external processes or network I/O never cause "invalid byte sequence in
# UTF-8" errors on Ruby 2.6+.
# Binary-specific operations (File.binread, IO#read with "b" mode, .b) are
# unaffected — they always bypass this setting.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# ── Ruby < 2.7 polyfills ──────────────────────────────────────────────────────

# Enumerable#filter_map was added in Ruby 2.7.
if RUBY_VERSION < "2.7"
  module Enumerable
    def filter_map(&block)
      return to_enum(:filter_map) unless block

      each_with_object([]) do |item, result|
        mapped = block.call(item)
        result << mapped if mapped
      end
    end
  end
end

# File.absolute_path? was added in Ruby 2.7.
# Polyfill: a path is absolute if it starts with "/" (Unix) or a drive letter (Windows).
unless File.respond_to?(:absolute_path?)
  def File.absolute_path?(path)
    File.expand_path(path) == path.to_s
  end
end

# URI.encode_uri_component was added in Ruby 3.2.
# CGI.escape encodes spaces as '+'; replace with '%20' to match URI encoding.
require "uri"
require "cgi"
unless URI.respond_to?(:encode_uri_component)
  def URI.encode_uri_component(str)
    CGI.escape(str.to_s).gsub("+", "%20")
  end
end

# YAML.safe_load with permitted_classes: keyword was added in Psych 4 (Ruby 3.1).
# On older Ruby, the second positional argument serves the same purpose.
# This helper provides a unified interface across Ruby versions.
module YAMLCompat
  def self.safe_load(yaml_string, permitted_classes: [])
    if Psych::VERSION >= "4.0"
      YAML.safe_load(yaml_string, permitted_classes: permitted_classes)
    else
      YAML.safe_load(yaml_string, permitted_classes)
    end
  end

  def self.load_file(path, permitted_classes: [])
    safe_load(File.read(path), permitted_classes: permitted_classes)
  end
end

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
require_relative "clacky/agent_profile"
require_relative "clacky/providers"
require_relative "clacky/clacky_auth_client"
require_relative "clacky/clacky_cloud_config"
require_relative "clacky/cloud_project_client"
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
require_relative "clacky/platform_http_client"
require_relative "clacky/utils/encoding"
require_relative "clacky/utils/environment_detector"
require_relative "clacky/utils/browser_detector"
require_relative "clacky/utils/scripts_manager"
require_relative "clacky/utils/model_pricing"
require_relative "clacky/utils/gitignore_parser"
require_relative "clacky/utils/limit_stack"
require_relative "clacky/utils/path_helper"
require_relative "clacky/utils/file_ignore_helper"
require_relative "clacky/utils/string_matcher"
require_relative "clacky/tools/base"
require_relative "clacky/utils/file_processor"

require_relative "clacky/tools/security"
require_relative "clacky/tools/file_reader"
require_relative "clacky/tools/write"
require_relative "clacky/tools/edit"
require_relative "clacky/tools/glob"
require_relative "clacky/tools/grep"
require_relative "clacky/tools/web_search"
require_relative "clacky/tools/web_fetch"
require_relative "clacky/tools/todo_manager"
require_relative "clacky/tools/run_project"
require_relative "clacky/tools/trash_manager"
require_relative "clacky/tools/request_user_feedback"
require_relative "clacky/tools/invoke_skill"
require_relative "clacky/tools/undo_task"
require_relative "clacky/tools/redo_task"
require_relative "clacky/tools/list_tasks"
require_relative "clacky/tools/browser"
require_relative "clacky/tools/terminal"
require_relative "clacky/telemetry"
require_relative "clacky/agent"

require_relative "clacky/server/session_registry"
require_relative "clacky/server/web_ui_controller"
require_relative "clacky/server/browser_manager"
require_relative "clacky/cli"

module Clacky
  class AgentInterrupted < Exception; end  # Inherit from Exception to bypass rescue StandardError
  class AgentError < StandardError; end
  class BadRequestError < AgentError; end  # 400 errors — our request was malformed, history should be rolled back
  class RetryableError < StandardError; end  # Transient errors that should be retried (5xx, HTML response, rate limit)
  class ToolCallError < AgentError; end  # Raised when tool call fails due to invalid parameters
  class BrowserNotReachableError < AgentError; end  # Chrome/Edge not running or remote debugging disabled
  # BrowserManager singleton: Clacky::BrowserManager.instance
end
