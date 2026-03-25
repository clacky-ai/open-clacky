# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel/adapters/feishu/adapter"

RSpec.describe Clacky::Channel::Adapters::Feishu::Adapter do
  let(:config) do
    { app_id: "cli_test_app_id", app_secret: "test_secret" }
  end

  let(:adapter) { described_class.new(config) }
  let(:bot)     { adapter.instance_variable_get(:@bot) }

  before do
    allow(bot).to receive(:tenant_access_token).and_return("fake_token")
  end

  # -------------------------------------------------------------------------
  # Private helpers: image_file? and feishu_file_type
  # -------------------------------------------------------------------------
  describe "file type helpers" do
    it "identifies image extensions" do
      %w[photo.jpg photo.jpeg pic.PNG banner.gif icon.webp thumb.heic].each do |f|
        expect(adapter.send(:image_file?, f)).to be(true), "#{f} should be an image"
      end
    end

    it "does not treat non-images as images" do
      %w[report.pdf video.mp4 voice.opus doc.docx].each do |f|
        expect(adapter.send(:image_file?, f)).to be(false), "#{f} should NOT be an image"
      end
    end

    it "maps extensions to Feishu file types" do
      expect(adapter.send(:feishu_file_type, "voice.opus")).to eq("opus")
      expect(adapter.send(:feishu_file_type, "clip.mp4")).to   eq("mp4")
      expect(adapter.send(:feishu_file_type, "slide.pptx")).to eq("ppt")
      expect(adapter.send(:feishu_file_type, "data.xlsx")).to  eq("xls")
      expect(adapter.send(:feishu_file_type, "report.pdf")).to eq("pdf")
      expect(adapter.send(:feishu_file_type, "file.bin")).to   eq("stream")
    end
  end

  # -------------------------------------------------------------------------
  # parse_ogg_duration
  # -------------------------------------------------------------------------
  describe "#parse_ogg_duration" do
    it "returns nil for non-OGG data" do
      expect(adapter.send(:parse_ogg_duration, "not ogg data")).to be_nil
    end

    it "returns nil for empty data" do
      expect(adapter.send(:parse_ogg_duration, "")).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # parse_mp4_duration
  # -------------------------------------------------------------------------
  describe "#parse_mp4_duration" do
    it "returns nil for non-MP4 data" do
      expect(adapter.send(:parse_mp4_duration, "not mp4 data")).to be_nil
    end

    it "returns nil for empty data" do
      expect(adapter.send(:parse_mp4_duration, "")).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # send_file routing
  # -------------------------------------------------------------------------
  describe "#send_file" do
    let(:chat_id) { "oc_chat_test" }

    context "with an image file" do
      it "uploads as image and sends image message" do
        Tempfile.create(["photo", ".jpg"]) do |f|
          f.write("fake_jpeg_data")
          f.flush

          expect(bot).to receive(:upload_image).with(anything, "photo.jpg").and_return("img_key_001")
          expect(bot).to receive(:send_image).with(chat_id, "img_key_001", reply_to: nil)

          adapter.send_file(chat_id, f.path, name: "photo.jpg")
        end
      end

      it "passes reply_to when provided" do
        Tempfile.create(["banner", ".png"]) do |f|
          f.write("png_data")
          f.flush

          allow(bot).to receive(:upload_image).and_return("img_key_002")
          expect(bot).to receive(:send_image).with(chat_id, "img_key_002", reply_to: "om_reply_123")

          adapter.send_file(chat_id, f.path, name: "banner.png", reply_to: "om_reply_123")
        end
      end
    end

    context "with a PDF file" do
      it "uploads as 'pdf' type and sends file message" do
        Tempfile.create(["report", ".pdf"]) do |f|
          f.write("pdf_binary")
          f.flush

          expect(bot).to receive(:upload_file).with(anything, "report.pdf", "pdf", duration: nil).and_return("file_key_pdf")
          expect(bot).to receive(:send_file_message).with(chat_id, "file_key_pdf", reply_to: nil)

          adapter.send_file(chat_id, f.path, name: "report.pdf")
        end
      end
    end

    context "with an opus audio file" do
      it "uploads as 'opus' type and sends audio message" do
        Tempfile.create(["voice", ".opus"]) do |f|
          f.write("fake_opus_binary")
          f.flush

          allow(adapter).to receive(:parse_ogg_duration).and_return(3000)
          expect(bot).to receive(:upload_file).with(anything, "voice.opus", "opus", duration: 3000).and_return("file_key_opus")
          expect(bot).to receive(:send_audio).with(chat_id, "file_key_opus", reply_to: nil)

          adapter.send_file(chat_id, f.path, name: "voice.opus")
        end
      end
    end

    context "with an MP4 video file" do
      it "uploads as 'mp4' type and sends video message" do
        Tempfile.create(["clip", ".mp4"]) do |f|
          f.write("fake_mp4_binary")
          f.flush

          allow(adapter).to receive(:parse_mp4_duration).and_return(15000)
          expect(bot).to receive(:upload_file).with(anything, "clip.mp4", "mp4", duration: 15000).and_return("file_key_mp4")
          expect(bot).to receive(:send_video).with(chat_id, "file_key_mp4", reply_to: nil)

          adapter.send_file(chat_id, f.path, name: "clip.mp4")
        end
      end
    end

    context "with an unknown file type" do
      it "uploads as 'stream' and sends file message" do
        Tempfile.create(["data", ".bin"]) do |f|
          f.write("binary_data")
          f.flush

          expect(bot).to receive(:upload_file).with(anything, "data.bin", "stream", duration: nil).and_return("file_key_bin")
          expect(bot).to receive(:send_file_message).with(chat_id, "file_key_bin", reply_to: nil)

          adapter.send_file(chat_id, f.path, name: "data.bin")
        end
      end
    end

    context "when name is omitted" do
      it "infers filename from path" do
        Tempfile.create(["document", ".docx"]) do |f|
          f.write("docx_data")
          f.flush

          inferred_name = File.basename(f.path)
          expect(bot).to receive(:upload_file).with(anything, inferred_name, "doc", duration: nil).and_return("fk")
          allow(bot).to receive(:send_file_message)

          adapter.send_file(chat_id, f.path)
        end
      end
    end
  end
end
