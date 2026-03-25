# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel/adapters/feishu/bot"

RSpec.describe Clacky::Channel::Adapters::Feishu::Bot do
  let(:bot) do
    described_class.new(
      app_id:     "cli_test_app_id",
      app_secret: "test_secret"
    )
  end

  # Stub the internal tenant_access_token to avoid real HTTP in tests
  before do
    allow(bot).to receive(:tenant_access_token).and_return("fake_token")
  end

  # -------------------------------------------------------------------------
  # upload_image
  # -------------------------------------------------------------------------
  describe "#upload_image" do
    it "calls the correct endpoint and returns image_key" do
      fake_response = double(
        is_a?: true,
        code: "200",
        body: '{"code":0,"data":{"image_key":"img_test_key"}}',
        "[]": nil
      )
      allow(fake_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        expect(req.path).to eq("/open-apis/im/v1/images")
        expect(req["Content-Type"]).to include("multipart/form-data")
        fake_response
      end

      result = bot.upload_image("fake_binary_data", "photo.jpg")
      expect(result).to eq("img_test_key")
    end

    it "raises when no image_key in response" do
      fake_response = double(
        is_a?: true,
        code: "200",
        body: '{"code":0,"data":{}}'
      )
      allow(fake_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(fake_response)

      expect { bot.upload_image("data", "img.png") }.to raise_error(/image_key/)
    end
  end

  # -------------------------------------------------------------------------
  # upload_file
  # -------------------------------------------------------------------------
  describe "#upload_file" do
    it "calls the correct endpoint and returns file_key" do
      fake_response = double(
        is_a?: true,
        code: "200",
        body: '{"code":0,"data":{"file_key":"file_test_key"}}'
      )
      allow(fake_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        expect(req.path).to eq("/open-apis/im/v1/files")
        expect(req.body).to include("file_type")
        fake_response
      end

      result = bot.upload_file("binary", "report.pdf", "pdf")
      expect(result).to eq("file_test_key")
    end

    it "raises when no file_key in response" do
      fake_response = double(
        is_a?: true,
        code: "200",
        body: '{"code":0,"data":{}}'
      )
      allow(fake_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(fake_response)

      expect { bot.upload_file("data", "doc.pdf", "pdf") }.to raise_error(/file_key/)
    end

    it "includes duration field when provided" do
      fake_response = double(
        is_a?: true,
        code: "200",
        body: '{"code":0,"data":{"file_key":"audio_key"}}'
      )
      allow(fake_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        expect(req.body).to include("duration")
        fake_response
      end

      result = bot.upload_file("audio_binary", "voice.opus", "opus", duration: 5000)
      expect(result).to eq("audio_key")
    end
  end

  # -------------------------------------------------------------------------
  # send_image / send_file_message / send_audio / send_video
  # -------------------------------------------------------------------------
  describe "media message senders" do
    let(:fake_post_response) { { "code" => 0, "data" => { "message_id" => "om_msg_123" } } }

    before do
      allow(bot).to receive(:post).and_return(fake_post_response)
    end

    it "#send_image sends msg_type=image with image_key" do
      expect(bot).to receive(:post).with(
        "/open-apis/im/v1/messages",
        hash_including(msg_type: "image"),
        params: { receive_id_type: "chat_id" }
      ).and_return(fake_post_response)

      result = bot.send_image("oc_chat_123", "img_key_abc")
      expect(result[:message_id]).to eq("om_msg_123")
    end

    it "#send_file_message sends msg_type=file with file_key" do
      expect(bot).to receive(:post).with(
        "/open-apis/im/v1/messages",
        hash_including(msg_type: "file"),
        params: { receive_id_type: "chat_id" }
      ).and_return(fake_post_response)

      bot.send_file_message("oc_chat_123", "file_key_abc")
    end

    it "#send_audio sends msg_type=audio" do
      expect(bot).to receive(:post).with(
        "/open-apis/im/v1/messages",
        hash_including(msg_type: "audio"),
        params: { receive_id_type: "chat_id" }
      ).and_return(fake_post_response)

      bot.send_audio("oc_chat_123", "file_key_opus")
    end

    it "#send_video sends msg_type=media" do
      expect(bot).to receive(:post).with(
        "/open-apis/im/v1/messages",
        hash_including(msg_type: "media"),
        params: { receive_id_type: "chat_id" }
      ).and_return(fake_post_response)

      bot.send_video("oc_chat_123", "file_key_mp4")
    end

    it "passes reply_to as reply_to_message_id" do
      expect(bot).to receive(:post).with(
        "/open-apis/im/v1/messages",
        hash_including(reply_to_message_id: "om_reply_001"),
        params: { receive_id_type: "chat_id" }
      ).and_return(fake_post_response)

      bot.send_image("oc_chat_123", "img_key", reply_to: "om_reply_001")
    end
  end
end
