# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel/adapters/dingtalk/adapter"
require "clacky/server/channel/adapters/dingtalk/api_client"

RSpec.describe Clacky::Channel::Adapters::DingTalk::Adapter do
  let(:config) do
    {
      client_id:     "cid",
      client_secret: "secret",
      allowed_users: []
    }
  end

  let(:adapter)    { described_class.new(config) }
  let(:api_client) { adapter.instance_variable_get(:@api_client) }

  describe ".platform_id" do
    it { expect(described_class.platform_id).to eq(:dingtalk) }
  end

  describe "#send_text" do
    let(:webhook) { "https://oapi.dingtalk.com/robot/send?access_token=xxx" }

    before do
      adapter.send(:cache_webhook, "chat-1", webhook,
                   ((Time.now.to_f + 7200) * 1000).to_i)
    end

    it "always sends as markdown msgtype (C-5596)" do
      expect(api_client).to receive(:send_via_webhook)
        .with(webhook, "# Hello\n**bold**", msg_type: :markdown)
        .and_return({ "errcode" => 0 })

      adapter.send_text("chat-1", "# Hello\n**bold**")
    end

    it "sends plain text as markdown too (no detection branch)" do
      expect(api_client).to receive(:send_via_webhook)
        .with(webhook, "just text", msg_type: :markdown)
        .and_return({ "errcode" => 0 })

      adapter.send_text("chat-1", "just text")
    end

    it "returns error hash when webhook expired" do
      adapter.instance_variable_set(:@webhook_urls, {})
      result = adapter.send_text("chat-1", "hi")
      expect(result[:ok]).to eq(false)
      expect(result[:error]).to eq("session_webhook_expired")
    end
  end

  describe "#handle_frame inbound parsing (C-5598)" do
    let(:on_message) { ->(_evt) {} }
    let(:webhook)    { "https://oapi.dingtalk.com/robot/send?access_token=xxx" }
    let(:expires)    { ((Time.now.to_f + 7200) * 1000).to_i }

    before { adapter.instance_variable_set(:@on_message, on_message) }

    def base_data(extra = {})
      {
        "senderStaffId"             => "user-1",
        "conversationId"            => "conv-1",
        "sessionWebhook"            => webhook,
        "sessionWebhookExpiredTime" => expires,
        "conversationType"          => "1",
        "robotCode"                 => "robot-1",
        "msgId"                     => "m-1"
      }.merge(extra)
    end

    def frame(data)
      {
        "headers" => { "topic" => "/v1.0/im/bot/messages/get" },
        "data"    => JSON.generate(data)
      }
    end

    it "parses text msgtype" do
      captured = nil
      adapter.instance_variable_set(:@on_message, ->(evt) { captured = evt })

      adapter.send(:handle_frame, frame(base_data(
        "msgtype" => "text",
        "text"    => { "content" => "hello bot" }
      )))

      expect(captured[:text]).to eq("hello bot")
      expect(captured[:files]).to eq([])
    end

    it "parses picture msgtype and downloads file" do
      tempfile = Tempfile.new(["dl-", ".png"])
      tempfile.close
      allow(api_client).to receive(:download_message_file)
        .with("DL-CODE-1", "robot-1", prefer_name: nil)
        .and_return({ path: tempfile.path, mime: "image/png" })

      captured = nil
      adapter.instance_variable_set(:@on_message, ->(evt) { captured = evt })

      adapter.send(:handle_frame, frame(base_data(
        "msgtype" => "picture",
        "content" => { "downloadCode" => "DL-CODE-1" }
      )))

      expect(captured[:files].size).to eq(1)
      expect(captured[:files].first[:mime]).to eq("image/png")
    end

    it "parses file msgtype, downloads it, and preserves original fileName" do
      tempfile = Tempfile.new(["dl-", ".bin"])
      tempfile.close
      allow(api_client).to receive(:download_message_file)
        .with("DL-FILE-1", "robot-1", prefer_name: "report.pdf")
        .and_return({ path: tempfile.path, mime: "application/pdf" })

      captured = nil
      adapter.instance_variable_set(:@on_message, ->(evt) { captured = evt })

      adapter.send(:handle_frame, frame(base_data(
        "msgtype" => "file",
        "content" => { "downloadCode" => "DL-FILE-1", "fileName" => "report.pdf" }
      )))

      expect(captured[:files].size).to eq(1)
      expect(captured[:files].first[:name]).to eq("report.pdf")
      expect(captured[:files].first[:mime]).to eq("application/pdf")
    end

    it "parses file msgtype for non-whitelist extensions (e.g. .txt) — inbound has no whitelist" do
      tempfile = Tempfile.new(["dl-", ".bin"])
      tempfile.close
      allow(api_client).to receive(:download_message_file)
        .with("DL-FILE-2", "robot-1", prefer_name: "notes.txt")
        .and_return({ path: tempfile.path, mime: "text/plain" })

      captured = nil
      adapter.instance_variable_set(:@on_message, ->(evt) { captured = evt })

      adapter.send(:handle_frame, frame(base_data(
        "msgtype" => "file",
        "content" => { "downloadCode" => "DL-FILE-2", "fileName" => "notes.txt" }
      )))

      expect(captured[:files].size).to eq(1)
      expect(captured[:files].first[:name]).to eq("notes.txt")
    end

    it "parses richText msgtype: text + picture mixed" do
      tempfile = Tempfile.new(["dl-", ".jpg"])
      tempfile.close
      allow(api_client).to receive(:download_message_file)
        .with("DL-CODE-2", "robot-1", prefer_name: nil)
        .and_return({ path: tempfile.path, mime: "image/jpeg" })

      captured = nil
      adapter.instance_variable_set(:@on_message, ->(evt) { captured = evt })

      adapter.send(:handle_frame, frame(base_data(
        "msgtype" => "richText",
        "content" => {
          "richText" => [
            { "text" => "look at this " },
            { "downloadCode" => "DL-CODE-2", "type" => "picture" }
          ]
        }
      )))

      expect(captured[:text]).to eq("look at this ")
      expect(captured[:files].size).to eq(1)
    end

    it "skips download when downloadCode resolution fails" do
      allow(api_client).to receive(:download_message_file).and_return(nil)

      captured = nil
      adapter.instance_variable_set(:@on_message, ->(evt) { captured = evt })

      adapter.send(:handle_frame, frame(base_data(
        "msgtype" => "picture",
        "content" => { "downloadCode" => "BAD" }
      )))

      expect(captured).to be_nil  # text empty + files empty → no event
    end

    it "ignores unsupported msgtype" do
      captured = nil
      adapter.instance_variable_set(:@on_message, ->(evt) { captured = evt })

      adapter.send(:handle_frame, frame(base_data(
        "msgtype" => "audio",
        "content" => { "downloadCode" => "X" }
      )))

      expect(captured).to be_nil
    end
  end

  describe "#send_file (C-5597)" do
    let(:tempfile) do
      f = Tempfile.new(["pic-", ".png"])
      f.write("\x89PNG fake")
      f.close
      f
    end

    before do
      adapter.send(:cache_route, "chat-1",
                   robot_code: "robot-1",
                   conv_id:    "conv-1",
                   user_id:    "user-1",
                   conv_type:  "1")
    end

    it "uploads media then sends image via OAPI for DM" do
      expect(api_client).to receive(:upload_media)
        .with(tempfile.path, kind: :image)
        .and_return("media-xyz")
      expect(api_client).to receive(:send_media)
        .with(hash_including(
          robot_code: "robot-1",
          conv_type:  "1",
          user_id:    "user-1",
          media_id:   "media-xyz",
          kind:       :image
        ))
        .and_return({ ok: true })

      result = adapter.send_file("chat-1", tempfile.path)
      expect(result[:ok]).to eq(true)
    end

    it "uses :file kind for non-image extensions" do
      pdf = Tempfile.new(["doc-", ".pdf"])
      pdf.write("hi"); pdf.close

      expect(api_client).to receive(:upload_media)
        .with(pdf.path, kind: :file)
        .and_return("media-doc")
      expect(api_client).to receive(:send_media)
        .with(hash_including(kind: :file, file_name: File.basename(pdf.path)))
        .and_return({ ok: true })

      adapter.send_file("chat-1", pdf.path)
    end

    it "sends [DingTalk System] error text and returns ok:false for non-whitelist files" do
      txt = Tempfile.new(["unsupported-", ".txt"])
      txt.write("hi"); txt.close

      # send_text routes via webhook, so the spec needs a valid sessionWebhook
      # cached for chat-1 (the parent describe only seeds cache_route).
      adapter.send(:cache_webhook, "chat-1",
                   "https://oapi.dingtalk.com/robot/send?access_token=xxx",
                   ((Time.now.to_f + 7200) * 1000).to_i)

      # Adapter must NOT upload or call send_media for unsupported extensions.
      # Instead it sends a chat message disguised as a DingTalk system error,
      # so the user sees the failure inline without any LLM round-trip.
      expect(api_client).not_to receive(:upload_media)
      expect(api_client).not_to receive(:send_media)

      sent_text = nil
      expect(api_client).to receive(:send_via_webhook) do |_url, text, **_kwargs|
        sent_text = text
        { "errcode" => 0 }
      end

      result = adapter.send_file("chat-1", txt.path, name: "report.txt")
      expect(result[:ok]).to eq(false)
      expect(result[:error]).to eq(:unsupported_extension)

      expect(sent_text).to start_with("[DingTalk System] ⚠️")
      expect(sent_text).to include('"report.txt"')
      expect(sent_text).to include('".txt"')
      # Lists the supported extensions so the LLM/user knows what to convert to.
      Clacky::Channel::Adapters::DingTalk::ApiClient::SUPPORTED_FILE_EXTS.each do |ext|
        expect(sent_text).to include(".#{ext}")
      end
    end

    it "returns file_not_found when path doesn't exist" do
      result = adapter.send_file("chat-1", "/nonexistent/path.png")
      expect(result[:ok]).to eq(false)
      expect(result[:error]).to eq("file_not_found")
    end

    it "returns no_route when chat has no cached routing" do
      adapter.instance_variable_set(:@routes, {})
      result = adapter.send_file("chat-1", tempfile.path)
      expect(result[:ok]).to eq(false)
      expect(result[:error]).to eq("no_route")
    end

    it "returns upload_failed when media upload returns nil" do
      allow(api_client).to receive(:upload_media).and_return(nil)
      result = adapter.send_file("chat-1", tempfile.path)
      expect(result[:ok]).to eq(false)
      expect(result[:error]).to eq("upload_failed")
    end
  end
end
