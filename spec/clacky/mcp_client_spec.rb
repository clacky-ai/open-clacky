# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::McpClient do
  describe ".for_server" do
    it "returns a StdioMcpClient for type=stdio" do
      cfg    = { "type" => "stdio", "command" => "npx" }
      client = described_class.for_server("test", cfg)
      expect(client).to be_a(Clacky::StdioMcpClient)
    end

    it "returns an SseMcpClient for type=sse" do
      cfg    = { "type" => "sse", "url" => "https://mcp.example.com/sse" }
      client = described_class.for_server("test", cfg)
      expect(client).to be_a(Clacky::SseMcpClient)
    end

    it "returns an HttpMcpClient for type=http" do
      cfg    = { "type" => "http", "url" => "https://mcp.example.com/mcp" }
      client = described_class.for_server("test", cfg)
      expect(client).to be_a(Clacky::HttpMcpClient)
    end

    it "raises ArgumentError for unknown type" do
      cfg = { "type" => "grpc" }
      expect { described_class.for_server("test", cfg) }
        .to raise_error(ArgumentError, /Unknown MCP transport type/)
    end
  end

  describe "#server_name" do
    it "returns the name passed to the constructor" do
      cfg    = { "type" => "stdio", "command" => "echo" }
      client = described_class.for_server("my_server", cfg)
      expect(client.server_name).to eq("my_server")
    end
  end

  describe "#connected?" do
    it "is false before connect!" do
      cfg    = { "type" => "stdio", "command" => "echo" }
      client = described_class.for_server("s", cfg)
      expect(client.connected?).to be false
    end
  end
end

RSpec.describe Clacky::StdioMcpClient do
  let(:config) { { "type" => "stdio", "command" => "cat" } }
  let(:client) { described_class.new("test", config) }

  describe "#connect! with a real echo process" do
    # Simulate a minimal MCP server that responds to initialize and tools/list
    # by spawning a Ruby one-liner that echoes back JSON-RPC responses.
    let(:fake_server_script) do
      # rubocop:disable Style/StringLiterals
      <<~'RUBY'
        require 'json'
        STDOUT.sync = true
        STDIN.each_line do |line|
          begin
            msg = JSON.parse(line.strip)
            next unless msg['id']
            meth = msg['method']
            if meth == 'initialize'
              puts JSON.generate({
                jsonrpc: '2.0',
                id: msg['id'],
                result: { protocolVersion: '2024-11-05', capabilities: {}, serverInfo: { name: 'fake' } }
              })
            elsif meth == 'tools/list'
              puts JSON.generate({
                jsonrpc: '2.0',
                id: msg['id'],
                result: {
                  tools: [
                    { name: 'echo_tool', description: 'Echoes input', inputSchema: { type: 'object', properties: { message: { type: 'string' } } } }
                  ]
                }
              })
            elsif meth == 'tools/call'
              call_args = msg.dig('params', 'arguments') || {}
              puts JSON.generate({
                jsonrpc: '2.0',
                id: msg['id'],
                result: { content: [{ type: 'text', text: "echo: #{call_args.inspect}" }] }
              })
            end
          rescue
            # silently skip bad lines
          end
        end
      RUBY
      # rubocop:enable Style/StringLiterals
    end

    let(:server_cfg) do
      { "type" => "stdio", "command" => RbConfig.ruby, "args" => ["-e", fake_server_script] }
    end

    let(:real_client) { Clacky::StdioMcpClient.new("fake_server", server_cfg) }

    after { real_client.close }

    it "connects and discovers tools" do
      real_client.connect!
      expect(real_client.connected?).to be true
      expect(real_client.tools).not_to be_empty
      expect(real_client.tools.first["name"]).to eq("echo_tool")
    end

    it "calls a remote tool and returns result" do
      real_client.connect!
      result = real_client.call_tool("echo_tool", { "message" => "hello" })
      content = result["content"]
      expect(content).not_to be_empty
      expect(content.first["text"]).to include("echo:")
    end

    it "raises McpError when call_tool is called without connect!" do
      expect { real_client.call_tool("echo_tool", {}) }
        .to raise_error(Clacky::McpError, /Not connected/)
    end
  end

  describe "#connect! raises when command is missing" do
    let(:client) { described_class.new("bad", { "type" => "stdio" }) }

    it "raises ArgumentError" do
      expect { client.connect! }.to raise_error(ArgumentError, /missing 'command'/)
    end
  end
end

RSpec.describe Clacky::McpToolAdapter do
  let(:tool_def) do
    {
      "name"        => "list_files",
      "description" => "List files in a directory",
      "inputSchema" => {
        "type"       => "object",
        "properties" => { "path" => { "type" => "string" } },
        "required"   => ["path"]
      }
    }
  end

  let(:mock_client) do
    client = instance_double(Clacky::StdioMcpClient, server_name: "filesystem", tools: [tool_def])
    client
  end

  let(:adapter) { described_class.new(mock_client, tool_def) }

  describe "#name" do
    it "is prefixed with mcp__<server>__<tool>" do
      expect(adapter.name).to eq("mcp__filesystem__list_files")
    end

    it "sanitizes non-alphanumeric characters" do
      defn    = tool_def.merge("name" => "list-files.v2")
      adapter = described_class.new(mock_client, defn)
      expect(adapter.name).to eq("mcp__filesystem__list_files_v2")
    end
  end

  describe "#description" do
    it "prefixes description with [MCP:<server>]" do
      expect(adapter.description).to include("[MCP:filesystem]")
      expect(adapter.description).to include("List files in a directory")
    end
  end

  describe "#parameters" do
    it "returns the inputSchema from the tool definition" do
      params = adapter.parameters
      expect(params["type"]).to eq("object")
      expect(params["properties"]).to have_key("path")
    end
  end

  describe "#category" do
    it "is 'mcp'" do
      expect(adapter.category).to eq("mcp")
    end
  end

  describe "#execute" do
    it "delegates to the MCP client and returns text content" do
      allow(mock_client).to receive(:call_tool).with("list_files", { path: "/tmp" })
        .and_return({ "content" => [{ "type" => "text", "text" => "file1.txt\nfile2.txt" }] })

      result = adapter.execute(path: "/tmp")
      expect(result).to eq("file1.txt\nfile2.txt")
    end

    it "returns an error hash on McpError" do
      allow(mock_client).to receive(:call_tool).and_raise(Clacky::McpError, "timeout")

      result = adapter.execute(path: "/tmp")
      expect(result).to be_a(Hash)
      expect(result[:error]).to include("timeout")
    end
  end

  describe "#to_function_definition" do
    it "has the correct structure for LLM function calling" do
      fd = adapter.to_function_definition
      expect(fd[:type]).to eq("function")
      expect(fd[:function][:name]).to eq("mcp__filesystem__list_files")
      expect(fd[:function][:description]).to include("[MCP:filesystem]")
      expect(fd[:function][:parameters]).to be_a(Hash)
    end
  end

  describe ".from_client" do
    it "builds one adapter per tool" do
      client = instance_double(Clacky::StdioMcpClient, server_name: "fs", tools: [tool_def, tool_def.merge("name" => "write_file")])
      adapters = described_class.from_client(client)
      expect(adapters.size).to eq(2)
      expect(adapters.map(&:name)).to include("mcp__fs__list_files", "mcp__fs__write_file")
    end
  end
end
