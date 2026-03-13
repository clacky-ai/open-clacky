# frozen_string_literal: true

RSpec.describe Clacky::Agent do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      # Set @api_key instance variable to avoid "API key not configured" error
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) do
    Clacky::AgentConfig.new(
      model: "gpt-3.5-turbo",
      permission_mode: :auto_approve
    )
  end
  let(:agent) { described_class.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id) }

  describe "#initialize" do
    it "sets initial state" do
      expect(agent.iterations).to eq(0)
      expect(agent.total_cost).to eq(0.0)
      expect(agent.session_id).to be_a(String)
    end
  end

  describe "#run" do
    let(:tool_call_response) do
      mock_api_response(
        content: nil,
        tool_calls: [mock_tool_call(name: "calculator", args: '{"expression":"1+1"}')]
      )
    end

    let(:final_response) do
      mock_api_response(content: "The result is 2")
    end

    before do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(tool_call_response, final_response)

      # Mock the format_tool_results method
      allow(client).to receive(:format_tool_results) do |response, tool_results, model:|
        response[:tool_calls].map do |call|
          result = tool_results.find { |r| r[:id] == call[:id] }
          if result
            {
              role: "tool",
              tool_call_id: call[:id],
              content: result[:content]
            }
          else
            {
              role: "tool",
              tool_call_id: call[:id],
              content: JSON.generate({ error: "Tool result missing" })
            }
          end
        end
      end
    end

    it "executes Think-Act-Observe loop" do
      result = agent.run("Calculate 1+1")

      expect(result[:status]).to eq(:success)
      expect(result[:iterations]).to be > 0
      expect(client).to have_received(:send_messages_with_tools).at_least(:once)
    end

    it "tracks iteration count" do
      agent.run("test")
      expect(agent.iterations).to be > 0
    end

    it "tracks cost" do
      agent.run("test")
      expect(agent.total_cost).to be > 0
    end


  end

  describe "#add_hook" do
    it "allows adding hooks" do
      hook_called = false

      agent.add_hook(:on_start) do |input|
        hook_called = true
        expect(input).to eq("test input")
      end

      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "done"))

      agent.run("test input")

      expect(hook_called).to be true
    end
  end

  describe "#observe" do
    it "maintains tool results in same order as tool_calls" do
      # Mock the format_tool_results method
      allow(client).to receive(:format_tool_results) do |response, tool_results, model:|
        # Simulate OpenAI format output
        response[:tool_calls].map do |call|
          result = tool_results.find { |r| r[:id] == call[:id] }
          if result
            {
              role: "tool",
              tool_call_id: call[:id],
              content: result[:content]
            }
          else
            {
              role: "tool",
              tool_call_id: call[:id],
              content: JSON.generate({ error: "Tool result missing" })
            }
          end
        end
      end

      # Simulate a response with multiple tool calls
      response = {
        tool_calls: [
          { id: "call_1", type: "function", function: { name: "tool_a", arguments: "{}" } },
          { id: "call_2", type: "function", function: { name: "tool_b", arguments: "{}" } },
          { id: "call_3", type: "function", function: { name: "tool_c", arguments: "{}" } }
        ]
      }

      # Tool results arrive in different order (e.g., due to concurrent execution)
      tool_results = [
        { id: "call_3", content: JSON.generate({ result: "C" }) },
        { id: "call_1", content: JSON.generate({ result: "A" }) },
        { id: "call_2", content: JSON.generate({ result: "B" }) }
      ]

      # Call observe
      agent.send(:observe, response, tool_results)

      # Get the messages
      messages = agent.instance_variable_get(:@messages)
      tool_messages = messages.select { |m| m[:role] == "tool" }

      # Verify the order matches the original tool_calls order
      expect(tool_messages.size).to eq(3)
      expect(tool_messages[0][:tool_call_id]).to eq("call_1")
      expect(tool_messages[1][:tool_call_id]).to eq("call_2")
      expect(tool_messages[2][:tool_call_id]).to eq("call_3")
    end

    it "handles missing tool results with error fallback" do
      # Mock the format_tool_results method
      allow(client).to receive(:format_tool_results) do |response, tool_results, model:|
        response[:tool_calls].map do |call|
          result = tool_results.find { |r| r[:id] == call[:id] }
          if result
            {
              role: "tool",
              tool_call_id: call[:id],
              content: result[:content]
            }
          else
            {
              role: "tool",
              tool_call_id: call[:id],
              content: JSON.generate({ error: "Tool result missing" })
            }
          end
        end
      end

      response = {
        tool_calls: [
          { id: "call_1", type: "function", function: { name: "tool_a", arguments: "{}" } },
          { id: "call_2", type: "function", function: { name: "tool_b", arguments: "{}" } }
        ]
      }

      # Only one result provided
      tool_results = [
        { id: "call_1", content: JSON.generate({ result: "A" }) }
      ]

      agent.send(:observe, response, tool_results)

      messages = agent.instance_variable_get(:@messages)
      tool_messages = messages.select { |m| m[:role] == "tool" }

      expect(tool_messages.size).to eq(2)
      expect(tool_messages[0][:tool_call_id]).to eq("call_1")
      expect(tool_messages[1][:tool_call_id]).to eq("call_2")

      # Second message should be an error
      error_content = JSON.parse(tool_messages[1][:content])
      expect(error_content["error"]).to eq("Tool result missing")
    end
  end

  describe "#get_recent_messages_with_tool_pairs" do
    it "includes all tool results for assistant with multiple tool_calls" do
      messages = [
        { role: "system", content: "System prompt" },
        { role: "user", content: "Do multiple things" },
        {
          role: "assistant",
          content: nil,
          tool_calls: [
            { id: "call_1", type: "function", function: { name: "tool_a", arguments: "{}" } },
            { id: "call_2", type: "function", function: { name: "tool_b", arguments: "{}" } },
            { id: "call_3", type: "function", function: { name: "tool_c", arguments: "{}" } }
          ]
        },
        { role: "tool", tool_call_id: "call_1", content: "Result A" },
        { role: "tool", tool_call_id: "call_2", content: "Result B" },
        { role: "tool", tool_call_id: "call_3", content: "Result C" },
        { role: "assistant", content: "Done with all three tasks" }
      ]

      # Request only 2 recent messages - should get assistant + all 3 tool results
      recent = agent.send(:get_recent_messages_with_tool_pairs, messages, 2)

      # Should include: final assistant, the 3 tool results, and the assistant with tool_calls
      expect(recent.size).to eq(5)
      
      # Verify order is preserved
      expect(recent[0][:role]).to eq("assistant")
      expect(recent[0][:tool_calls].size).to eq(3)
      expect(recent[1][:role]).to eq("tool")
      expect(recent[1][:tool_call_id]).to eq("call_1")
      expect(recent[2][:role]).to eq("tool")
      expect(recent[2][:tool_call_id]).to eq("call_2")
      expect(recent[3][:role]).to eq("tool")
      expect(recent[3][:tool_call_id]).to eq("call_3")
      expect(recent[4][:role]).to eq("assistant")
    end

    it "handles multiple assistant messages with tool_calls" do
      messages = [
        { role: "system", content: "System" },
        { role: "user", content: "First request" },
        {
          role: "assistant",
          tool_calls: [
            { id: "call_1", type: "function", function: { name: "tool_a", arguments: "{}" } },
            { id: "call_2", type: "function", function: { name: "tool_b", arguments: "{}" } }
          ]
        },
        { role: "tool", tool_call_id: "call_1", content: "A1" },
        { role: "tool", tool_call_id: "call_2", content: "B1" },
        { role: "assistant", content: "First done" },
        { role: "user", content: "Second request" },
        {
          role: "assistant",
          tool_calls: [
            { id: "call_3", type: "function", function: { name: "tool_c", arguments: "{}" } },
            { id: "call_4", type: "function", function: { name: "tool_d", arguments: "{}" } }
          ]
        },
        { role: "tool", tool_call_id: "call_3", content: "C1" },
        { role: "tool", tool_call_id: "call_4", content: "D1" },
        { role: "assistant", content: "Second done" }
      ]

      # Request 3 recent messages
      recent = agent.send(:get_recent_messages_with_tool_pairs, messages, 3)

      # Should include: last assistant + the 2 tool results before it + assistant with tool_calls
      expect(recent.size).to eq(4)
      expect(recent.map { |m| m[:role] }).to eq(["assistant", "tool", "tool", "assistant"])
      expect(recent[0][:tool_calls].map { |tc| tc[:id] }).to eq(["call_3", "call_4"])
    end

    it "maintains correct order when encountering tool results" do
      messages = [
        { role: "system", content: "System" },
        { role: "user", content: "Request" },
        {
          role: "assistant",
          tool_calls: [
            { id: "call_1", type: "function", function: { name: "file_reader", arguments: "{}" } },
            { id: "call_2", type: "function", function: { name: "grep", arguments: "{}" } }
          ]
        },
        { role: "tool", tool_call_id: "call_1", content: "File content" },
        { role: "tool", tool_call_id: "call_2", content: "Grep results" },
        { role: "assistant", content: "Analysis complete" }
      ]

      recent = agent.send(:get_recent_messages_with_tool_pairs, messages, 1)

      # Should get the final assistant message only
      expect(recent.size).to eq(1)
      expect(recent[0][:content]).to eq("Analysis complete")
    end

    it "handles nested tool calls correctly" do
      messages = [
        { role: "system", content: "System" },
        { role: "user", content: "Complex task" },
        {
          role: "assistant",
          tool_calls: [
            { id: "call_1", type: "function", function: { name: "todo_manager", arguments: '{"action":"add"}' } }
          ]
        },
        { role: "tool", tool_call_id: "call_1", content: "TODO added" },
        { role: "assistant", content: "Now executing" },
        {
          role: "assistant",
          tool_calls: [
            { id: "call_2", type: "function", function: { name: "file_reader", arguments: "{}" } },
            { id: "call_3", type: "function", function: { name: "edit", arguments: "{}" } }
          ]
        },
        { role: "tool", tool_call_id: "call_2", content: "File read" },
        { role: "tool", tool_call_id: "call_3", content: "Edit done" },
        {
          role: "assistant",
          tool_calls: [
            { id: "call_4", type: "function", function: { name: "todo_manager", arguments: '{"action":"complete"}' } }
          ]
        },
        { role: "tool", tool_call_id: "call_4", content: "TODO completed" }
      ]

      # Request 2 recent messages - should get call_4 pair
      recent = agent.send(:get_recent_messages_with_tool_pairs, messages, 2)
      
      expect(recent.size).to eq(2)
      expect(recent[0][:tool_calls].first[:id]).to eq("call_4")
      expect(recent[1][:tool_call_id]).to eq("call_4")
    end

    it "handles edge case with single tool call" do
      messages = [
        { role: "system", content: "System" },
        { role: "user", content: "Simple request" },
        {
          role: "assistant",
          tool_calls: [
            { id: "call_1", type: "function", function: { name: "calculator", arguments: "{}" } }
          ]
        },
        { role: "tool", tool_call_id: "call_1", content: "42" },
        { role: "assistant", content: "The answer is 42" }
      ]

      recent = agent.send(:get_recent_messages_with_tool_pairs, messages, 2)

      # Should include: assistant with tool_calls, tool result, and final assistant
      expect(recent.size).to eq(3)
      expect(recent[0][:role]).to eq("assistant")
      expect(recent[0][:tool_calls].first[:id]).to eq("call_1")
      expect(recent[1][:role]).to eq("tool")
      expect(recent[1][:tool_call_id]).to eq("call_1")
      expect(recent[2][:role]).to eq("assistant")
      expect(recent[2][:content]).to eq("The answer is 42")
    end

    it "returns empty array for empty messages" do
      recent = agent.send(:get_recent_messages_with_tool_pairs, [], 5)
      expect(recent).to eq([])
    end

    it "returns all messages when count exceeds message count" do
      messages = [
        { role: "system", content: "System" },
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi" }
      ]

      recent = agent.send(:get_recent_messages_with_tool_pairs, messages, 100)
      expect(recent.size).to eq(3)
    end
  end

  describe "message compression" do
    let(:compression_config) do
      Clacky::AgentConfig.new(
        model: "gpt-3.5-turbo",
        permission_mode: :auto_approve,
        enable_compression: true,
        keep_recent_messages: 5
      )
    end
    let(:compression_agent) { described_class.new(client, compression_config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id) }

    before do
      # Mock send_messages for LLM compression
      allow(client).to receive(:send_messages) do |messages, **_options|
        # Return a compressed summary as JSON array
        mock_api_response(content: '[{"role":"user","content":"Compressed history summary"}]')
      end
    end

    it "compresses messages when threshold is exceeded" do
      # Add messages with enough content to exceed 80K token threshold
      # Each message needs ~1600 chars to reach ~400 tokens (4 chars/token)
      # 200 messages × 400 tokens = 80K tokens
      messages = compression_agent.instance_variable_get(:@messages)
      messages << { role: "system", content: "System prompt" }

      200.times do |i|
        # Create longer messages to reach token threshold
        long_content = "This is a detailed message number #{i}. " * 100
        messages << { role: "user", content: long_content }
        messages << { role: "assistant", content: "Response #{i}: " + "Detailed response " * 100 }
      end

      initial_count = messages.size
      initial_tokens = compression_agent.send(:total_message_tokens)[:total]

      # Verify we have enough tokens to trigger compression
      expect(initial_tokens).to be >= 80_000

      # Mock LLM response: first call is compression, returns compressed summary
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "<summary>Compressed history of all previous conversations</summary>"))

      # Call think which will trigger and handle compression automatically
      compression_agent.send(:think)

      final_count = compression_agent.instance_variable_get(:@messages).size
      final_tokens = compression_agent.send(:total_message_tokens)[:total]

      expect(final_count).to be < initial_count
      expect(final_tokens).to be < initial_tokens
      # Should target around 70K tokens
      expect(final_tokens).to be <= 75_000
    end

    it "preserves system message during compression" do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "done"))

      messages = compression_agent.instance_variable_get(:@messages)
      messages << { role: "system", content: "Important system prompt" }

      # Add enough content to exceed token threshold
      100.times do |i|
        long_content = "Detailed conversation message #{i}. " * 80
        messages << { role: "user", content: long_content }
        messages << { role: "assistant", content: "Response #{i}: " + "Detailed answer " * 80 }
      end

      compression_agent.send(:compress_messages_if_needed)
      compressed_messages = compression_agent.instance_variable_get(:@messages)

      system_msg = compressed_messages.find { |m| m[:role] == "system" }
      expect(system_msg).not_to be_nil
      expect(system_msg[:content]).to eq("Important system prompt")
    end

    it "can be disabled via config" do
      no_compression_config = Clacky::AgentConfig.new(
        permission_mode: :auto_approve,
        enable_compression: false,
        keep_recent_messages: 5
      )
      no_compression_agent = described_class.new(client, no_compression_config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id)

      messages = no_compression_agent.instance_variable_get(:@messages)

      # Add many messages (enough to normally trigger compression)
      100.times do |i|
        long_content = "Detailed message #{i}. " * 80
        messages << { role: "user", content: long_content }
        messages << { role: "assistant", content: "Response #{i}: " + "Answer " * 80 }
      end

      initial_count = messages.size
      no_compression_agent.send(:compress_messages_if_needed)
      final_count = no_compression_agent.instance_variable_get(:@messages).size

      expect(final_count).to eq(initial_count) # No compression when disabled
    end

    it "preserves all tool results when assistant has multiple tool_calls" do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "done"))

      messages = compression_agent.instance_variable_get(:@messages)
      messages << { role: "system", content: "System" }

      # Add many messages to trigger compression (need token threshold)
      100.times do |i|
        long_content = "Request message #{i}. " * 80
        messages << { role: "user", content: long_content }
        messages << { role: "assistant", content: "Response #{i}: " + "Answer " * 80 }
      end

      # Add a critical scenario: assistant with MULTIPLE tool_calls
      messages << { role: "user", content: "Do two things" }
      messages << {
        role: "assistant",
        content: nil,
        tool_calls: [
          { id: "call_1", type: "function", function: { name: "tool_a", arguments: "{}" } },
          { id: "call_2", type: "function", function: { name: "tool_b", arguments: "{}" } }
        ]
      }
      # Add the two corresponding tool results
      messages << { role: "tool", tool_call_id: "call_1", content: "Result A" }
      messages << { role: "tool", tool_call_id: "call_2", content: "Result B" }

      # Add a final message to be preserved
      messages << { role: "user", content: "Final request" }

      compression_agent.send(:compress_messages_if_needed)
      compressed = compression_agent.instance_variable_get(:@messages)

      # Find the assistant message with multiple tool_calls
      assistant_msg = compressed.find do |m|
        m[:role] == "assistant" && m[:tool_calls]&.size == 2
      end

      if assistant_msg
        # If the assistant message is preserved, ALL its tool results must be preserved
        tool_call_ids = assistant_msg[:tool_calls].map { |tc| tc[:id] }
        tool_results = compressed.select { |m| m[:role] == "tool" && tool_call_ids.include?(m[:tool_call_id]) }

        expect(tool_results.size).to eq(2),
          "Expected 2 tool results for assistant with 2 tool_calls, but found #{tool_results.size}"
        expect(tool_results.map { |m| m[:tool_call_id] }.sort).to eq(["call_1", "call_2"].sort)
      end
    end

    it "triggers compression when message count exceeds threshold even if tokens are below threshold" do
      messages = compression_agent.instance_variable_get(:@messages)
      messages << { role: "system", content: "System prompt" }

      # Add exactly 100 short messages (token count will be well below 80K threshold)
      # System + 100 user + 100 assistant = 201 messages
      100.times do |i|
        # Short content to keep token count low
        short_content = "Short message #{i}"
        messages << { role: "user", content: short_content }
        messages << { role: "assistant", content: "Response #{i}" }
      end

      initial_count = messages.size
      initial_tokens = compression_agent.send(:total_message_tokens)[:total]

      # Verify token count is below token threshold but message count exceeds 100
      expect(initial_tokens).to be < 80_000
      expect(initial_count).to be >= 201

      # Mock LLM response: first call is compression, returns compressed summary
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "<summary>Compressed history of short messages</summary>"))

      # Call think which will trigger and handle compression automatically
      compression_agent.send(:think)

      final_count = compression_agent.instance_variable_get(:@messages).size
      final_tokens = compression_agent.send(:total_message_tokens)[:total]

      # Compression should have been triggered by message count threshold
      expect(final_count).to be < initial_count
      expect(final_tokens).to be < initial_tokens
    end
  end

  describe ".from_session" do
    let(:session_data) do
      {
        session_id: "test-session-123",
        created_at: "2024-01-01T00:00:00Z",
        working_dir: "/test/dir",
        messages: [
          { role: "system", content: "System prompt" },
          { role: "user", content: "First request" },
          { role: "assistant", content: "First response" }
        ],
        todos: [
          { id: 1, task: "Test task", status: "pending" }
        ],
        stats: {
          total_iterations: 5,
          total_cost_usd: 0.10,
          total_tasks: 2,
          last_status: "success"
        }
      }
    end

    it "restores session state correctly" do
      restored_agent = described_class.from_session(client, config, session_data, profile: "coding")

      expect(restored_agent.session_id).to eq("test-session-123")
      expect(restored_agent.iterations).to eq(5)
      expect(restored_agent.total_cost).to eq(0.10)
      expect(restored_agent.messages.size).to eq(3)
      expect(restored_agent.todos.size).to eq(1)
      expect(restored_agent.working_dir).to eq("/test/dir")
    end

    context "when session ended with error" do
      let(:error_session_data) do
        session_data.merge(
          messages: session_data[:messages] + [
            { role: "user", content: "This caused an error" }
          ],
          stats: session_data[:stats].merge(
            last_status: "error",
            last_error: "Something went wrong"
          )
        )
      end

      it "rolls back the last user message" do
        restored_agent = described_class.from_session(client, config, error_session_data, profile: "coding")

        # Should have rolled back the error-causing message
        expect(restored_agent.messages.size).to eq(3) # system + user + assistant, not the error-causing user message
        expect(restored_agent.messages.last[:content]).to eq("First response")
      end

      it "triggers session_rollback hook" do
        hook_data = nil
        
        # Create a new agent to add the hook
        agent_with_hook = described_class.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id)
        agent_with_hook.add_hook(:session_rollback) do |data|
          hook_data = data
        end

        # Manually restore session to trigger the hook
        agent_with_hook.restore_session(error_session_data)

        expect(hook_data).not_to be_nil
        expect(hook_data[:reason]).to eq("Previous session ended with error")
        expect(hook_data[:error_message]).to eq("Something went wrong")
        expect(hook_data[:rolled_back_message_index]).to eq(3)
      end
    end
  end

  describe "truncated response handling" do
    let(:truncated_response) do
      mock_api_response(
        content: "",
        tool_calls: [
          mock_tool_call(name: "write", args: '{"path": "test.md"}')  # Missing content parameter
        ],
        finish_reason: "length"  # Indicates truncation
      )
    end

    let(:retry_response) do
      mock_api_response(
        content: "Let me create the file in smaller steps",
        tool_calls: [
          mock_tool_call(name: "write", args: '{"path": "test.md", "content": "# Title"}')
        ],
        finish_reason: "stop"
      )
    end

    it "detects truncated responses and retries automatically" do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(truncated_response, retry_response)

      agent.run("Create a document")

      # Should have added a system message about truncation
      system_messages = agent.messages.select { |m| 
        m[:role] == "user" && m[:content]&.include?("[SYSTEM] Your response was truncated")
      }
      expect(system_messages.size).to eq(1)

      # Should have retried and gotten a valid response
      expect(client).to have_received(:send_messages_with_tools).twice
    end

    it "gives up after multiple truncations" do
      # Always return truncated responses
      allow(client).to receive(:send_messages_with_tools)
        .and_return(truncated_response)

      result = agent.run("Create a very complex document")

      # Should have given up and returned a helpful message
      expect(result[:status]).to eq(:success)
      
      # Find the assistant message that gave up
      assistant_messages = agent.messages.select { |m| 
        m[:role] == "assistant" && m[:content]&.include?("too complex")
      }
      expect(assistant_messages.size).to be >= 1
      expect(assistant_messages.last[:content]).to include("break it down into smaller steps")
    end
  end

  describe "#inject_todo_reminder" do
    let(:todo_tool) { instance_double(Clacky::Tools::TodoManager) }
    
    before do
      allow(agent.instance_variable_get(:@tool_registry)).to receive(:get)
        .with("todo_manager").and_return(todo_tool)
    end

    context "when there are pending TODOs" do
      before do
        allow(todo_tool).to receive(:execute).with(action: "list", todos_storage: anything).and_return({
          todos: [
            { id: 1, task: "Task 1", status: "pending" },
            { id: 2, task: "Task 2", status: "completed" },
            { id: 3, task: "Task 3", status: "pending" }
          ]
        })
      end

      it "injects reminder into string result" do
        result = agent.send(:inject_todo_reminder, "safe_shell", "Command executed successfully")
        
        expect(result).to include("Command executed successfully")
        expect(result).to include("📋 REMINDER")
        expect(result).to include("2 pending TODO(s)")
      end

      it "injects reminder into hash result" do
        result = agent.send(:inject_todo_reminder, "file_reader", { content: "file content" })
        
        expect(result[:content]).to eq("file content")
        expect(result[:_todo_reminder]).to include("📋 REMINDER")
        expect(result[:_todo_reminder]).to include("2 pending TODO(s)")
      end

      it "injects reminder into array result" do
        result = agent.send(:inject_todo_reminder, "glob", ["file1.rb", "file2.rb"])
        
        expect(result[0..1]).to eq(["file1.rb", "file2.rb"])
        expect(result.last).to be_a(Hash)
        expect(result.last[:_todo_reminder]).to include("📋 REMINDER")
      end
    end

    context "when there are no pending TODOs" do
      before do
        allow(todo_tool).to receive(:execute).with(action: "list", todos_storage: anything).and_return({
          todos: [
            { id: 1, task: "Task 1", status: "completed" },
            { id: 2, task: "Task 2", status: "completed" }
          ]
        })
      end

      it "does not inject reminder" do
        result = agent.send(:inject_todo_reminder, "safe_shell", "Command executed successfully")
        
        expect(result).to eq("Command executed successfully")
        expect(result).not_to include("📋 REMINDER")
      end
    end

    context "when tool is todo_manager" do
      before do
        allow(todo_tool).to receive(:execute).with(action: "list", todos_storage: anything).and_return({
          todos: [{ id: 1, task: "Task 1", status: "pending" }]
        })
      end

      it "skips injection to avoid redundancy" do
        result = agent.send(:inject_todo_reminder, "todo_manager", { message: "TODO added" })
        
        expect(result).to eq({ message: "TODO added" })
        expect(result[:_todo_reminder]).to be_nil
      end
    end

    context "when todo_manager is not available" do
      before do
        allow(agent.instance_variable_get(:@tool_registry)).to receive(:get)
          .with("todo_manager").and_return(nil)
      end

      it "returns result without modification" do
        result = agent.send(:inject_todo_reminder, "safe_shell", "Command executed successfully")
        
        expect(result).to eq("Command executed successfully")
      end
    end

    context "when todo_tool execution fails" do
      before do
        allow(todo_tool).to receive(:execute).and_raise(StandardError.new("Tool error"))
      end

      it "returns result without modification" do
        result = agent.send(:inject_todo_reminder, "safe_shell", "Command executed successfully")
        
        expect(result).to eq("Command executed successfully")
      end
    end
  end
end
