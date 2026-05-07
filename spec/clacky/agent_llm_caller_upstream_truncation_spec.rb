# frozen_string_literal: true

# Tests for upstream tool-call truncation detection in Agent#call_llm.
#
# Background (root cause tracked in memory `openclacky-agent-silent-stop-bug`):
#
#   OpenRouter / Bedrock and other routers occasionally close the SSE stream
#   mid-tool_use. The response we receive looks like success:
#     - finish_reason = "stop"   (or "tool_calls")
#     - tool_calls[]  has one entry with a valid `id` and `name`
#     - arguments     is `""`, `"{}"`, or non-parseable JSON
#
#   Previously, the agent's main loop short-circuited on
#     `finish_reason == "stop" || tool_calls empty`
#   which caused it to silently exit treating the truncated response as a
#   completed task — no error, no retry, stats.last_status = :success.
#
#   Fix has two layers:
#     1. LlmCaller#detect_upstream_truncation! raises UpstreamTruncatedError
#        (< RetryableError) so the standard retry/fallback path kicks in.
#     2. Agent main loop no longer exits on finish_reason=="stop" alone —
#        only truly-empty tool_calls terminates the loop (defense in depth).

RSpec.describe Clacky::Agent, "upstream tool-call truncation recovery" do
  let(:config) do
    Clacky::AgentConfig.new(
      models: [{
        "type"             => "default",
        "model"            => "abs-claude-opus-4-7",
        "api_key"          => "absk-test",
        "base_url"         => "https://openrouter.ai/api/v1",
        "anthropic_format" => false
      }],
      permission_mode: :auto_approve
    )
  end

  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      allow(c).to receive(:instance_variable_get).with(:@api_key).and_return("absk-test")
      allow(c).to receive(:bedrock?).and_return(false)
      allow(c).to receive(:anthropic_format?).and_return(false)
      allow(c).to receive(:supports_prompt_caching?).and_return(false)
      allow(c).to receive(:format_tool_results) do |_resp, tool_results, **_|
        tool_results.map { |r| { role: "tool", tool_call_id: r[:id], content: r[:content] } }
      end
    end
  end

  let(:agent) do
    described_class.new(
      client, config,
      working_dir: Dir.pwd,
      ui: nil,
      profile: "general",
      session_id: Clacky::SessionManager.generate_id,
      source: :manual
    )
  end

  # Build a tool_call whose arguments JSON was truncated by the upstream.
  # The call references `write` (which has a required `path`/`content` schema).
  def truncated_call(args:, id: "call_truncated_#{SecureRandom.hex(3)}")
    {
      id: id,
      type: "function",
      name: "write",
      arguments: args
    }
  end

  before do
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  # ── Detector-level unit tests (tool_call_args_truncated?) ────────────────

  describe "#tool_call_args_truncated? (private)" do
    subject(:truncated) { agent.send(:tool_call_args_truncated?, args) }

    context "with nil args" do
      let(:args) { nil }
      it { is_expected.to be true }
    end

    context "with non-String args" do
      let(:args) { { path: "/tmp/x" } } # raw hash, not JSON-encoded
      it { is_expected.to be true }
    end

    context %q(with empty string args "") do
      let(:args) { "" }
      it { is_expected.to be true }
    end

    context %q(with placeholder args "{}") do
      let(:args) { "{}" }
      it { is_expected.to be true }
    end

    context "with non-parseable JSON (partial stream)" do
      let(:args) { '{"path": "/tmp/x"' } # truncated mid-object
      # Intentionally NOT treated as truncation here — the existing
      # ArgumentsParser → BadArgumentsError path handles partial JSON by
      # surfacing the parse error to the LLM as a tool_result, which is
      # more efficient than a blind retry.
      it { is_expected.to be false }
    end

    context "with complete, non-empty JSON" do
      let(:args) { '{"path": "/tmp/x", "content": "hi"}' }
      it { is_expected.to be false }
    end

    context "with a single-key JSON" do
      let(:args) { '{"path": "/tmp/x"}' }
      it { is_expected.to be false }  # parseable + non-empty → not a truncation
    end

    context "with non-object JSON (array)" do
      let(:args) { '[1,2,3]' }
      # Non-object but parseable + non-empty → not our truncation signature
      it { is_expected.to be false }
    end
  end

  # ── Integration: agent recovers from finish_reason=stop + args={} ────────

  describe 'finish_reason="stop" + tool_calls=[write] with args="{}" (OpenRouter silent truncation)' do
    it "retries and succeeds instead of silently exiting" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        if call_count == 1
          # The exact silent-stop shape we saw in production logs:
          # finish_reason=stop + a tool_call whose args is the empty "{}" placeholder
          mock_api_response(
            content: "",
            tool_calls: [truncated_call(args: "{}")],
            finish_reason: "stop"
          )
        else
          mock_api_response(content: "Done.")
        end
      end

      result = agent.run("create a file")
      expect(result[:status]).to eq(:success)
      expect(call_count).to be >= 2  # at least one retry happened
    end
  end

  describe 'finish_reason="stop" + tool_calls=[write] with args=""' do
    it "retries and succeeds" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        if call_count == 1
          mock_api_response(
            content: "",
            tool_calls: [truncated_call(args: "")],
            finish_reason: "stop"
          )
        else
          mock_api_response(content: "Done.")
        end
      end

      agent.run("create a file")
      expect(call_count).to be >= 2
    end
  end

  describe 'tool_calls=[write] with partial/invalid JSON args' do
    # Partial JSON is NOT intercepted by the upstream-truncation detector —
    # it falls through to the existing ArgumentsParser / BadArgumentsError
    # path (see bedrock_truncation_recovery_spec.rb for that coverage).
    # We assert the negative: the detector stays out of the way.
    it "does NOT raise UpstreamTruncatedError for partial-JSON args" do
      allow(client).to receive(:send_messages_with_tools).and_return(
        mock_api_response(
          content: "",
          tool_calls: [truncated_call(args: '{"path": "/tmp/x"')],
          finish_reason: "tool_calls"
        ),
        mock_api_response(content: "Done.")
      )

      # Not raising UpstreamTruncatedError means our detector didn't fire.
      # The BadArgumentsError path then kicks in, producing a tool_result
      # error — tested separately in bedrock_truncation_recovery_spec.
      expect { agent.run("create a file") }.not_to raise_error
    end
  end

  # ── Negative: legitimate response with full args is NOT treated as truncation ──

  describe "complete tool_call args (normal success path)" do
    it "does NOT retry; tool is executed once and task completes" do
      Dir.mktmpdir do |dir|
        tmp = File.join(dir, "ok.txt")
        call_count = 0
        allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
          call_count += 1
          if call_count == 1
            mock_api_response(
              content: "",
              tool_calls: [{
                id: "call_ok",
                type: "function",
                name: "write",
                arguments: JSON.generate(path: tmp, content: "hi")
              }],
              finish_reason: "tool_calls"
            )
          else
            mock_api_response(content: "Done.")
          end
        end

        result = agent.run("write file")
        expect(result[:status]).to eq(:success)
        expect(File.exist?(tmp)).to be true
        expect(call_count).to eq(2)  # 1 write + 1 final summary, no retries
      end
    end
  end

  # ── Hint injection: smaller-steps guidance on first truncation ──

  describe "[SYSTEM] hint injection on first upstream truncation" do
    it "appends a one-shot system hint to history advising smaller tool_call args" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        if call_count == 1
          mock_api_response(
            content: "",
            tool_calls: [truncated_call(args: "{}")],
            finish_reason: "stop"
          )
        else
          mock_api_response(content: "Done.")
        end
      end

      agent.run("write a big file")

      # Grab the raw history and look for our system-injected nudge.
      # Note: agents may inject other system messages (e.g. disk file refs),
      # so we filter specifically by our hint content.
      history_dump = agent.instance_variable_get(:@history).to_a
      injected = history_dump.select do |m|
        m[:system_injected] == true && m[:content].to_s.include?("cut short by the upstream")
      end
      expect(injected.size).to eq(1)
      expect(injected.first[:content]).to match(/smaller.*tool_call|break.*smaller/i)
    end

    it "only injects ONCE per task even if truncation recurs before success" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        if call_count <= 2
          mock_api_response(
            content: "",
            tool_calls: [truncated_call(args: "{}")],
            finish_reason: "stop"
          )
        else
          mock_api_response(content: "Done.")
        end
      end

      agent.run("write a big file")

      history_dump = agent.instance_variable_get(:@history).to_a
      injected = history_dump.select do |m|
        m[:system_injected] == true && m[:content].to_s.include?("cut short by the upstream")
      end
      expect(injected.size).to eq(1)  # not 2, despite two truncations
    end
  end

  # ── Runaway protection: never-ending truncation should terminate, not loop ──

  describe "persistent truncation never recovers" do
    it "eventually raises AgentError after exhausting retries (no infinite loop)" do
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        mock_api_response(
          content: "",
          tool_calls: [truncated_call(args: "{}")],
          finish_reason: "stop"
        )
      end

      # Must terminate. After the fallback retry budget is also exhausted,
      # call_llm raises AgentError. What we CARE about is:
      #   1. It terminates within a bounded time (no infinite loop)
      #   2. The exception (if any) is our own AgentError, not some
      #      unrelated crash from executing a tool with empty args
      expect {
        Timeout.timeout(10) { agent.run("create a file") }
      }.to raise_error(Clacky::AgentError, /Service unavailable|Upstream truncated/i)
    end
  end
end
