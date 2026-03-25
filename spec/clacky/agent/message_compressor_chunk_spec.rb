# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "time"

RSpec.describe "Compression chunk MD archiving" do
  let(:sessions_dir) { Dir.mktmpdir }
  let(:session_id) { "abc12345-0000-0000-0000-000000000000" }
  let(:created_at) { "2026-03-08T10:00:00+08:00" }

  # Minimal agent class that includes MessageCompressorHelper
  let(:agent_class) do
    Class.new do
      include Clacky::Agent::MessageCompressorHelper

      attr_accessor :messages, :session_id, :created_at, :compressed_summaries, :compression_level

      def initialize(sessions_dir)
        @sessions_dir_override = sessions_dir
        @messages = []
        @session_id = nil
        @created_at = nil
        @compressed_summaries = []
        @compression_level = 0
      end

      def ui
        nil
      end

      def config
        double("config", enable_compression: true)
      end
    end
  end

  before do
    stub_const("Clacky::SessionManager::SESSIONS_DIR", sessions_dir)
  end

  after do
    FileUtils.rm_rf(sessions_dir)
  end

  subject(:agent) do
    obj = agent_class.new(sessions_dir)
    obj.session_id = session_id
    obj.created_at = created_at
    obj
  end

  let(:user_msg)      { { role: "user", content: "Tell me about compression" } }
  let(:assistant_msg) { { role: "assistant", content: "Compression reduces token usage." } }
  let(:system_msg)    { { role: "system", content: "You are a helpful assistant." } }
  let(:recent_msg)    { { role: "user", content: "And what about memory?" } }

  describe "#save_compressed_chunk" do
    it "creates a chunk MD file in the sessions directory" do
      original_messages = [system_msg, user_msg, assistant_msg, recent_msg]
      recent_messages = [recent_msg]

      path = agent.send(:save_compressed_chunk, original_messages, recent_messages,
                        chunk_index: 1, compression_level: 1)

      expect(path).not_to be_nil
      expect(File.exist?(path)).to be true
    end

    it "names the file with the correct pattern: datetime-shortid-chunk-n.md" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      filename = File.basename(path)
      expect(filename).to match(/\A2026-03-08-10-00-00-abc12345-chunk-1\.md\z/)
    end

    it "increments chunk index for sequential compressions" do
      original_messages = [system_msg, user_msg, assistant_msg]

      path1 = agent.send(:save_compressed_chunk, original_messages, [], chunk_index: 1, compression_level: 1)
      path2 = agent.send(:save_compressed_chunk, original_messages, [], chunk_index: 2, compression_level: 2)

      expect(File.basename(path1)).to include("chunk-1")
      expect(File.basename(path2)).to include("chunk-2")
    end

    it "excludes system messages from the chunk content" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).not_to include("You are a helpful assistant")
    end

    it "excludes recent messages from the chunk content" do
      original_messages = [system_msg, user_msg, assistant_msg, recent_msg]
      recent_messages = [recent_msg]

      path = agent.send(:save_compressed_chunk, original_messages, recent_messages,
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).not_to include("And what about memory?")
      expect(content).to include("Tell me about compression")
    end

    it "includes user and assistant messages in readable MD format" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).to include("## User")
      expect(content).to include("## Assistant")
      expect(content).to include("Tell me about compression")
      expect(content).to include("Compression reduces token usage.")
    end

    it "includes front matter with session metadata" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).to include("session_id: #{session_id}")
      expect(content).to include("chunk: 1")
      expect(content).to include("compression_level: 1")
    end

    it "returns nil if session_id is not set" do
      agent.session_id = nil
      original_messages = [user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)
      expect(path).to be_nil
    end

    it "returns nil if there are no messages to archive (only system + recent)" do
      original_messages = [system_msg, recent_msg]
      recent_messages = [recent_msg]
      path = agent.send(:save_compressed_chunk, original_messages, recent_messages,
                        chunk_index: 1, compression_level: 1)
      expect(path).to be_nil
    end
  end

  describe "SessionManager cleanup" do
    let(:manager) { Clacky::SessionManager.new(sessions_dir: sessions_dir) }

    # Build a minimal valid session data hash
    def session_data(session_id:, created_at:, updated_at:)
      {
        session_id: session_id,
        created_at: created_at,
        updated_at: updated_at,
        working_dir: "/tmp",
        messages: [],
        todos: [],
        time_machine: { task_parents: {}, current_task_id: 0, active_task_id: 0 },
        config: { models: {}, permission_mode: "auto_approve", enable_compression: true,
                  enable_prompt_caching: false, max_tokens: 8192, verbose: false },
        stats: { total_iterations: 0, total_cost_usd: 0.0, total_tasks: 0,
                 last_status: "ok", previous_total_tokens: 0,
                 cache_stats: {}, debug_logs: [] }
      }
    end

    # Write a chunk MD file using the same naming convention as the real code
    def write_chunk(manager, session_id, created_at, chunk_index)
      datetime = Time.parse(created_at).strftime("%Y-%m-%d-%H-%M-%S")
      short_id = session_id[0..7]
      base = "#{datetime}-#{short_id}"
      chunk_path = File.join(sessions_dir, "#{base}-chunk-#{chunk_index}.md")
      File.write(chunk_path, "# Chunk #{chunk_index}\n\nSome archived content.")
      chunk_path
    end

    it "deletes associated chunk MD files when cleanup_by_count removes a session" do
      old_id = "old-sess-0000-0000-0000-000000000001"
      new_id = "new-sess-0000-0000-0000-000000000002"
      old_created = "2026-01-01T00:00:00+08:00"
      new_created = "2026-03-08T10:00:00+08:00"

      # Save sessions via manager so filenames are consistent
      manager.save(session_data(session_id: old_id, created_at: old_created, updated_at: old_created))
      chunk_path = write_chunk(manager, old_id, old_created, 1)
      manager.save(session_data(session_id: new_id, created_at: new_created, updated_at: new_created))

      # Keep only 1 session — old one should be deleted with its chunk
      # (save already called cleanup_by_count(keep:10), so call explicitly with keep:1)
      manager.cleanup_by_count(keep: 1)

      expect(File.exist?(chunk_path)).to be false
    end

    it "deletes multiple chunk files for a deleted session" do
      old_id = "old-sess-0000-0000-0000-000000000001"
      new_id = "new-sess-0000-0000-0000-000000000002"
      old_created = "2026-01-01T00:00:00+08:00"
      new_created = "2026-03-08T10:00:00+08:00"

      manager.save(session_data(session_id: old_id, created_at: old_created, updated_at: old_created))
      chunk1 = write_chunk(manager, old_id, old_created, 1)
      chunk2 = write_chunk(manager, old_id, old_created, 2)
      manager.save(session_data(session_id: new_id, created_at: new_created, updated_at: new_created))

      manager.cleanup_by_count(keep: 1)

      expect(File.exist?(chunk1)).to be false
      expect(File.exist?(chunk2)).to be false
    end
  end

  describe Clacky::MessageCompressor do
    describe "#rebuild_with_compression" do
      let(:compressor) { described_class.new(nil) }
      let(:system_msg) { { role: "system", content: "System prompt" } }
      let(:recent_msg) { { role: "user", content: "Recent message" } }

      it "injects chunk anchor into compressed summary when chunk_path is provided" do
        chunk_path = "/home/user/.clacky/sessions/2026-03-08-10-00-00-abc12345-chunk-1.md"
        original_messages = [system_msg]

        result = compressor.rebuild_with_compression(
          "<summary>Conversation summary here</summary>",
          original_messages: original_messages,
          recent_messages: [recent_msg],
          chunk_path: chunk_path
        )

        summary_msg = result.find { |m| m[:role] == "assistant" }
        expect(summary_msg[:content]).to include(chunk_path)
        expect(summary_msg[:content]).to include("file_reader")
        expect(summary_msg[:chunk_path]).to eq(chunk_path)
      end

      it "does not inject anchor when chunk_path is nil" do
        original_messages = [system_msg]

        result = compressor.rebuild_with_compression(
          "<summary>Conversation summary here</summary>",
          original_messages: original_messages,
          recent_messages: [recent_msg],
          chunk_path: nil
        )

        summary_msg = result.find { |m| m[:role] == "assistant" }
        expect(summary_msg[:content]).not_to include("file_reader")
        expect(summary_msg[:chunk_path]).to be_nil
      end
    end
  end
end
