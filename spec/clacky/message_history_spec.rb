# frozen_string_literal: true

require "json"

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

    # ── reasoning_content consistency ────────────────────────────────────────
    #
    # Thinking-mode providers (DeepSeek V4, Kimi K2 thinking, etc.) return a
    # `reasoning_content` field on each assistant turn and REQUIRE the caller
    # to echo `reasoning_content` back on every subsequent assistant message
    # in the payload — omitting it triggers HTTP 400 with:
    #   "The reasoning_content in the thinking mode must be passed back"
    #
    # History contains two kinds of assistant messages:
    #   • Real LLM responses (carry reasoning_content when provider emitted it)
    #   • Synthetic / injected messages (skill injection, subagent acks,
    #     slash-command notices, truncation fallbacks — never carry it)
    #
    # #to_api must pad synthetic messages with an empty reasoning_content
    # whenever ANY assistant message in the history already carries one
    # (proving the current provider is in thinking mode).
    describe "reasoning_content auto-padding" do
      it "pads synthetic assistant messages with empty reasoning_content when a real LLM assistant has reasoning_content" do
        # Scenario: DeepSeek V4 thinking-mode session where the LLM returned
        # reasoning, then a skill was injected locally (no reasoning).
        history.append(user_msg("hi"))
        history.append(assistant_msg("LLM reply", reasoning_content: "I think..."))
        history.append(user_msg("do skill"))
        history.append(assistant_with_tool_calls("invoke_skill", reasoning_content: "calling skill"))
        history.append(tool_result_msg)
        # Locally-injected synthetic assistant — no reasoning_content.
        history.append(assistant_msg("# Skill Content\n...", system_injected: true))
        history.append(user_msg("[SYSTEM] proceed", system_injected: true))

        api_msgs = history.to_api
        assistant_msgs = api_msgs.select { |m| m[:role] == "assistant" }

        expect(assistant_msgs.size).to eq(3)
        expect(assistant_msgs).to all(have_key(:reasoning_content))
        # Real LLM messages keep their original reasoning_content.
        expect(assistant_msgs[0][:reasoning_content]).to eq("I think...")
        expect(assistant_msgs[1][:reasoning_content]).to eq("calling skill")
        # Synthetic message is padded with an empty string.
        expect(assistant_msgs[2][:reasoning_content]).to eq("")
      end

      it "does NOT pad when no assistant message carries reasoning_content (non-thinking provider)" do
        # Scenario: Claude / OpenAI session — LLM never emits reasoning_content.
        history.append(user_msg("hi"))
        history.append(assistant_msg("Claude reply"))
        history.append(user_msg("do skill"))
        history.append(assistant_msg("# Skill Content", system_injected: true))

        api_msgs = history.to_api
        assistant_msgs = api_msgs.select { |m| m[:role] == "assistant" }

        expect(assistant_msgs).to all(satisfy { |m| !m.key?(:reasoning_content) })
      end

      it "does NOT pad when only synthetic assistant messages exist (thinking mode not yet activated)" do
        # Scenario: first turn invokes a skill via slash-command before any
        # real LLM response — thinking mode has not been proven yet.
        history.append(user_msg("/skill-name"))
        history.append(assistant_msg("# Skill Content", system_injected: true))
        history.append(user_msg("[SYSTEM] proceed", system_injected: true))

        api_msgs = history.to_api
        assistant_msgs = api_msgs.select { |m| m[:role] == "assistant" }

        expect(assistant_msgs.size).to eq(1)
        expect(assistant_msgs.first).not_to have_key(:reasoning_content)
      end

      it "preserves an explicit empty-string reasoning_content and does not overwrite it" do
        history.append(user_msg("hi"))
        history.append(assistant_msg("reply", reasoning_content: "thought"))
        history.append(user_msg("more"))
        history.append(assistant_msg("reply 2", reasoning_content: ""))

        api_msgs = history.to_api
        assistant_msgs = api_msgs.select { |m| m[:role] == "assistant" }

        expect(assistant_msgs[0][:reasoning_content]).to eq("thought")
        expect(assistant_msgs[1][:reasoning_content]).to eq("")
      end

      it "does not mutate user/tool/system messages (only assistant is padded)" do
        history.append(system_msg("You are helpful."))
        history.append(user_msg("hi"))
        history.append(assistant_msg("reply", reasoning_content: "thought"))
        history.append(assistant_with_tool_calls("bash"))
        history.append(tool_result_msg)

        api_msgs = history.to_api
        non_assistant = api_msgs.reject { |m| m[:role] == "assistant" }

        expect(non_assistant).to all(satisfy { |m| !m.key?(:reasoning_content) })
      end

      # Regression: a session started on a provider that keeps thinking
      # inline in content (e.g. MiniMax: <think>...</think>) then switched
      # to DeepSeek/Kimi thinking-mode. The history-evidence heuristic
      # can't fire because no assistant message ever carried a
      # reasoning_content FIELD — everything is embedded in content. The
      # LLM caller detects the 400 "reasoning_content must be passed back"
      # error and retries once with force_reasoning_content_pad: true.
      it "pads every assistant message when force_reasoning_content_pad is true even without any evidence in history" do
        # Simulate the exact shape of ~/Downloads/session.json: all assistant
        # messages have <think> text inside content, none carry a
        # reasoning_content field.
        history.append(user_msg("go"))
        history.append(assistant_with_tool_calls("terminal", content: "<think>planning...</think>"))
        history.append(tool_result_msg)
        history.append(assistant_msg("<think>done</think>\n\nDone!"))
        history.append(user_msg("random"))
        history.append(assistant_msg("<think>hmm</think>\n\nReply"))

        # Without the flag, to_api does NOT pad (nothing in history says
        # we're in thinking mode).
        unforced = history.to_api
        unforced_asst = unforced.select { |m| m[:role] == "assistant" }
        expect(unforced_asst).to all(satisfy { |m| !m.key?(:reasoning_content) })

        # With the flag (set by the BadRequestError retry path), every
        # assistant message gets a padded empty reasoning_content.
        forced = history.to_api(force_reasoning_content_pad: true)
        forced_asst = forced.select { |m| m[:role] == "assistant" }
        expect(forced_asst.size).to eq(3)
        expect(forced_asst).to all(have_key(:reasoning_content))
        expect(forced_asst.map { |m| m[:reasoning_content] }).to all(eq(""))

        # <think> text inside content must be preserved untouched — the
        # pad only adds the missing field, never rewrites content.
        expect(forced_asst[0][:content]).to include("<think>planning...</think>")
        expect(forced_asst[2][:content]).to include("<think>hmm</think>")
      end

      it "force pad preserves existing non-empty reasoning_content on real LLM messages" do
        history.append(user_msg("hi"))
        history.append(assistant_msg("real reply", reasoning_content: "real thought"))
        history.append(user_msg("more"))
        history.append(assistant_msg("synthetic", system_injected: true))

        forced = history.to_api(force_reasoning_content_pad: true)
        asst = forced.select { |m| m[:role] == "assistant" }

        expect(asst[0][:reasoning_content]).to eq("real thought")
        expect(asst[1][:reasoning_content]).to eq("")
      end
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

  describe "UTF-8 sanitization on append" do
    it "scrubs invalid UTF-8 bytes from string content" do
      # GBK bytes for "你好" — illegal as UTF-8. Use .b + .dup to escape
      # the frozen-string-literal pragma and produce a mutable UTF-8-tagged string.
      dirty = ("prefix".b + "\xC4\xE3\xBA\xC3".b + "suffix".b).force_encoding("UTF-8")
      expect(dirty.valid_encoding?).to be(false)

      history.append(user_msg(dirty))
      stored = history.to_a.last[:content]

      expect(stored.encoding).to eq(Encoding::UTF_8)
      expect(stored.valid_encoding?).to be(true)
      expect(stored).to start_with("prefix")
      expect(stored).to end_with("suffix")
      expect { JSON.generate(history.to_a) }.not_to raise_error
    end

    it "scrubs invalid UTF-8 bytes deep inside nested structures" do
      dirty = "\xC4\xE3\xBA\xC3".b.force_encoding("UTF-8")
      msg = {
        role: "tool",
        tool_results: [{ tool_use_id: "tc_1", content: dirty }],
        task_id: 1, created_at: Time.now.to_f
      }
      history.append(msg)

      stored_content = history.to_a.last[:tool_results].first[:content]
      expect(stored_content.valid_encoding?).to be(true)
      expect { JSON.generate(history.to_a) }.not_to raise_error
    end

    it "leaves valid UTF-8 messages as the same object (preserves object identity)" do
      # This is critical for rollback_before which uses m.equal?(message).
      msg = user_msg("你好世界")
      history.append(msg)
      expect(history.to_a.last).to equal(msg)  # same Hash instance
    end
  end
end
