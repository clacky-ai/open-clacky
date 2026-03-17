# frozen_string_literal: true

RSpec.describe Clacky::MessageHistory do
  subject(:history) { described_class.new }

  # Helper: build a basic message
  def user_msg(content = "hello", **opts)
    { role: "user", content: content, task_id: 1, created_at: Time.now.to_f }.merge(opts)
  end

  def assistant_msg(content = "hi", **opts)
    { role: "assistant", content: content, task_id: 1, created_at: Time.now.to_f }.merge(opts)
  end

  def assistant_with_tool_calls(tool_name = "bash", **opts)
    { role: "assistant", content: nil, tool_calls: [{ id: "tc_1", name: tool_name, arguments: "{}" }],
      task_id: 1, created_at: Time.now.to_f }.merge(opts)
  end

  def tool_result_msg(tool_call_id = "tc_1", **opts)
    { role: "tool", tool_results: [{ tool_use_id: tool_call_id, content: "result" }],
      task_id: 1, created_at: Time.now.to_f }.merge(opts)
  end

  def system_msg(content = "You are helpful.", **opts)
    { role: "system", content: content }.merge(opts)
  end

  # ─────────────────────────────────────────────
  # append
  # ─────────────────────────────────────────────
  describe "#append" do
    it "adds a message to the history" do
      history.append(user_msg)
      expect(history.size).to eq(1)
    end

    it "preserves all fields including internal ones" do
      msg = user_msg("test", system_injected: true, task_id: 42)
      history.append(msg)
      expect(history.to_a.first).to include(system_injected: true, task_id: 42)
    end

    context "when appending a user message after a dangling assistant+tool_calls" do
      it "drops the dangling assistant message automatically" do
        history.append(user_msg)
        history.append(assistant_with_tool_calls)
        # no tool_result — next user message should clean this up
        history.append(user_msg("follow-up"))
        expect(history.size).to eq(2)
        expect(history.to_a.last[:content]).to eq("follow-up")
        expect(history.to_api.none? { |m| m[:tool_calls] }).to be true
      end

      it "does not drop assistant+tool_calls when tool_result is present" do
        history.append(user_msg)
        history.append(assistant_with_tool_calls)
        history.append(tool_result_msg)
        history.append(user_msg("next"))
        expect(history.size).to eq(4)
      end
    end
  end

  # ─────────────────────────────────────────────
  # replace_system_prompt
  # ─────────────────────────────────────────────
  describe "#replace_system_prompt" do
    it "replaces existing system message in place" do
      history.append(system_msg("old"))
      history.append(user_msg)
      history.replace_system_prompt("new system")
      expect(history.to_a.first[:content]).to eq("new system")
      expect(history.size).to eq(2)
    end

    it "prepends system message if none exists" do
      history.append(user_msg)
      history.replace_system_prompt("new system")
      expect(history.to_a.first[:role]).to eq("system")
      expect(history.size).to eq(2)
    end
  end

  # ─────────────────────────────────────────────
  # replace_all
  # ─────────────────────────────────────────────
  describe "#replace_all" do
    it "replaces the entire message list (used by compression rebuild)" do
      history.append(user_msg)
      new_messages = [user_msg("compressed"), assistant_msg("summary")]
      history.replace_all(new_messages)
      expect(history.size).to eq(2)
      expect(history.to_a.first[:content]).to eq("compressed")
    end
  end

  # ─────────────────────────────────────────────
  # pop_last
  # ─────────────────────────────────────────────
  describe "#pop_last" do
    it "removes and returns the last message" do
      history.append(user_msg("a"))
      history.append(user_msg("b"))
      popped = history.pop_last
      expect(popped[:content]).to eq("b")
      expect(history.size).to eq(1)
    end
  end

  # ─────────────────────────────────────────────
  # pop_while
  # ─────────────────────────────────────────────
  describe "#pop_while" do
    it "removes messages from the end while condition is true" do
      history.append(user_msg("keep"))
      history.append(assistant_msg("remove1"))
      history.append(assistant_msg("remove2"))
      history.pop_while { |m| m[:role] == "assistant" }
      expect(history.size).to eq(1)
      expect(history.to_a.last[:content]).to eq("keep")
    end
  end

  # ─────────────────────────────────────────────
  # delete_where
  # ─────────────────────────────────────────────
  describe "#delete_where" do
    it "removes all messages matching the block (used by memory cleanup)" do
      history.append(user_msg("normal"))
      history.append(user_msg("memory", memory_update: true))
      history.append(assistant_msg)
      history.delete_where { |m| m[:memory_update] }
      expect(history.size).to eq(2)
      expect(history.to_a.none? { |m| m[:memory_update] }).to be true
    end
  end

  # ─────────────────────────────────────────────
  # mutate_last_matching
  # ─────────────────────────────────────────────
  describe "#mutate_last_matching" do
    it "mutates the last message matching criteria in-place" do
      history.append(user_msg)
      history.append(assistant_msg("original", subagent_instructions: true))
      history.mutate_last_matching(->(m) { m[:subagent_instructions] }) do |m|
        m[:content] = "updated"
        m.delete(:subagent_instructions)
      end
      last = history.to_a.last
      expect(last[:content]).to eq("updated")
      expect(last[:subagent_instructions]).to be_nil
    end
  end

  # ─────────────────────────────────────────────
  # pending_tool_calls?
  # ─────────────────────────────────────────────
  describe "#pending_tool_calls?" do
    it "returns true when last message is assistant with tool_calls and no tool_result follows" do
      history.append(user_msg)
      history.append(assistant_with_tool_calls)
      expect(history.pending_tool_calls?).to be true
    end

    it "returns false when tool_calls are followed by tool_result" do
      history.append(user_msg)
      history.append(assistant_with_tool_calls)
      history.append(tool_result_msg)
      expect(history.pending_tool_calls?).to be false
    end

    it "returns false when last message is plain assistant" do
      history.append(user_msg)
      history.append(assistant_msg)
      expect(history.pending_tool_calls?).to be false
    end

    it "returns false when history is empty" do
      expect(history.pending_tool_calls?).to be false
    end
  end

  # ─────────────────────────────────────────────
  # last_session_context_date
  # ─────────────────────────────────────────────
  describe "#last_session_context_date" do
    it "returns the date from the last session_context message" do
      history.append(user_msg("ctx", session_context: true, session_date: "2026-03-16"))
      history.append(user_msg)
      expect(history.last_session_context_date).to eq("2026-03-16")
    end

    it "returns nil if no session_context message exists" do
      history.append(user_msg)
      expect(history.last_session_context_date).to be_nil
    end
  end

  # ─────────────────────────────────────────────
  # real_user_messages
  # ─────────────────────────────────────────────
  describe "#real_user_messages" do
    it "returns only non-system-injected user messages" do
      history.append(user_msg("real1"))
      history.append(user_msg("shim", system_injected: true))
      history.append(user_msg("real2"))
      expect(history.real_user_messages.map { |m| m[:content] }).to eq(%w[real1 real2])
    end
  end

  # ─────────────────────────────────────────────
  # subagent_instruction_message
  # ─────────────────────────────────────────────
  describe "#subagent_instruction_message" do
    it "finds the message with subagent_instructions flag" do
      history.append(user_msg)
      history.append(assistant_msg("instructions", subagent_instructions: true))
      expect(history.subagent_instruction_message).to include(subagent_instructions: true)
    end

    it "returns nil if none found" do
      history.append(user_msg)
      expect(history.subagent_instruction_message).to be_nil
    end
  end

  # ─────────────────────────────────────────────
  # for_task
  # ─────────────────────────────────────────────
  describe "#for_task" do
    it "returns only messages with task_id <= given id" do
      history.append(user_msg("t1", task_id: 1))
      history.append(assistant_msg("t2", task_id: 2))
      history.append(user_msg("t3", task_id: 3))
      result = history.for_task(2)
      expect(result.map { |m| m[:content] }).to eq(%w[t1 t2])
    end
  end

  # ─────────────────────────────────────────────
  # recent_truncation_count
  # ─────────────────────────────────────────────
  describe "#recent_truncation_count" do
    it "counts truncated messages in the last N messages" do
      history.append(assistant_msg("ok"))
      history.append(assistant_msg("truncated", truncated: true))
      history.append(assistant_msg("truncated", truncated: true))
      expect(history.recent_truncation_count(5)).to eq(2)
    end

    it "only looks at the last N messages" do
      10.times { history.append(assistant_msg("truncated", truncated: true)) }
      3.times { history.append(assistant_msg("ok")) }
      # last 3 are all non-truncated, so count should be 0
      expect(history.recent_truncation_count(3)).to eq(0)
    end
  end

  # ─────────────────────────────────────────────
  # last_real_user_index
  # ─────────────────────────────────────────────
  describe "#last_real_user_index" do
    it "returns the index of the last non-system-injected user message" do
      history.append(user_msg("real"))        # index 0
      history.append(assistant_msg)           # index 1
      history.append(user_msg("shim", system_injected: true)) # index 2
      expect(history.last_real_user_index).to eq(0)
    end

    it "returns nil if no real user message" do
      history.append(user_msg("shim", system_injected: true))
      expect(history.last_real_user_index).to be_nil
    end
  end

  # ─────────────────────────────────────────────
  # truncate_from
  # ─────────────────────────────────────────────
  describe "#truncate_from" do
    it "removes all messages from the given index onward" do
      history.append(user_msg("a"))   # 0
      history.append(assistant_msg)   # 1
      history.append(user_msg("b"))   # 2
      history.truncate_from(1)
      expect(history.size).to eq(1)
      expect(history.to_a.first[:content]).to eq("a")
    end
  end

  describe "#rollback_before" do
    it "removes the target message and everything after it" do
      history.append(user_msg("a"))
      pivot = { role: "user", content: "pivot", system_injected: true }
      history.append(pivot)
      history.append(assistant_msg)
      history.rollback_before(pivot)
      expect(history.size).to eq(1)
      expect(history.to_a.last[:content]).to eq("a")
    end

    it "is a no-op when the message is not found" do
      history.append(user_msg("a"))
      other = { role: "user", content: "not in history" }
      history.rollback_before(other)
      expect(history.size).to eq(1)
    end

    it "uses object identity not value equality" do
      msg = { role: "user", content: "same content", system_injected: true }
      doppelganger = { role: "user", content: "same content", system_injected: true }
      history.append(user_msg("before"))
      history.append(doppelganger)
      history.append(user_msg("after"))
      # rollback_before(msg) should be a no-op because msg is not the same object
      history.rollback_before(msg)
      expect(history.size).to eq(3)
    end
  end

  # ─────────────────────────────────────────────
  # size / empty?
  # ─────────────────────────────────────────────
  describe "#size / #empty?" do
    it "returns correct size" do
      expect(history.size).to eq(0)
      history.append(user_msg)
      expect(history.size).to eq(1)
    end

    it "returns true when empty" do
      expect(history.empty?).to be true
      history.append(user_msg)
      expect(history.empty?).to be false
    end
  end

  # ─────────────────────────────────────────────
  # to_api
  # ─────────────────────────────────────────────
  describe "#to_api" do
    it "strips internal fields (task_id, created_at, system_injected, etc.)" do
      history.append(user_msg("hello", task_id: 1, created_at: 123.0, system_injected: true,
                                       session_context: true, memory_update: true))
      api_msgs = history.to_api
      expect(api_msgs.first.keys).to contain_exactly(:role, :content)
    end

    it "keeps assistant+tool_calls when tool_result follows" do
      history.append(user_msg)
      history.append(assistant_with_tool_calls)
      history.append(tool_result_msg)
      api_msgs = history.to_api
      expect(api_msgs.size).to eq(3)
    end

    it "keeps system message at the start" do
      history.append(system_msg("You are helpful."))
      history.append(user_msg)
      api_msgs = history.to_api
      expect(api_msgs.first[:role]).to eq("system")
    end
  end

  # ─────────────────────────────────────────────
  # to_a
  # ─────────────────────────────────────────────
  describe "#to_a" do
    it "returns a copy of the full internal message list" do
      history.append(user_msg)
      result = history.to_a
      result.clear
      expect(history.size).to eq(1) # original not affected
    end
  end
end
