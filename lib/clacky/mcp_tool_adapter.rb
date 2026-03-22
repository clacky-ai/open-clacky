# frozen_string_literal: true

module Clacky
  # McpToolAdapter wraps a single MCP remote tool as a Clacky::Tools::Base-compatible
  # object, so it can be registered in the ToolRegistry and used by the Agent
  # transparently alongside built-in tools.
  #
  # Each adapter holds a reference to the McpClient it was created from, and
  # delegates #execute calls to that client's #call_tool method.
  #
  # Tool names are prefixed with the server name to avoid collisions:
  #   server "github" + tool "search_repos" → name "mcp__github__search_repos"
  #
  # Usage (internal — called by Agent during MCP initialization):
  #   client = McpClient.for_server("github", config)
  #   client.connect!
  #   adapters = McpToolAdapter.from_client(client)
  #   adapters.each { |a| tool_registry.register(a) }
  class McpToolAdapter < Tools::Base
    # Separator used to compose the namespaced tool name
    NAME_SEP = "__"

    # Build adapters for all tools discovered from a connected McpClient.
    # @param client [McpClient]
    # @return [Array<McpToolAdapter>]
    def self.from_client(client)
      client.tools.map { |tool_def| new(client, tool_def) }
    end

    # @param client   [McpClient]   connected MCP client
    # @param tool_def [Hash]        tool definition from MCP tools/list response
    def initialize(client, tool_def)
      @mcp_client    = client
      @tool_def      = tool_def
      @remote_name   = tool_def["name"].to_s
      @tool_name     = build_namespaced_name(client.server_name, @remote_name)
      @tool_description = build_description(client.server_name, tool_def)
      @tool_parameters  = build_parameters(tool_def)
      @tool_category    = "mcp"
    end

    def name        = @tool_name
    def description = @tool_description
    def parameters  = @tool_parameters
    def category    = @tool_category

    # Execute: delegate to the remote MCP server via the client.
    # Converts the result content blocks to a plain string for the Agent.
    def execute(**args)
      # Remove internal Clacky metadata keys that aren't part of the MCP schema
      clean_args = args.reject { |k, _| k.to_s.start_with?("_clacky") }

      result = @mcp_client.call_tool(@remote_name, clean_args)
      extract_text(result)
    rescue McpError => e
      { error: "MCP tool error (#{@tool_name}): #{e.message}" }
    rescue => e
      { error: "Unexpected error calling MCP tool #{@tool_name}: #{e.message}" }
    end

    def format_call(args)
      "mcp:#{@mcp_client.server_name}/#{@remote_name}(#{summarize_args(args)})"
    end

    def format_result(result)
      return "[MCP Error] #{result[:error].to_s[0..120]}" if result.is_a?(Hash) && result[:error]

      text = result.to_s
      text.length > 120 ? "#{text[0..120]}..." : text
    end

    # Override to_function_definition so the MCP schema is passed through exactly.
    # The remote tool's inputSchema is already in JSON Schema format.
    def to_function_definition
      {
        type: "function",
        function: {
          name: @tool_name,
          description: @tool_description,
          parameters: @tool_parameters
        }
      }
    end

    # -------------------------------------------------------------------------
    private
    # -------------------------------------------------------------------------

    # Build the namespaced tool name used in ToolRegistry and LLM function calls.
    # Format: mcp__<server_name>__<remote_tool_name>
    # Both server_name and tool_name are sanitized to replace non-alphanumeric chars.
    private def build_namespaced_name(server_name, tool_name)
      safe_server = server_name.gsub(/[^a-zA-Z0-9_]/, "_")
      safe_tool   = tool_name.gsub(/[^a-zA-Z0-9_]/, "_")
      "mcp#{NAME_SEP}#{safe_server}#{NAME_SEP}#{safe_tool}"
    end

    # Compose a description that includes the server origin for clarity.
    private def build_description(server_name, tool_def)
      base = tool_def["description"].to_s.strip
      prefix = "[MCP:#{server_name}]"
      base.empty? ? "#{prefix} #{@remote_name}" : "#{prefix} #{base}"
    end

    # Extract and normalize the tool's input schema from the MCP tool definition.
    # Falls back to an empty-object schema if not provided.
    private def build_parameters(tool_def)
      schema = tool_def["inputSchema"] || tool_def["input_schema"] || {}
      return default_parameters if schema.empty?

      # Ensure top-level type is "object" (required by OpenAI function calling)
      schema = schema.transform_keys(&:to_s)
      schema["type"] ||= "object"
      schema
    end

    private def default_parameters
      { "type" => "object", "properties" => {}, "required" => [] }
    end

    # Convert MCP result to a plain string.
    # MCP result["content"] is an array of content blocks: { "type": "text", "text": "..." }
    private def extract_text(result)
      return result.to_s unless result.is_a?(Hash)

      contents = result["content"] || []
      if contents.empty?
        # Some servers put text directly at result level
        return result["text"].to_s if result["text"]
        return result.to_s
      end

      texts = contents.select { |c| c.is_a?(Hash) && c["type"] == "text" }.map { |c| c["text"].to_s }
      texts.join("\n")
    end

    # Format args hash as a short summary for display.
    private def summarize_args(args)
      return "" if args.nil? || args.empty?

      args.map { |k, v|
        val_str = v.to_s
        val_str = "#{val_str[0..30]}..." if val_str.length > 33
        "#{k}: #{val_str}"
      }.join(", ")
    end
  end
end
