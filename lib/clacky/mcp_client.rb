# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "net/http"
require "uri"

module Clacky
  # McpClient provides a unified interface for connecting to MCP (Model Context Protocol)
  # servers over three transports: stdio, sse, and http.
  #
  # Usage:
  #   client = McpClient.for_server("my_server", config)
  #   client.connect!
  #   tools = client.list_tools
  #   result = client.call_tool("read_file", { path: "/tmp/foo.txt" })
  #   client.close
  class McpClient
    # MCP protocol version used in handshake
    MCP_PROTOCOL_VERSION = "2024-11-05"

    # Handshake and call timeouts (seconds)
    HANDSHAKE_TIMEOUT = 15
    CALL_TIMEOUT      = 60

    attr_reader :server_name, :tools

    # Factory: build the right McpClient subclass from a server config hash.
    # @param name   [String] server name (from mcp.yml key)
    # @param config [Hash]   server config hash (type, command/url, etc.)
    # @return [McpClient subclass]
    def self.for_server(name, config)
      type = config["type"]
      case type
      when "stdio"
        StdioMcpClient.new(name, config)
      when "sse"
        SseMcpClient.new(name, config)
      when "http"
        HttpMcpClient.new(name, config)
      else
        raise ArgumentError, "Unknown MCP transport type: #{type.inspect}"
      end
    end

    def initialize(server_name, config)
      @server_name = server_name
      @config      = config
      @tools       = []        # Array of tool definition Hashes from tools/list
      @connected   = false
      @call_id     = 1
      @mutex       = Mutex.new
    end

    # Connect to the MCP server and complete the initialize handshake.
    # Populates @tools via tools/list.
    # @return [self]
    def connect!
      raise NotImplementedError, "#{self.class} must implement #connect!"
    end

    # Call a remote MCP tool.
    # @param tool_name [String]
    # @param arguments [Hash]
    # @return [Hash] — raw MCP result hash (contains :content key)
    def call_tool(tool_name, arguments = {})
      raise NotImplementedError, "#{self.class} must implement #call_tool"
    end

    # Close the connection / terminate any child process.
    def close
      # Default: no-op. Subclasses override if needed.
    end

    def connected? = @connected

    # -------------------------------------------------------------------------
    # Shared helpers
    # -------------------------------------------------------------------------

    # Increment and return the next JSON-RPC id.
    # Must be called while already holding @mutex (connect! / call_tool),
    # so we do NOT synchronize here to avoid recursive locking deadlocks.
    private def next_id
      id = @call_id
      @call_id += 1
      id
    end

    private def build_json_rpc(method, params, id: next_id)
      JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params })
    end

    private def build_notification(method, params = {})
      JSON.generate({ jsonrpc: "2.0", method: method, params: params })
    end

    # Parse and validate a JSON-RPC response, returning the result value.
    # Raises McpError on protocol errors or remote errors.
    private def unwrap_result(response)
      if response["error"]
        err = response["error"]
        raise McpError, "MCP error #{err['code']}: #{err['message']}"
      end
      response["result"]
    end

    # Extract text content from MCP tool result.
    # MCP result["content"] is an array of content blocks: { type: "text", text: "..." }
    # @param result [Hash] raw result from unwrap_result
    # @return [String]
    private def extract_content_text(result)
      return result.to_s unless result.is_a?(Hash)

      contents = result["content"] || []
      texts = contents.select { |c| c["type"] == "text" }.map { |c| c["text"] }
      texts.join("\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Stdio transport — spawns a local child process and speaks JSON-RPC over
  # its stdin/stdout (same as the Browser tool's Chrome MCP implementation).
  # ---------------------------------------------------------------------------
  class StdioMcpClient < McpClient
    def connect!
      @mutex.synchronize do
        return self if @connected

        cmd = build_command
        env = build_env

        @stdin, @stdout, stderr_io, @wait_thr = Open3.popen3(env, *cmd)
        # Drain stderr asynchronously to avoid pipe-buffer deadlocks
        Thread.new { stderr_io.read rescue nil }

        perform_handshake!
        fetch_tools!

        @connected = true
      end
      self
    end

    def call_tool(tool_name, arguments = {})
      @mutex.synchronize do
        raise McpError, "Not connected to #{server_name}" unless @connected && process_alive?

        id  = next_id
        msg = build_json_rpc("tools/call", { name: tool_name, arguments: arguments }, id: id)
        @stdin.write(msg + "\n")
        @stdin.flush

        resp = read_response(@stdout, target_id: id, timeout: CALL_TIMEOUT)
        raise McpError, "tools/call timed out for #{server_name}/#{tool_name}" unless resp

        unwrap_result(resp)
      end
    end

    def close
      @mutex.synchronize do
        return unless @connected

        @stdin.close  rescue nil
        @stdout.close rescue nil
        Process.kill("TERM", @wait_thr.pid) rescue nil
        @connected = false
      end
    end

    # -------------------------------------------------------------------------
    private
    # -------------------------------------------------------------------------

    private def build_command
      command = @config["command"]
      raise ArgumentError, "stdio MCP server '#{server_name}' missing 'command'" unless command

      args = Array(@config["args"] || []).map(&:to_s)
      [command, *args]
    end

    private def build_env
      env_cfg = @config["env"] || {}
      env_cfg.transform_keys(&:to_s).transform_values(&:to_s)
    end

    private def perform_handshake!
      id       = 1   # reserve id=1 for initialize
      init_msg = build_json_rpc("initialize", {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities:    {},
        clientInfo:      { name: "clacky", version: Clacky::VERSION }
      }, id: id)

      @stdin.write(init_msg + "\n")
      @stdin.flush

      resp = read_response(@stdout, target_id: id, timeout: HANDSHAKE_TIMEOUT)
      unless resp
        close_process!
        raise McpError, "MCP initialize handshake timed out for server '#{server_name}'"
      end

      notify = build_notification("notifications/initialized")
      @stdin.write(notify + "\n")
      @stdin.flush

      @call_id = 2   # ids 1+ are now in use
    end

    private def fetch_tools!
      id  = next_id
      msg = build_json_rpc("tools/list", {}, id: id)
      @stdin.write(msg + "\n")
      @stdin.flush

      resp = read_response(@stdout, target_id: id, timeout: HANDSHAKE_TIMEOUT)
      return unless resp

      result = unwrap_result(resp)
      @tools = Array(result&.dig("tools") || [])
    rescue McpError
      @tools = []
    end

    private def process_alive?
      return false if @wait_thr.nil?

      Process.kill(0, @wait_thr.pid)
      !@stdin.closed? && !@stdout.closed?
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    private def close_process!
      @stdin.close  rescue nil
      @stdout.close rescue nil
      Process.kill("TERM", @wait_thr.pid) rescue nil
    end

    # Read newline-delimited JSON-RPC responses, returning the one with matching id.
    # Ignores notification messages (no "id" field) and unknown ids.
    private def read_response(io, target_id:, timeout:)
      Timeout.timeout(timeout) do
        loop do
          line = io.gets
          break if line.nil?

          line = line.strip
          next if line.empty?

          begin
            msg = JSON.parse(line)
            # Skip notifications (no id) and mismatched ids
            return msg if msg["id"] == target_id
          rescue JSON::ParserError
            # skip malformed lines
          end
        end
      end
      nil
    rescue Timeout::Error
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Streamable HTTP transport — sends POST requests to a single MCP endpoint
  # (the newer "Streamable HTTP" transport defined in MCP 2025-03-26 spec).
  # ---------------------------------------------------------------------------
  class HttpMcpClient < McpClient
    def connect!
      @mutex.synchronize do
        return self if @connected

        fetch_tools!
        @connected = true
      end
      self
    end

    def call_tool(tool_name, arguments = {})
      id = nil
      payload = nil
      @mutex.synchronize do
        id      = next_id
        payload = JSON.parse(build_json_rpc("tools/call", { name: tool_name, arguments: arguments }, id: id))
      end
      resp = http_post(payload)
      unwrap_result(resp)
    end

    # -------------------------------------------------------------------------
    private
    # -------------------------------------------------------------------------

    private def http_url
      @config["url"] or raise ArgumentError, "http MCP server '#{server_name}' missing 'url'"
    end

    private def extra_headers
      (@config["headers"] || {}).transform_keys(&:to_s)
    end

    private def http_post(payload)
      uri  = URI.parse(http_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = CALL_TIMEOUT
      http.open_timeout = HANDSHAKE_TIMEOUT

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["Accept"]       = "application/json, text/event-stream"
      extra_headers.each { |k, v| req[k] = v }
      req.body = JSON.generate(payload)

      raw = http.request(req)

      unless raw.is_a?(Net::HTTPSuccess)
        raise McpError, "HTTP #{raw.code} from #{server_name}: #{raw.body.to_s[0..200]}"
      end

      # Handle SSE-wrapped response (Content-Type: text/event-stream)
      if raw["content-type"]&.include?("text/event-stream")
        parse_sse_body(raw.body)
      else
        JSON.parse(raw.body)
      end
    end

    private def fetch_tools!
      id      = next_id
      payload = JSON.parse(build_json_rpc("tools/list", {}, id: id))
      resp    = http_post(payload)
      result  = unwrap_result(resp)
      @tools  = Array(result&.dig("tools") || [])
    rescue => e
      warn "[McpClient] #{server_name}: tools/list failed: #{e.message}"
      @tools = []
    end

    # Parse a minimal SSE body and extract the first JSON-RPC message data line.
    private def parse_sse_body(body)
      body.each_line do |line|
        line = line.strip
        next unless line.start_with?("data:")

        data = line.sub(/\Adata:\s*/, "")
        begin
          return JSON.parse(data)
        rescue JSON::ParserError
          # skip non-JSON data lines
        end
      end
      raise McpError, "No valid JSON-RPC data found in SSE response from #{server_name}"
    end
  end

  # ---------------------------------------------------------------------------
  # SSE transport — connects to a Server-Sent Events endpoint for the older
  # MCP SSE transport (HTTP GET for events, HTTP POST for sending messages).
  # Note: Full bidirectional SSE requires long-lived GET connection. This
  # implementation uses a simplified request-response approach suitable for
  # most MCP SSE servers (many servers accept POST to /messages endpoint).
  # ---------------------------------------------------------------------------
  class SseMcpClient < HttpMcpClient
    private def http_url
      base = @config["url"] or raise ArgumentError, "sse MCP server '#{server_name}' missing 'url'"
      # Use the base URL directly — SSE servers usually accept POST at root or /message
      base
    end
  end

  # Raised on any MCP protocol or transport error.
  class McpError < StandardError; end
end
