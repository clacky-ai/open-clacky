# frozen_string_literal: true

require "clacky/server/channel/adapters/weixin/adapter"

RSpec.describe Clacky::Channel::Adapters::Weixin::SendQueue do
  let(:api_client) { instance_double("Clacky::Channel::Adapters::Weixin::ApiClient") }
  let(:logger) do
    instance_double("Logger").tap do |l|
      allow(l).to receive(:error)
      allow(l).to receive(:warn)
      allow(l).to receive(:info)
    end
  end

  # Speed knobs: make every interval tiny so the suite stays sub-second.
  # We can't tweak the loop's `sleep 0.2` from outside, so timing-sensitive
  # specs use `instance_variable_get(:@flusher)` to stop the thread first
  # and drive `drain_buffers` synchronously via `send(:drain_buffers)`.
  before do
    stub_const("Clacky::Channel::Adapters::Weixin::SendQueue::FLUSH_CHAR_THRESHOLD", 20)
    stub_const("Clacky::Channel::Adapters::Weixin::SendQueue::FLUSH_INTERVAL", 0.05)
    stub_const("Clacky::Channel::Adapters::Weixin::SendQueue::MIN_SEND_INTERVAL", 0.0)
    stub_const("Clacky::Channel::Adapters::Weixin::SendQueue::RETRY_BACKOFFS", [0.0, 0.0, 0.0])
  end

  # Build a queue and immediately stop its background thread so we can drive
  # `drain_buffers` deterministically. Use this for unit-level checks.
  def build_quiesced_queue
    q = described_class.new(api_client, logger: logger)
    q.instance_variable_set(:@running, false)
    q.instance_variable_get(:@flusher).join(1)
    q
  end

  describe "#enqueue" do
    it "buffers entries per chat_id without sending" do
      q = build_quiesced_queue
      expect(api_client).not_to receive(:send_text)

      q.enqueue("u1", "hello", "ctx1")
      q.enqueue("u1", "world", "ctx2")
      q.enqueue("u2", "hi", "ctxA")

      buffers = q.instance_variable_get(:@buffers)
      expect(buffers["u1"].length).to eq(2)
      expect(buffers["u2"].length).to eq(1)
      expect(buffers["u1"].first.text).to eq("hello")
      expect(buffers["u1"].last.context_token).to eq("ctx2")
    end
  end

  describe "#flush" do
    it "sends all pending entries immediately and clears the buffer" do
      q = build_quiesced_queue
      q.enqueue("u1", "part-A", "ctx-old")
      q.enqueue("u1", "part-B", "ctx-new")

      expect(api_client).to receive(:send_text)
        .with(to_user_id: "u1", text: "part-A\npart-B", context_token: "ctx-new")
        .once

      q.flush("u1")
      expect(q.instance_variable_get(:@buffers)["u1"]).to be_nil
    end

    it "is a no-op when nothing is pending" do
      q = build_quiesced_queue
      expect(api_client).not_to receive(:send_text)
      expect { q.flush("nobody") }.not_to raise_error
    end

    it "uses the latest context_token from the buffered entries" do
      q = build_quiesced_queue
      q.enqueue("u1", "a", "ctx-1")
      q.enqueue("u1", "b", "ctx-2")
      q.enqueue("u1", "c", "ctx-3")

      expect(api_client).to receive(:send_text)
        .with(hash_including(context_token: "ctx-3"))

      q.flush("u1")
    end
  end

  describe "#drain_buffers (private)" do
    it "flushes a buffer once the char threshold is exceeded" do
      q = build_quiesced_queue
      # FLUSH_CHAR_THRESHOLD is stubbed to 20
      q.enqueue("u1", "a" * 25, "ctx")

      expect(api_client).to receive(:send_text).once
      q.send(:drain_buffers)

      expect(q.instance_variable_get(:@buffers)["u1"]).to be_nil
    end

    it "flushes a buffer once FLUSH_INTERVAL has elapsed" do
      q = build_quiesced_queue
      q.enqueue("u1", "short", "ctx")

      # Backdate the entry to simulate elapsed time.
      q.instance_variable_get(:@buffers)["u1"].first.enqueued_at = Time.now - 1.0

      expect(api_client).to receive(:send_text).once
      q.send(:drain_buffers)

      expect(q.instance_variable_get(:@buffers)["u1"]).to be_nil
    end

    it "leaves the buffer untouched when neither trigger fires" do
      q = build_quiesced_queue
      q.enqueue("u1", "tiny", "ctx") # 4 chars < 20

      expect(api_client).not_to receive(:send_text)
      q.send(:drain_buffers)

      expect(q.instance_variable_get(:@buffers)["u1"].length).to eq(1)
    end

    it "logs but does not raise when the api client throws" do
      q = build_quiesced_queue
      q.enqueue("u1", "x" * 25, "ctx")

      allow(api_client).to receive(:send_text).and_raise(StandardError, "boom")
      expect(logger).to receive(:error).with(/send_text failed/)

      expect { q.send(:drain_buffers) }.not_to raise_error
    end
  end

  describe "background flusher integration" do
    it "automatically sends after FLUSH_INTERVAL elapses" do
      q = described_class.new(api_client, logger: logger)
      sent = Queue.new
      allow(api_client).to receive(:send_text) { |**args| sent << args }

      q.enqueue("u1", "hello", "ctx")

      # FLUSH_INTERVAL=0.05 + loop tick=0.2 → at most ~0.3s to observe send.
      args = Timeout.timeout(2) { sent.pop }
      expect(args[:to_user_id]).to eq("u1")
      expect(args[:text]).to eq("hello")
      expect(args[:context_token]).to eq("ctx")

      q.stop
    end
  end

  describe "#split_message (private)" do
    let(:q) { build_quiesced_queue }

    it "returns the text untouched when it fits in the limit" do
      expect(q.send(:split_message, "hello world", limit: 2000)).to eq(["hello world"])
    end

    it "splits on a paragraph break when one exists in the window" do
      head = "A" * 50
      tail = "B" * 50
      chunks = q.send(:split_message, "#{head}\n\n#{tail}", limit: 60)
      expect(chunks.length).to eq(2)
      expect(chunks[0]).to eq(head)
      expect(chunks[1]).to eq(tail)
    end

    it "falls back to single newline when no paragraph break is present" do
      head = "A" * 50
      tail = "B" * 50
      chunks = q.send(:split_message, "#{head}\n#{tail}", limit: 60)
      expect(chunks.length).to eq(2)
      expect(chunks[0]).to eq(head)
      expect(chunks[1]).to eq(tail)
    end

    it "falls back to a space when no newline is present" do
      chunks = q.send(:split_message, "#{"A" * 50} #{"B" * 50}", limit: 60)
      expect(chunks.length).to eq(2)
      expect(chunks[0]).to eq("A" * 50)
      expect(chunks[1]).to eq("B" * 50)
    end

    it "hard-cuts when there is no whitespace anywhere" do
      chunks = q.send(:split_message, "A" * 150, limit: 60)
      expect(chunks.length).to eq(3)
      expect(chunks.map(&:length)).to eq([60, 60, 30])
    end

    it "counts Unicode characters rather than bytes" do
      # 100 CJK characters; each is 3 bytes in UTF-8 but 1 char.
      text = "中" * 100
      chunks = q.send(:split_message, text, limit: 30)
      expect(chunks.length).to eq(4)
      expect(chunks.first.chars.length).to eq(30)
    end
  end

  describe "#throttle (private)" do
    it "spaces consecutive sends by at least MIN_SEND_INTERVAL" do
      stub_const("Clacky::Channel::Adapters::Weixin::SendQueue::MIN_SEND_INTERVAL", 0.1)
      q = build_quiesced_queue

      t0 = Time.now
      q.send(:throttle)
      q.send(:throttle)
      q.send(:throttle)
      elapsed = Time.now - t0

      # First throttle is "free" (no previous send), next two each wait ~0.1s.
      expect(elapsed).to be >= 0.18
      expect(elapsed).to be < 1.0 # sanity: nowhere near 30s
    end
  end

  describe "#send_with_retry (private)" do
    let(:api_error_class) { Clacky::Channel::Adapters::Weixin::ApiClient::ApiError }

    it "retries on ret=-2 then succeeds" do
      q = build_quiesced_queue
      attempts = 0
      allow(api_client).to receive(:send_text) do
        attempts += 1
        raise api_error_class.new(-2, "rate limited") if attempts < 3
        :ok
      end

      q.send(:send_with_retry, "u1", "hi", "ctx")
      expect(attempts).to eq(3)
    end

    it "stops retrying after RETRY_BACKOFFS is exhausted (rescued at outer rescue)" do
      q = build_quiesced_queue
      allow(api_client).to receive(:send_text)
        .and_raise(api_error_class.new(-2, "always rate limited"))

      expect(logger).to receive(:warn).at_least(:twice)
      expect(logger).to receive(:error).with(/send_text failed/)

      expect { q.send(:send_with_retry, "u1", "hi", "ctx") }.not_to raise_error
      # 3 backoff slots → 3 attempts total
      expect(api_client).to have_received(:send_text).exactly(3).times
    end

    it "does not retry on non -2 ApiError" do
      q = build_quiesced_queue
      allow(api_client).to receive(:send_text)
        .and_raise(api_error_class.new(-14, "session expired"))

      expect(logger).to receive(:error).with(/send_text failed/)
      q.send(:send_with_retry, "u1", "hi", "ctx")

      expect(api_client).to have_received(:send_text).once
    end

    it "swallows arbitrary StandardError and logs it" do
      q = build_quiesced_queue
      allow(api_client).to receive(:send_text).and_raise(StandardError, "network oops")

      expect(logger).to receive(:error).with(/network oops/)
      expect { q.send(:send_with_retry, "u1", "hi", "ctx") }.not_to raise_error
    end
  end

  describe "#stop" do
    it "stops the flusher thread and drains entries that meet a flush trigger" do
      q = described_class.new(api_client, logger: logger)
      sent = Queue.new
      allow(api_client).to receive(:send_text) { |**args| sent << args }

      # Enough chars (>20) to trigger the char threshold in the final drain.
      q.enqueue("u1", "final-message-final-message", "ctx")
      q.stop

      flusher = q.instance_variable_get(:@flusher)
      expect(flusher).not_to be_alive

      args = Timeout.timeout(1) { sent.pop }
      expect(args[:text]).to eq("final-message-final-message")
    end

    it "is safe to call when there are no pending entries" do
      q = described_class.new(api_client, logger: logger)
      expect { q.stop }.not_to raise_error
      expect(q.instance_variable_get(:@flusher)).not_to be_alive
    end

    it "force-drains messages even when no flush trigger was met" do
      q = described_class.new(api_client, logger: logger)
      sent = Queue.new
      allow(api_client).to receive(:send_text) { |**args| sent << args }

      q.enqueue("u1", "tiny", "ctx") # 4 chars, instant — neither trigger met
      q.stop

      args = Timeout.timeout(1) { sent.pop }
      expect(args[:text]).to eq("tiny")
    end
  end
end
