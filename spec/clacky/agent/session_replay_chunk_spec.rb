# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "time"

RSpec.describe "replay_history chunk MD expansion" do
  let(:sessions_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(sessions_dir) }

  # Minimal agent stub that includes SessionSerializer
  def build_agent(messages)
    history = Clacky::MessageHistory.new(messages)

    # Build a real class instance so @history instance variable works correctly
    agent_class = Class.new do
      include Clacky::Agent::SessionSerializer

      def initialize(history)
        @history = history
        @skill_loader = Object.new.tap do |sl|
          sl.define_singleton_method(:load_all) {}
        end
      end

      def build_system_prompt; "system"; end
    end

    agent_class.new(history)
  end

  # Collector that captures events (mirrors HistoryCollector interface)
  class TestCollector
    attr_reader :events

    def initialize
      @events = []
    end

    def show_user_message(content, created_at: nil, files: [])
      @events << { type: :user, content: content, created_at: created_at }
    end

    def show_assistant_message(content, files:)
      @events << { type: :assistant, content: content }
    end

    def show_tool_call(name, args)
      @events << { type: :tool_call, name: name }
    end

    def show_tool_result(result)
      @events << { type: :tool_result, result: result }
    end

    def show_token_usage(*); end
    def method_missing(*); end
    def respond_to_missing?(*); true; end
  end

  # Build a minimal chunk MD string
  def chunk_md(user_content:, assistant_content:, archived_at: "2026-03-01T10:00:00+08:00", chunk: 1)
    <<~MD
      ---
      session_id: aabbccdd
      chunk: #{chunk}
      compression_level: 1
      archived_at: #{archived_at}
      message_count: 2
      ---

      # Session Chunk #{chunk}

      > This file contains the original conversation archived during compression.

      ## User

      #{user_content}

      ## Assistant

      #{assistant_content}
    MD
  end

  describe "parse_chunk_md_to_rounds" do
    it "parses a simple chunk MD into rounds" do
      path = File.join(sessions_dir, "chunk-1.md")
      File.write(path, chunk_md(user_content: "Hello from chunk", assistant_content: "Hi there"))

      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, path)

      expect(rounds.size).to eq(1)
      expect(rounds.first[:user_msg][:content]).to include("Hello from chunk")
      expect(rounds.first[:events].first[:content]).to include("Hi there")
      expect(rounds.first[:events].first[:role]).to eq("assistant")
    end

    it "assigns synthetic created_at timestamps based on archived_at" do
      archived_at = "2026-03-01T10:00:00+08:00"
      path = File.join(sessions_dir, "chunk-1.md")
      File.write(path, chunk_md(user_content: "Q1", assistant_content: "A1", archived_at: archived_at))

      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, path)

      expect(rounds.first[:user_msg][:created_at]).to be_a(Float)
      expect(rounds.first[:user_msg][:created_at]).to be < Time.parse(archived_at).to_f
    end

    it "returns empty array for missing file" do
      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, "/nonexistent/chunk.md")
      expect(rounds).to eq([])
    end

    it "returns empty array for nil path" do
      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, nil)
      expect(rounds).to eq([])
    end

    it "marks rounds with _from_chunk: true" do
      path = File.join(sessions_dir, "chunk-1.md")
      File.write(path, chunk_md(user_content: "Hi", assistant_content: "Hey"))

      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, path)

      expect(rounds.first[:user_msg][:_from_chunk]).to be true
    end

    it "parses multiple user turns" do
      md = <<~MD
        ---
        session_id: aabbccdd
        chunk: 1
        archived_at: 2026-03-01T10:00:00+08:00
        message_count: 4
        ---

        ## User

        First question

        ## Assistant

        First answer

        ## User

        Second question

        ## Assistant

        Second answer
      MD
      path = File.join(sessions_dir, "chunk-1.md")
      File.write(path, md)

      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, path)

      expect(rounds.size).to eq(2)
      expect(rounds[0][:user_msg][:content]).to include("First question")
      expect(rounds[1][:user_msg][:content]).to include("Second question")
    end

    it "handles tool results inside chunks (old format: name only)" do
      md = <<~MD
        ---
        session_id: aabbccdd
        chunk: 1
        archived_at: 2026-03-01T10:00:00+08:00
        message_count: 3
        ---

        ## User

        Run a command

        ## Assistant

        _Tool calls: safe_shell_

        ### Tool Result: safe_shell

        ```
        output here
        ```

        ## Assistant

        Done.
      MD
      path = File.join(sessions_dir, "chunk-1.md")
      File.write(path, md)

      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, path)

      expect(rounds.size).to eq(1)
      roles = rounds.first[:events].map { |e| e[:role] }
      expect(roles).to include("assistant", "tool")
      # Old format: args should be empty hash
      tc_event = rounds.first[:events].find { |e| e[:tool_calls] }
      expect(tc_event[:tool_calls].first[:arguments]).to eq({})
    end

    it "handles tool calls with args (new format: name | {json})" do
      md = <<~MD
        ---
        session_id: aabbccdd
        chunk: 1
        archived_at: 2026-03-01T10:00:00+08:00
        message_count: 2
        ---

        ## User

        List files

        ## Assistant

        _Tool calls: safe_shell | {"command":"ls -la"}_

        ### Tool Result: safe_shell

        ```
        total 8
        drwxr-xr-x  2 user user 4096 Jan  1 00:00 .
        ```

        ## Assistant

        Done.
      MD
      path = File.join(sessions_dir, "chunk-args.md")
      File.write(path, md)

      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, path)

      tc_event = rounds.first[:events].find { |e| e[:tool_calls] }
      expect(tc_event).not_to be_nil
      expect(tc_event[:tool_calls].first[:name]).to eq("safe_shell")
      expect(tc_event[:tool_calls].first[:arguments]).to eq({ "command" => "ls -la" })
    end

    it "handles multiple tool calls in one assistant turn (new format with ;)" do
      md = <<~MD
        ---
        session_id: aabbccdd
        chunk: 1
        archived_at: 2026-03-01T10:00:00+08:00
        message_count: 2
        ---

        ## User

        Do two things

        ## Assistant

        _Tool calls: safe_shell | {"command":"echo hi"}; edit | {"path":"a.rb","old_string":"x","new_string":"y"}_

        ## Assistant

        Done.
      MD
      path = File.join(sessions_dir, "chunk-multi.md")
      File.write(path, md)

      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, path)

      tc_events = rounds.first[:events].select { |e| e[:tool_calls] }
      expect(tc_events.size).to eq(2)
      names = tc_events.map { |e| e[:tool_calls].first[:name] }
      expect(names).to contain_exactly("safe_shell", "edit")
      expect(tc_events.first[:tool_calls].first[:arguments]).to eq({ "command" => "echo hi" })
    end

    it "recursively expands nested chunk references" do
      # chunk-1: original content
      chunk1_path = File.join(sessions_dir, "2026-03-01-10-00-00-aabbccdd-chunk-1.md")
      File.write(chunk1_path, chunk_md(
        user_content: "Original question",
        assistant_content: "Original answer",
        archived_at: "2026-03-01T09:00:00+08:00",
        chunk: 1
      ))

      # chunk-2: references chunk-1 via Compressed Summary heading
      chunk2_md = <<~MD
        ---
        session_id: aabbccdd
        chunk: 2
        archived_at: 2026-03-01T10:00:00+08:00
        message_count: 3
        ---

        ## Assistant [Compressed Summary — original conversation at: 2026-03-01-10-00-00-aabbccdd-chunk-1.md]

        Summary of earlier conversation.

        ## User

        Later question

        ## Assistant

        Later answer
      MD
      chunk2_path = File.join(sessions_dir, "2026-03-01-10-00-00-aabbccdd-chunk-2.md")
      File.write(chunk2_path, chunk2_md)

      agent = build_agent([])
      rounds = agent.send(:parse_chunk_md_to_rounds, chunk2_path)

      # Should include rounds from chunk-1 AND rounds from chunk-2
      all_user_texts = rounds.map { |r| r[:user_msg][:content] }
      expect(all_user_texts).to include(a_string_including("Original question"))
      expect(all_user_texts).to include(a_string_including("Later question"))
    end
  end

  describe "replay_history with compressed sessions" do
    it "expands chunk rounds when history contains only a compressed summary" do
      chunk_path = File.join(sessions_dir, "chunk-1.md")
      File.write(chunk_path, chunk_md(
        user_content: "Compressed question",
        assistant_content: "Compressed answer"
      ))

      messages = [
        { role: "system", content: "You are helpful." },
        { role: "assistant", content: "Summary...", compressed_summary: true, chunk_path: chunk_path },
        { role: "user", content: "Current question", created_at: Time.now.to_f }
      ]

      agent = build_agent(messages)
      collector = TestCollector.new
      result = agent.replay_history(collector)

      user_events = collector.events.select { |e| e[:type] == :user }
      contents = user_events.map { |e| e[:content] }

      expect(contents).to include(a_string_including("Compressed question"))
      expect(contents).to include(a_string_including("Current question"))
      expect(result[:has_more]).to be false
    end

    it "respects before cursor for chunk rounds" do
      base_time = Time.now.to_f

      chunk_path = File.join(sessions_dir, "chunk-1.md")
      File.write(chunk_path, chunk_md(
        user_content: "Old question",
        assistant_content: "Old answer",
        archived_at: Time.at(base_time - 1000).iso8601
      ))

      messages = [
        { role: "system", content: "System." },
        { role: "assistant", content: "Summary.", compressed_summary: true, chunk_path: chunk_path },
        { role: "user", content: "New question", created_at: base_time }
      ]

      agent = build_agent(messages)
      collector = TestCollector.new
      # before = just before "New question" — should only show old chunk rounds
      agent.replay_history(collector, before: base_time - 0.5)

      user_events = collector.events.select { |e| e[:type] == :user }
      expect(user_events.map { |e| e[:content] }).to include(a_string_including("Old question"))
      expect(user_events.map { |e| e[:content] }).not_to include(a_string_including("New question"))
    end

    it "returns has_more: true when chunk rounds exceed limit" do
      chunk_path = File.join(sessions_dir, "chunk-1.md")

      # Build a chunk with many user turns
      lines = ["---", "session_id: aabb", "chunk: 1", "archived_at: 2026-01-01T00:00:00+08:00", "message_count: 40", "---", ""]
      25.times do |i|
        lines << "## User\n\nQuestion #{i}\n\n## Assistant\n\nAnswer #{i}\n"
      end
      File.write(chunk_path, lines.join("\n"))

      messages = [
        { role: "system", content: "System." },
        { role: "assistant", content: "Summary.", compressed_summary: true, chunk_path: chunk_path },
        { role: "user", content: "Latest question", created_at: Time.now.to_f }
      ]

      agent = build_agent(messages)
      collector = TestCollector.new
      result = agent.replay_history(collector, limit: 10)

      expect(result[:has_more]).to be true
    end

    it "shows assistant messages from chunk rounds" do
      chunk_path = File.join(sessions_dir, "chunk-1.md")
      File.write(chunk_path, chunk_md(
        user_content: "What is Ruby?",
        assistant_content: "Ruby is a programming language."
      ))

      messages = [
        { role: "system", content: "System." },
        { role: "assistant", content: "Summary.", compressed_summary: true, chunk_path: chunk_path }
      ]

      agent = build_agent(messages)
      collector = TestCollector.new
      agent.replay_history(collector)

      assistant_events = collector.events.select { |e| e[:type] == :assistant }
      expect(assistant_events.map { |e| e[:content] }).to include(a_string_including("Ruby is a programming language"))
    end

    it "handles missing chunk file gracefully" do
      messages = [
        { role: "system", content: "System." },
        { role: "assistant", content: "Summary.", compressed_summary: true, chunk_path: "/nonexistent/chunk.md" },
        { role: "user", content: "Still here", created_at: Time.now.to_f }
      ]

      agent = build_agent(messages)
      collector = TestCollector.new

      expect { agent.replay_history(collector) }.not_to raise_error

      user_events = collector.events.select { |e| e[:type] == :user }
      expect(user_events.map { |e| e[:content] }).to include(a_string_including("Still here"))
    end

    # Regression: when chunk has more rounds than limit, session.json new messages
    # must still appear — they must NOT be squeezed out by rounds.last(limit).
    it "always shows session.json new messages even when chunk rounds exceed limit" do
      chunk_path = File.join(sessions_dir, "chunk-big.md")

      # Build a chunk with 35 user turns (exceeds default limit=30)
      lines = ["---", "session_id: aabb", "chunk: 1",
               "archived_at: 2026-01-01T00:00:00+08:00", "message_count: 70", "---", ""]
      35.times do |i|
        lines << "## User\n\nChunk question #{i}\n\n## Assistant\n\nChunk answer #{i}\n"
      end
      File.write(chunk_path, lines.join("\n"))

      # session.json has 3 new messages after compression
      base_time = Time.parse("2026-03-01T10:00:00+08:00").to_f
      messages = [
        { role: "system", content: "System." },
        { role: "assistant", content: "Summary.", compressed_summary: true, chunk_path: chunk_path },
        { role: "user",      content: "Session new msg 1", created_at: base_time },
        { role: "assistant", content: "Reply 1" },
        { role: "user",      content: "Session new msg 2", created_at: base_time + 10 },
        { role: "assistant", content: "Reply 2" },
        { role: "user",      content: "Session new msg 3", created_at: base_time + 20 },
        { role: "assistant", content: "Reply 3" }
      ]

      agent = build_agent(messages)
      collector = TestCollector.new
      agent.replay_history(collector, limit: 30)

      user_contents = collector.events.select { |e| e[:type] == :user }.map { |e| e[:content] }

      # All 3 session.json messages MUST be present
      expect(user_contents).to include(a_string_including("Session new msg 1"))
      expect(user_contents).to include(a_string_including("Session new msg 2"))
      expect(user_contents).to include(a_string_including("Session new msg 3"))
    end

    # Regression: after compression, recent_messages may contain only assistant/tool messages
    # with no real user message (e.g. tool_result blocks in role:user). In that case
    # session_rounds = [] and the fallback path fires — but it must still render those
    # recent messages, NOT silently drop them.
    it "shows recent assistant/tool messages even when no real user message survived in session.json after compression" do
      chunk_path = File.join(sessions_dir, "chunk-no-user.md")
      File.write(chunk_path, chunk_md(
        user_content: "Earlier question",
        assistant_content: "Earlier answer"
      ))

      # After compression, recent_messages kept only: assistant reply + tool_result (role:user)
      # No real user text message survived in session.json.
      messages = [
        { role: "system",    content: "System." },
        # compressed summary referencing chunk
        { role: "assistant", content: "Summary.", compressed_summary: true, chunk_path: chunk_path },
        # recent_messages: assistant + tool_result only (no real user text message)
        { role: "assistant", content: "Here is my plan.", tool_calls: [{ name: "safe_shell", arguments: { command: "ls" } }] },
        { role: "user",      content: [{ type: "tool_result", tool_use_id: "t1", content: "file1.rb\nfile2.rb" }] },
        { role: "assistant", content: "Done." }
      ]

      agent = build_agent(messages)
      collector = TestCollector.new
      agent.replay_history(collector)

      assistant_contents = collector.events.select { |e| e[:type] == :assistant }.map { |e| e[:content] }

      # The recent assistant messages must appear, not be silently dropped
      expect(assistant_contents).to include(a_string_including("Done."))
    end

    # Regression: after compression, session.json has real user messages BUT they come
    # AFTER a sequence of tool/assistant messages that have no preceding user message
    # (because the leading user message was in the compressed chunk). Those orphaned
    # assistant/tool messages must still be rendered.
    it "shows orphaned assistant/tool messages that precede the first session.json user message" do
      chunk_path = File.join(sessions_dir, "chunk-orphan.md")
      File.write(chunk_path, chunk_md(
        user_content: "Old task",
        assistant_content: "Old result"
      ))

      base_time = Time.parse("2026-03-01T10:00:00+08:00").to_f

      # After compression the recent_messages slice started mid-task:
      # assistant + tool_result came before the next real user message.
      messages = [
        { role: "system",    content: "System." },
        { role: "assistant", content: "Summary.", compressed_summary: true, chunk_path: chunk_path },
        # orphaned: these belong to the round whose user msg was compressed into the chunk
        { role: "assistant", content: "Working on it...", tool_calls: [{ name: "write", arguments: { path: "a.rb" } }] },
        { role: "tool",      content: "Written." },
        { role: "assistant", content: "All done." },
        # then a new real user message
        { role: "user",      content: "Next task", created_at: base_time },
        { role: "assistant", content: "Starting next task." }
      ]

      agent = build_agent(messages)
      collector = TestCollector.new
      agent.replay_history(collector)

      all_contents = collector.events.map { |e| e[:content] || e[:name] }

      # Both the orphaned assistant messages AND the new user round must appear
      expect(all_contents).to include(a_string_including("All done."))
      expect(collector.events.select { |e| e[:type] == :user }.map { |e| e[:content] })
        .to include(a_string_including("Next task"))
    end
  end
end
