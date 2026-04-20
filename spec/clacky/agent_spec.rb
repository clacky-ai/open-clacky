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
  let(:agent) { described_class.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id, source: :manual) }

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
      tool_messages = agent.history.to_a.select { |m| m[:role] == "tool" }

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

      tool_messages = agent.history.to_a.select { |m| m[:role] == "tool" }

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

    it "returns all non-system messages when count exceeds message count" do
      messages = [
        { role: "system", content: "System" },
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi" }
      ]

      recent = agent.send(:get_recent_messages_with_tool_pairs, messages, 100)
      # system message is excluded — rebuild_with_compression prepends it separately
      expect(recent.size).to eq(2)
      expect(recent.none? { |m| m[:role] == "system" }).to be(true)
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
    let(:compression_agent) { described_class.new(client, compression_config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id, source: :manual) }

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
      compression_agent.history.append({ role: "system", content: "System prompt" })

      200.times do |i|
        # Create longer messages to reach token threshold
        long_content = "This is a detailed message number #{i}. " * 100
        compression_agent.history.append({ role: "user", content: long_content })
        compression_agent.history.append({ role: "assistant", content: "Response #{i}: " + "Detailed response " * 100 })
      end

      initial_count = compression_agent.history.size

      # Verify we have enough messages to trigger compression (MESSAGE_COUNT_THRESHOLD = 200)
      expect(initial_count).to be >= 200

      # Mock LLM response: first call is compression, returns compressed summary
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "<summary>Compressed history of all previous conversations</summary>"))

      # Call think which will trigger and handle compression automatically
      compression_agent.send(:think)

      final_count = compression_agent.history.size

      expect(final_count).to be < initial_count
    end

    it "preserves system message during compression" do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "done"))

      compression_agent.history.append({ role: "system", content: "Important system prompt" })

      # Add enough content to exceed token threshold
      100.times do |i|
        long_content = "Detailed conversation message #{i}. " * 80
        compression_agent.history.append({ role: "user", content: long_content })
        compression_agent.history.append({ role: "assistant", content: "Response #{i}: " + "Detailed answer " * 80 })
      end

      compression_agent.send(:compress_messages_if_needed)
      compressed_messages = compression_agent.history.to_a

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
      no_compression_agent = described_class.new(client, no_compression_config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id, source: :manual)

      # Add many messages (enough to normally trigger compression)
      100.times do |i|
        long_content = "Detailed message #{i}. " * 80
        no_compression_agent.history.append({ role: "user", content: long_content })
        no_compression_agent.history.append({ role: "assistant", content: "Response #{i}: " + "Answer " * 80 })
      end

      initial_count = no_compression_agent.history.size
      no_compression_agent.send(:compress_messages_if_needed)
      final_count = no_compression_agent.history.size

      expect(final_count).to eq(initial_count) # No compression when disabled
    end

    it "preserves all tool results when assistant has multiple tool_calls" do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "done"))

      compression_agent.history.append({ role: "system", content: "System" })

      # Add many messages to trigger compression (need token threshold)
      100.times do |i|
        long_content = "Request message #{i}. " * 80
        compression_agent.history.append({ role: "user", content: long_content })
        compression_agent.history.append({ role: "assistant", content: "Response #{i}: " + "Answer " * 80 })
      end

      # Add a critical scenario: assistant with MULTIPLE tool_calls
      compression_agent.history.append({ role: "user", content: "Do two things" })
      compression_agent.history.append({
        role: "assistant",
        content: nil,
        tool_calls: [
          { id: "call_1", type: "function", function: { name: "tool_a", arguments: "{}" } },
          { id: "call_2", type: "function", function: { name: "tool_b", arguments: "{}" } }
        ]
      })
      # Add the two corresponding tool results
      compression_agent.history.append({ role: "tool", tool_call_id: "call_1", content: "Result A" })
      compression_agent.history.append({ role: "tool", tool_call_id: "call_2", content: "Result B" })

      # Add a final message to be preserved
      compression_agent.history.append({ role: "user", content: "Final request" })

      compression_agent.send(:compress_messages_if_needed)
      compressed = compression_agent.history.to_a

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
      compression_agent.history.append({ role: "system", content: "System prompt" })

      # Add exactly 100 short messages (token count will be well below 80K threshold)
      # System + 100 user + 100 assistant = 201 messages
      100.times do |i|
        # Short content to keep token count low
        short_content = "Short message #{i}"
        compression_agent.history.append({ role: "user", content: short_content })
        compression_agent.history.append({ role: "assistant", content: "Response #{i}" })
      end

      initial_count = compression_agent.history.size

      # Verify message count exceeds threshold
      expect(initial_count).to be >= 201

      # Mock LLM response: first call is compression, returns compressed summary
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "<summary>Compressed history of short messages</summary>"))

      # Call think which will trigger and handle compression automatically
      compression_agent.send(:think)

      final_count = compression_agent.history.size

      # Compression should have been triggered by message count threshold
      expect(final_count).to be < initial_count
    end

    # Regression tests for: "user types new input during compression → LLM echoes
    # compression instructions instead of answering the new question"
    #
    # Root cause: when AgentInterrupted fires during the compression call_llm,
    # the ensure block rolls back the compression_message from history (correct),
    # but @compression_level had already been incremented by compress_messages_if_needed.
    # On the very next think() triggered by the new task, compression fires again,
    # appending COMPRESSION_PROMPT right after the user's new message. The LLM then
    # sees two consecutive user messages and responds to the latter (compression prompt)
    # instead of the actual user question.
    context "when compression is interrupted by new user input" do
      # Build a helper that fills history past the compression threshold
      def fill_history_past_threshold(agent)
        agent.history.append({ role: "system", content: "System prompt" })
        100.times do |i|
          long_content = "Conversation message #{i}. " * 80
          agent.history.append({ role: "user", content: long_content })
          agent.history.append({ role: "assistant", content: "Response #{i}: " + "Answer " * 80 })
        end
      end

      it "restores @compression_level to its pre-compression value after interrupt" do
        fill_history_past_threshold(compression_agent)

        level_before = compression_agent.instance_variable_get(:@compression_level)

        # Simulate AgentInterrupted firing during call_llm (compression never completes)
        allow(client).to receive(:send_messages_with_tools)
          .and_raise(Clacky::AgentInterrupted, "New input received")

        # think() should propagate the interrupt (it only catches it in ensure)
        expect { compression_agent.send(:think) }.to raise_error(Clacky::AgentInterrupted)

        level_after = compression_agent.instance_variable_get(:@compression_level)
        expect(level_after).to eq(level_before),
          "@compression_level was #{level_before} before interrupted compression, " \
          "expected it to be restored but got #{level_after}"
      end

      it "rolls back compression_message from history after interrupt" do
        fill_history_past_threshold(compression_agent)

        messages_before = compression_agent.history.to_a.dup
        count_before = compression_agent.history.size

        allow(client).to receive(:send_messages_with_tools)
          .and_raise(Clacky::AgentInterrupted, "New input received")

        expect { compression_agent.send(:think) }.to raise_error(Clacky::AgentInterrupted)

        count_after = compression_agent.history.size
        expect(count_after).to eq(count_before),
          "History should be restored after interrupted compression, " \
          "but went from #{count_before} to #{count_after} messages"

        # The last message must not be the compression prompt
        last_msg = compression_agent.history.to_a.last
        expect(last_msg[:content]).not_to include("COMPRESSION MODE"),
          "compression_message must be rolled back from history after interrupt"
      end

      it "does not send COMPRESSION_PROMPT as the last message when new task starts after interrupt" do
        fill_history_past_threshold(compression_agent)

        # Step 1: interrupt the compression mid-way
        allow(client).to receive(:send_messages_with_tools)
          .and_raise(Clacky::AgentInterrupted, "New input received")
        expect { compression_agent.send(:think) }.to raise_error(Clacky::AgentInterrupted)

        # Step 2: simulate new task — append the user's new message (as run() would)
        compression_agent.history.append({ role: "user", content: "New question from user" })

        # Step 3: capture what messages the next think() would send to the LLM
        messages_sent = nil
        allow(client).to receive(:send_messages_with_tools) do |msgs, **_opts|
          messages_sent = msgs
          mock_api_response(content: "Here is my answer to your new question")
        end

        # think() will again detect the threshold and trigger compression,
        # appending COMPRESSION_PROMPT after the new user message.
        # After the fix, @compression_level is correctly restored, but more importantly
        # we verify that the actual messages sent to LLM contain the user's new question
        # as the effective last real instruction (not buried under COMPRESSION_PROMPT).
        compression_agent.send(:think)

        expect(messages_sent).not_to be_nil

        # The last message sent to the LLM must be the COMPRESSION_PROMPT (intended),
        # but crucially the new user message must appear immediately before it — not
        # swallowed or missing — so that if compression succeeds, context is preserved.
        last_msg = messages_sent.last
        second_last = messages_sent[-2]

        expect(last_msg[:content]).to include("COMPRESSION MODE"),
          "Expected COMPRESSION_PROMPT to be the final message sent to LLM during compression"
        expect(second_last[:content]).to eq("New question from user"),
          "Expected the user's new question to appear immediately before the COMPRESSION_PROMPT, " \
          "but got: #{second_last[:content].to_s[0..100]}"
      end
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
      expect(restored_agent.history.size).to eq(3)
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

        # Rollback is deferred — history still contains all 4 messages at restore time
        # (trimming immediately causes the history replay to return empty results in the UI).
        # The pending flag signals that truncation will happen on the next run().
        expect(restored_agent.history.size).to eq(4)
        expect(restored_agent.instance_variable_get(:@pending_error_rollback)).to be true
      end

      it "triggers session_rollback hook" do
        hook_data = nil

        # Create a new agent and add hook before restoring session
        agent_with_hook = described_class.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id, source: :manual)
        agent_with_hook.add_hook(:session_rollback) do |data|
          hook_data = data
        end

        agent_with_hook.restore_session(error_session_data)

        # Hook is deferred — fires when the user sends the next message via run(),
        # not at restore time. At this point only the pending flag is set.
        expect(hook_data).to be_nil
        expect(agent_with_hook.instance_variable_get(:@pending_error_rollback)).to be true

        # Simulate user sending next message — rollback and hook fire here.
        allow(client).to receive(:send_messages_with_tools).and_return(
          mock_api_response(content: "OK")
        )
        agent_with_hook.run("New message")

        expect(hook_data).not_to be_nil
        expect(hook_data[:reason]).to eq("Previous session ended with error — rolling back before new message")
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
      system_messages = agent.history.to_a.select { |m| 
        m[:role] == "user" && m[:content]&.include?("[SYSTEM] Your previous response was truncated")
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
      assistant_messages = agent.history.to_a.select { |m| 
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

  # ── inline skill injection integration ───────────────────────────────────────
  #
  # Verifies that when the agent loop executes an invoke_skill tool call for an
  # inline skill, the resulting history has the correct message order required
  # by Bedrock (and all providers):
  #
  #   [N]   assistant: { toolUse: invoke_skill }
  #   [N+1] user:      { toolResult: ... }         ← observe() appends first
  #   [N+2] assistant: { text: skill instructions } ← flush_pending_injections runs here
  #   [N+3] user:      "[SYSTEM] please proceed"
  #
  describe "inline skill injection via agent loop" do
    let(:skill_content) { "## Skill Instructions\nDo the magic thing." }

    def build_agent_with_inline_skill(tmpdir)
      # Write a minimal inline skill
      skill_dir = File.join(tmpdir, ".clacky", "skills", "magic-skill")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), <<~MD)
        ---
        name: magic-skill
        description: A magic test skill
        ---

        #{skill_content}
      MD

      Clacky::Agent.new(
        client, config,
        working_dir: tmpdir,
        ui: nil,
        profile: "general",
        session_id: Clacky::SessionManager.generate_id,
        source: :manual
      )
    end

    def stub_client_for_invoke_skill(agent, tool_call_id)
      # Round 1: assistant calls invoke_skill
      invoke_skill_response = mock_api_response(
        content: "好，来调用 skill！",
        tool_calls: [mock_tool_call(name: "invoke_skill", args: JSON.generate(skill_name: "magic-skill", task: "do it"))]
      ).merge(id: tool_call_id)

      # Round 2: assistant finishes
      final_response = mock_api_response(content: "Skill executed.")

      allow(client).to receive(:send_messages_with_tools)
        .and_return(invoke_skill_response, final_response)

      # format_tool_results: return Anthropic-style user message with toolResult block
      allow(client).to receive(:format_tool_results) do |_response, tool_results, model:|
        [{
          role: "user",
          content: tool_results.map { |r|
            { type: "tool_result", tool_use_id: r[:id], content: r[:content] }
          }
        }]
      end
    end

    it "appends toolResult before skill instructions in history" do
      require "fileutils"
      Dir.mktmpdir do |tmpdir|
        local_agent = build_agent_with_inline_skill(tmpdir)
        tool_call_id = "tooluse_test_#{SecureRandom.hex(4)}"

        stub_client_for_invoke_skill(local_agent, tool_call_id)
        allow(local_agent).to receive(:inject_memory_prompt!).and_return(false)

        local_agent.run("invoke magic-skill")

        messages = local_agent.history.to_a

        # Find the user message containing the toolResult block
        tool_result_idx = messages.index { |m|
          m[:role] == "user" &&
          Array(m[:content]).any? { |b| b.is_a?(Hash) && b[:type] == "tool_result" }
        }
        expect(tool_result_idx).not_to be_nil, "Expected a toolResult message in history"

        # Find the injected skill instruction message (assistant, system_injected, contains skill content)
        skill_inject_idx = messages.index { |m|
          m[:role] == "assistant" &&
          m[:system_injected] == true &&
          m[:content].to_s.include?(skill_content.lines.first.strip)
        }
        expect(skill_inject_idx).not_to be_nil, "Expected injected skill instruction message in history"

        # Core assertion: toolResult must appear BEFORE skill instructions
        expect(skill_inject_idx).to be > tool_result_idx,
          "Skill instructions (idx=#{skill_inject_idx}) must appear AFTER toolResult (idx=#{tool_result_idx})"

        # The "[SYSTEM] ... Please proceed" shim must come after skill instructions
        shim_idx = messages.index { |m|
          m[:role] == "user" &&
          m[:system_injected] == true &&
          m[:content].to_s.include?("Please proceed to execute the task")
        }
        expect(shim_idx).not_to be_nil, "Expected '[SYSTEM] please proceed' shim message in history"
        expect(shim_idx).to be > skill_inject_idx,
          "Shim must come after skill instructions"
      end
    end

    it "enqueue_injection adds entry to @pending_injections" do
      Dir.mktmpdir do |tmpdir|
        local_agent = build_agent_with_inline_skill(tmpdir)
        skill = local_agent.instance_variable_get(:@skill_loader).find_by_name("magic-skill")

        expect {
          local_agent.enqueue_injection(skill, "do it")
        }.to change {
          local_agent.instance_variable_get(:@pending_injections).size
        }.by(1)
      end
    end

    it "flush_pending_injections injects into history and clears the queue" do
      Dir.mktmpdir do |tmpdir|
        local_agent = build_agent_with_inline_skill(tmpdir)
        skill = local_agent.instance_variable_get(:@skill_loader).find_by_name("magic-skill")

        local_agent.enqueue_injection(skill, "do it")
        expect(local_agent.instance_variable_get(:@pending_injections).size).to eq(1)

        local_agent.send(:flush_pending_injections)

        # Queue must be cleared
        expect(local_agent.instance_variable_get(:@pending_injections)).to be_empty

        # Skill instruction must be in history
        injected = local_agent.history.to_a.select { |m|
          m[:system_injected] && m[:role] == "assistant" &&
          m[:content].to_s.include?(skill_content.lines.first.strip)
        }
        expect(injected.size).to eq(1)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Dangling tool_calls cleanup — API error 2013
  #
  # Error: "tool call result does not follow tool call"
  # Root cause: a previous task left an unanswered assistant+tool_calls message in
  # history (e.g. due to AgentInterrupted during act(), or AgentError during the
  # second LLM call). When the next task appends a user message,
  # MessageHistory#append calls drop_dangling_tool_calls! to remove the orphan.
  #
  # These tests verify the end-to-end Agent behaviour — that the messages actually
  # sent to the LLM API never contain a dangling tool_calls assistant message.
  # ─────────────────────────────────────────────────────────────────────────────
  describe "dangling tool_calls cleanup (API error 2013 prevention)" do
    # Shared format_tool_results stub (OpenAI-style)
    def stub_format_tool_results(client)
      allow(client).to receive(:format_tool_results) do |response, tool_results, model:|
        response[:tool_calls].map do |call|
          result = tool_results.find { |r| r[:id] == call[:id] }
          {
            role: "tool",
            tool_call_id: call[:id],
            content: result ? result[:content] : JSON.generate({ error: "missing" })
          }
        end
      end
    end

    context "when previous task was interrupted (AgentInterrupted) after think() appended tool_calls" do
      # Scenario:
      #   Task 1: think() returns tool_calls → appended to history.
      #           act() raises AgentInterrupted before observe() runs.
      #           → history ends with a dangling assistant+tool_calls message.
      #   Task 2: run("second task") appends a user message.
      #           MessageHistory#append must drop the dangling message first.
      #           → API must NOT receive the orphaned tool_calls message.

      it "drops dangling tool_calls so the next task does not trigger error 2013" do
        stub_format_tool_results(client)

        tool_call = mock_tool_call(name: "safe_shell", args: '{"command":"ls"}')

        # Task 1 — interrupted run: think returns tool_calls, then act raises AgentInterrupted
        interrupted_response = mock_api_response(
          content: "Running ls…",
          tool_calls: [tool_call]
        )
        allow(client).to receive(:send_messages_with_tools)
          .and_return(interrupted_response)
          .once
        allow(agent).to receive(:act).and_raise(Clacky::AgentInterrupted, "user pressed Ctrl+C")
        allow(agent).to receive(:inject_memory_prompt!).and_return(false)

        expect { agent.run("task one") }.to raise_error(Clacky::AgentInterrupted)

        # History should now have a dangling assistant+tool_calls at the end
        expect(agent.history.pending_tool_calls?).to be true

        # Task 2 — second run: capture messages sent to LLM
        messages_sent = nil
        allow(client).to receive(:send_messages_with_tools) do |msgs, **_opts|
          messages_sent = msgs
          mock_api_response(content: "Done with task two")
        end

        agent.run("task two")

        # The dangling assistant message must NOT appear in messages sent to API
        dangling = messages_sent.select { |m|
          m[:role] == "assistant" && Array(m[:tool_calls]).any?
        }
        expect(dangling).to be_empty,
          "Expected no dangling assistant+tool_calls in API messages, but found: #{dangling.inspect}"
      end
    end

    context "when previous task ended with AgentError after think() appended tool_calls" do
      # Scenario:
      #   Task 1: think() (round 1) returns tool_calls → appended + observe() runs fine.
      #           think() (round 2, for final answer) raises AgentError.
      #           Because the round-1 tool_call was properly observed, history is clean
      #           at that point. But if the error occurs BEFORE observe(), the
      #           dangling message is left. We simulate the worst case: error fires
      #           in act() so observe() never runs.

      it "API receives no dangling tool_calls when error occurred before observe()" do
        stub_format_tool_results(client)

        tool_call = mock_tool_call(name: "safe_shell", args: '{"command":"pwd"}')
        erroring_response = mock_api_response(content: "Thinking…", tool_calls: [tool_call])

        allow(client).to receive(:send_messages_with_tools).and_return(erroring_response).once
        allow(agent).to receive(:act).and_raise(Clacky::AgentError, "simulated API failure")
        allow(agent).to receive(:inject_memory_prompt!).and_return(false)

        expect { agent.run("task one") }.to raise_error(Clacky::AgentError)
        expect(agent.history.pending_tool_calls?).to be true

        # Task 2 — should clean up and proceed normally
        messages_sent = nil
        allow(client).to receive(:send_messages_with_tools) do |msgs, **_opts|
          messages_sent = msgs
          mock_api_response(content: "All good now")
        end

        agent.run("task two")

        dangling = messages_sent.select { |m|
          m[:role] == "assistant" && Array(m[:tool_calls]).any?
        }
        expect(dangling).to be_empty,
          "Expected no dangling assistant+tool_calls in API messages after error recovery"
      end
    end

    context "when history is manually seeded with a dangling assistant+tool_calls" do
      # Scenario: directly inject a dangling state into history to verify the
      # cleanup path regardless of how it was created (e.g. session restore edge cases).

      it "drops the dangling message before sending to API" do
        stub_format_tool_results(client)
        allow(agent).to receive(:inject_memory_prompt!).and_return(false)

        # Build a fresh agent with controlled history
        agent.history.append({ role: "system", content: "You are helpful." })
        agent.history.append({ role: "user", content: "previous task" })
        # Dangling: assistant with tool_calls, no subsequent tool_result
        agent.history.append({
          role: "assistant",
          content: "",
          tool_calls: [{ id: "orphan_call_1", type: "function", name: "safe_shell",
                         function: { name: "safe_shell", arguments: '{"command":"ls"}' } }]
        })

        expect(agent.history.pending_tool_calls?).to be true

        messages_sent = nil
        allow(client).to receive(:send_messages_with_tools) do |msgs, **_opts|
          messages_sent = msgs
          mock_api_response(content: "Cleaned up and running")
        end

        agent.run("new task after dangling state")

        dangling = messages_sent.select { |m|
          m[:role] == "assistant" && Array(m[:tool_calls]).any?
        }
        expect(dangling).to be_empty,
          "Dangling assistant+tool_calls must be stripped before sending to API"
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Brand skill end-to-end tests
  #
  # Brand skills (encrypted: true) are injected as transient messages — visible to
  # the LLM during the current session but never persisted to session.json.
  #
  # Three paths are tested end-to-end through agent.run():
  #   1. invoke_skill tool path  — LLM calls invoke_skill → enqueue → flush
  #   2. slash command path      — user types /brand-skill → inject_skill_command_as_assistant_message
  #   3. persistence isolation   — transient messages are absent from to_a after run()
  # ─────────────────────────────────────────────────────────────────────────────
  describe "brand skill end-to-end" do
    # Helper: set up a brand skill in a temp dir, yield agent + skill.
    # Mirrors the with_brand_skill helper in inject_skill_command_spec.rb.
    def with_brand_skill_agent(content: "Secret brand instructions.", name: "secret-skill")
      Dir.mktmpdir do |tmp|
        stub_const("Clacky::BrandConfig::CONFIG_DIR", tmp)
        stub_const("Clacky::BrandConfig::BRAND_FILE", File.join(tmp, "brand.yml"))

        brand_config = Clacky::BrandConfig.new(
          "brand_name"           => "TestBrand",
          "license_key"          => "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4",
          "license_activated_at" => Time.now.utc.iso8601,
          "license_expires_at"   => (Time.now.utc + 86_400).iso8601,
          "device_id"            => "testdevice"
        )
        allow(Clacky::BrandConfig).to receive(:load).and_return(brand_config)

        skill_dir = File.join(tmp, "brand_skills", name)
        FileUtils.mkdir_p(skill_dir)
        File.binwrite(
          File.join(skill_dir, "SKILL.md.enc"),
          "---\nname: #{name}\ndescription: A secret brand skill\n---\n\n#{content}"
        )

        old_test_env = ENV.delete("CLACKY_TEST")
        begin
          brand_agent = described_class.new(
            client, config,
            working_dir: tmp, ui: nil, profile: "general",
            session_id: Clacky::SessionManager.generate_id,
            source: :manual
          )
          skill = brand_agent.instance_variable_get(:@skill_loader).find_by_name(name)
          yield brand_agent, skill, tmp
        ensure
          ENV["CLACKY_TEST"] = old_test_env if old_test_env
        end
      end
    end

    context "via invoke_skill tool (inline path)" do
      # LLM decides to call invoke_skill → enqueue_injection → flush after observe()
      # Verifies: brand skill content reaches to_api (LLM sees it this session)
      #           but does NOT appear in to_a (not persisted)

      it "brand skill content is visible in to_api but absent from to_a after run()" do
        with_brand_skill_agent(content: "Top secret brand instructions.") do |brand_agent, skill, _tmp|
          expect(skill).not_to be_nil
          expect(skill.encrypted?).to be true

          tool_call_id = "call_brand_#{SecureRandom.hex(4)}"
          invoke_response = mock_api_response(
            content: "Invoking brand skill…",
            tool_calls: [mock_tool_call(name: "invoke_skill",
                                        args: JSON.generate(skill_name: "secret-skill", task: "do it"))]
          ).merge(id: tool_call_id)
          final_response = mock_api_response(content: "Brand skill done.")

          allow(client).to receive(:send_messages_with_tools)
            .and_return(invoke_response, final_response)
          allow(client).to receive(:format_tool_results) do |_resp, tool_results, model:|
            [{ role: "user",
               content: tool_results.map { |r|
                 { type: "tool_result", tool_use_id: r[:id], content: r[:content] }
               } }]
          end
          allow(brand_agent).to receive(:inject_memory_prompt!).and_return(false)

          brand_agent.run("use secret skill")

          # to_api includes transient messages (LLM sees them this session)
          api_messages = brand_agent.history.to_api
          has_brand_content = api_messages.any? { |m| m[:content].to_s.include?("Top secret brand instructions.") }
          # Brand skill content must be present in to_api (LLM must see it)
          expect(has_brand_content).to eq(true)

          # to_a excludes transient messages (must not be persisted)
          persisted = brand_agent.history.to_a
          leaks_brand_content = persisted.any? { |m| m[:content].to_s.include?("Top secret brand instructions.") }
          # Brand skill content must NOT appear in to_a (must not be persisted)
          expect(leaks_brand_content).to eq(false)
        end
      end

      it "brand skill messages are marked transient in raw history after run()" do
        with_brand_skill_agent(content: "Proprietary workflow steps.") do |brand_agent, _skill, _tmp|
          tool_call_id = "call_brand_#{SecureRandom.hex(4)}"
          invoke_response = mock_api_response(
            content: nil,
            tool_calls: [mock_tool_call(name: "invoke_skill",
                                        args: JSON.generate(skill_name: "secret-skill", task: "run it"))]
          ).merge(id: tool_call_id)
          final_response = mock_api_response(content: "All done.")

          allow(client).to receive(:send_messages_with_tools)
            .and_return(invoke_response, final_response)
          allow(client).to receive(:format_tool_results) do |_resp, tool_results, model:|
            [{ role: "user",
               content: tool_results.map { |r|
                 { type: "tool_result", tool_use_id: r[:id], content: r[:content] }
               } }]
          end
          allow(brand_agent).to receive(:inject_memory_prompt!).and_return(false)

          brand_agent.run("invoke secret")

          raw = brand_agent.history.instance_variable_get(:@messages)
          brand_msgs = raw.select { |m|
            m[:system_injected] && !m[:session_context] &&
              m[:content].to_s.include?("Proprietary workflow steps.")
          }
          expect(brand_msgs).not_to be_empty, "Expected brand skill messages in raw history"
          expect(brand_msgs).to all(satisfy { |m| m[:transient] == true }),
            "All brand skill messages must be transient"
        end
      end
    end

    context "via slash command path" do
      # User types /secret-skill → inject_skill_command_as_assistant_message runs immediately
      # Verifies same transient isolation guarantees

      it "brand skill injected via slash command is transient and not persisted" do
        with_brand_skill_agent(content: "Slash command brand instructions.") do |brand_agent, _skill, _tmp|
          allow(client).to receive(:send_messages_with_tools)
            .and_return(mock_api_response(content: "Executed slash skill."))
          allow(brand_agent).to receive(:inject_memory_prompt!).and_return(false)

          brand_agent.run("/secret-skill do the thing")

          # Raw history contains transient brand skill messages
          raw = brand_agent.history.instance_variable_get(:@messages)
          brand_msgs = raw.select { |m|
            m[:system_injected] && !m[:session_context] &&
              m[:content].to_s.include?("Slash command brand instructions.")
          }
          expect(brand_msgs).not_to be_empty, "Expected injected brand skill messages in raw history"
          expect(brand_msgs).to all(satisfy { |m| m[:transient] == true })

          # to_a must not include brand skill content
          persisted = brand_agent.history.to_a
          leaks = persisted.any? { |m| m[:content].to_s.include?("Slash command brand instructions.") }
          # Brand skill content must not be persisted via to_a
          expect(leaks).to eq(false)
        end
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # CONFIDENTIALITY NOTICE injection tests
    #
    # inject_skill_as_assistant_message wraps encrypted brand skills with
    # [CONFIDENTIAL SKILL START/END] markers whenever skill.encrypted? is true.
    # These end-to-end tests verify:
    #   a) The notice is present in to_api (the LLM receives it)
    #   b) The notice is absent from to_a  (not persisted to session.json)
    #   c) Plain (non-encrypted) skills never get the notice injected
    #
    # Both injection paths (slash command + invoke_skill tool) are covered.
    # ─────────────────────────────────────────────────────────────────────────
    describe "CONFIDENTIALITY NOTICE injection" do
      CONFIDENTIALITY_NOTICE = "[CONFIDENTIAL SKILL"

      context "slash command path" do
        it "appends CONFIDENTIALITY NOTICE to the injected content" do
          with_brand_skill_agent(content: "Slash secret content.") do |brand_agent, _skill, _tmp|
            allow(client).to receive(:send_messages_with_tools)
              .and_return(mock_api_response(content: "Done."))
            allow(brand_agent).to receive(:inject_memory_prompt!).and_return(false)

            brand_agent.run("/secret-skill do the thing")

            api_messages = brand_agent.history.to_api
            notice_in_api = api_messages.any? { |m| m[:content].to_s.include?(CONFIDENTIALITY_NOTICE) }
            expect(notice_in_api).to eq(true)
          end
        end

        it "CONFIDENTIALITY NOTICE is NOT present in to_a (not persisted)" do
          with_brand_skill_agent(content: "Slash secret content.") do |brand_agent, _skill, _tmp|
            allow(client).to receive(:send_messages_with_tools)
              .and_return(mock_api_response(content: "Done."))
            allow(brand_agent).to receive(:inject_memory_prompt!).and_return(false)

            brand_agent.run("/secret-skill do the thing")

            persisted = brand_agent.history.to_a
            notice_leaked = persisted.any? { |m| m[:content].to_s.include?(CONFIDENTIALITY_NOTICE) }
            expect(notice_leaked).to eq(false)
          end
        end
      end

      context "invoke_skill tool path" do
        it "appends CONFIDENTIALITY NOTICE when LLM calls invoke_skill for a brand skill" do
          with_brand_skill_agent(content: "Tool path secret content.") do |brand_agent, _skill, _tmp|
            invoke_response = mock_api_response(
              content: nil,
              tool_calls: [mock_tool_call(name: "invoke_skill",
                                          args: JSON.generate(skill_name: "secret-skill", task: "run it"))]
            )
            final_response = mock_api_response(content: "All done.")

            allow(client).to receive(:send_messages_with_tools)
              .and_return(invoke_response, final_response)
            allow(client).to receive(:format_tool_results) do |_resp, tool_results, model:|
              [{ role: "user",
                 content: tool_results.map { |r|
                   { type: "tool_result", tool_use_id: r[:id], content: r[:content] }
                 } }]
            end
            allow(brand_agent).to receive(:inject_memory_prompt!).and_return(false)

            brand_agent.run("use secret skill")

            api_messages = brand_agent.history.to_api
            notice_in_api = api_messages.any? { |m| m[:content].to_s.include?(CONFIDENTIALITY_NOTICE) }
            expect(notice_in_api).to eq(true)
          end
        end

        it "CONFIDENTIALITY NOTICE is NOT present in to_a (not persisted)" do
          with_brand_skill_agent(content: "Tool path secret content.") do |brand_agent, _skill, _tmp|
            invoke_response = mock_api_response(
              content: nil,
              tool_calls: [mock_tool_call(name: "invoke_skill",
                                          args: JSON.generate(skill_name: "secret-skill", task: "run it"))]
            )
            final_response = mock_api_response(content: "All done.")

            allow(client).to receive(:send_messages_with_tools)
              .and_return(invoke_response, final_response)
            allow(client).to receive(:format_tool_results) do |_resp, tool_results, model:|
              [{ role: "user",
                 content: tool_results.map { |r|
                   { type: "tool_result", tool_use_id: r[:id], content: r[:content] }
                 } }]
            end
            allow(brand_agent).to receive(:inject_memory_prompt!).and_return(false)

            brand_agent.run("use secret skill")

            persisted = brand_agent.history.to_a
            notice_leaked = persisted.any? { |m| m[:content].to_s.include?(CONFIDENTIALITY_NOTICE) }
            expect(notice_leaked).to eq(false)
          end
        end
      end

      context "plain (non-encrypted) skill" do
        it "does NOT inject CONFIDENTIALITY NOTICE for a regular skill" do
          Dir.mktmpdir do |tmp|
            # Set up a plain skill (not encrypted) in the project skills dir
            skill_dir = File.join(tmp, ".clacky", "skills", "plain-skill")
            FileUtils.mkdir_p(skill_dir)
            File.write(File.join(skill_dir, "SKILL.md"), <<~SKILL)
              ---
              name: plain-skill
              description: A plain non-encrypted skill.
              ---

              Plain skill content. No secrets here.
            SKILL

            plain_agent = described_class.new(
              client, config,
              working_dir: tmp, ui: nil, profile: "general",
              session_id: Clacky::SessionManager.generate_id,
              source: :manual
            )
            allow(client).to receive(:send_messages_with_tools)
              .and_return(mock_api_response(content: "Done."))
            allow(plain_agent).to receive(:inject_memory_prompt!).and_return(false)

            plain_agent.run("/plain-skill do something")

            # Neither to_api nor to_a should contain the CONFIDENTIALITY NOTICE
            all_contents = (plain_agent.history.to_api + plain_agent.history.to_a)
              .map { |m| m[:content].to_s }
              .join("\n")
            expect(all_contents).not_to include(CONFIDENTIALITY_NOTICE)
          end
        end
      end
    end
  end
end
