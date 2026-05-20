# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel/adapters/dingtalk/api_client"

RSpec.describe Clacky::Channel::Adapters::DingTalk::ApiClient do
  let(:client) { described_class.new(client_id: "cid", client_secret: "secret") }

  before do
    # Stub access_token to avoid hitting real network
    allow(client).to receive(:access_token).and_return("AT-stub")
    allow(client).to receive(:oapi_access_token).and_return("OAPI-stub")
  end

  # Build a Net::HTTPResponse-like double whose body / code can be controlled.
  def fake_response(code:, body:, headers: {})
    resp = instance_double(Net::HTTPResponse)
    allow(resp).to receive(:code).and_return(code.to_s)
    allow(resp).to receive(:body).and_return(body)
    headers.each { |k, v| allow(resp).to receive(:[]).with(k).and_return(v) }
    allow(resp).to receive(:[]).and_return(nil) unless headers.any?
    resp
  end

  describe "#send_via_webhook (C-5596)" do
    let(:webhook) { "https://oapi.dingtalk.com/robot/send?access_token=xxx" }

    it "builds markdown body with title + text when msg_type is :markdown" do
      captured = nil
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        captured = JSON.parse(req.body)
        fake_response(code: 200, body: '{"errcode":0}')
      end

      client.send_via_webhook(webhook, "# Hi\n**bold**", msg_type: :markdown)
      expect(captured["msgtype"]).to eq("markdown")
      expect(captured["markdown"]["title"]).to eq("Reply")
      expect(captured["markdown"]["text"]).to eq("# Hi\n**bold**")
    end

    it "builds text body when msg_type is :text" do
      captured = nil
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        captured = JSON.parse(req.body)
        fake_response(code: 200, body: '{"errcode":0}')
      end

      client.send_via_webhook(webhook, "plain", msg_type: :text)
      expect(captured["msgtype"]).to eq("text")
      expect(captured["text"]["content"]).to eq("plain")
    end
  end

  describe "#download_message_file (C-5598)" do
    it "exchanges downloadCode for downloadUrl then persists bytes to UPLOAD_DIR" do
      call_count = 0
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, _req|
        call_count += 1
        fake_response(code: 200, body: JSON.generate(downloadUrl: "https://cdn.example/x.png"))
      end
      allow_any_instance_of(Net::HTTP).to receive(:get) do |_http, _path|
        fake_response(code: 200, body: "PNGDATA", headers: { "content-type" => "image/png" })
      end

      result = client.download_message_file("DC-1", "robot-1")
      expect(result).not_to be_nil
      expect(result[:mime]).to eq("image/png")
      expect(result[:name]).to match(/\Adingtalk-\d{8}-\d{6}-[0-9a-f]{6}\.png\z/)
      expect(File.exist?(result[:path])).to be(true)
      expect(File.read(result[:path])).to eq("PNGDATA")
    end

    it "preserves the original filename's extension when prefer_name is supplied" do
      allow_any_instance_of(Net::HTTP).to receive(:request)
        .and_return(fake_response(code: 200, body: JSON.generate(downloadUrl: "https://cdn.example/x")))
      allow_any_instance_of(Net::HTTP).to receive(:get)
        .and_return(fake_response(code: 200, body: "PDFDATA",
                                  headers: { "content-type" => "application/pdf" }))

      result = client.download_message_file("DC-2", "robot-1", prefer_name: "report.pdf")
      expect(result[:name]).to end_with(".pdf")
      expect(result[:name]).to start_with("report-")
    end

    it "preserves the .txt extension for non-whitelist files (no .bin downgrade)" do
      allow_any_instance_of(Net::HTTP).to receive(:request)
        .and_return(fake_response(code: 200, body: JSON.generate(downloadUrl: "https://cdn.example/x")))
      allow_any_instance_of(Net::HTTP).to receive(:get)
        .and_return(fake_response(code: 200, body: "hello",
                                  headers: { "content-type" => "text/plain" }))

      result = client.download_message_file("DC-3", "robot-1", prefer_name: "notes.txt")
      expect(result[:name]).to end_with(".txt")
    end

    it "falls back to MIME-based extension when prefer_name is nil" do
      allow_any_instance_of(Net::HTTP).to receive(:request)
        .and_return(fake_response(code: 200, body: JSON.generate(downloadUrl: "https://cdn.example/x")))
      allow_any_instance_of(Net::HTTP).to receive(:get)
        .and_return(fake_response(code: 200, body: "PDFDATA",
                                  headers: { "content-type" => "application/pdf" }))

      result = client.download_message_file("DC-4", "robot-1")
      expect(result[:name]).to end_with(".pdf")
    end

    it "sanitizes CJK / spaces in basename to keep filesystem-safe filenames" do
      allow_any_instance_of(Net::HTTP).to receive(:request)
        .and_return(fake_response(code: 200, body: JSON.generate(downloadUrl: "https://cdn.example/x")))
      allow_any_instance_of(Net::HTTP).to receive(:get)
        .and_return(fake_response(code: 200, body: "x",
                                  headers: { "content-type" => "application/pdf" }))

      result = client.download_message_file("DC-5", "robot-1", prefer_name: "我的 报告.pdf")
      expect(result[:name]).to end_with(".pdf")
      # basename portion should not contain CJK / spaces
      expect(result[:name]).not_to match(/[\u4e00-\u9fff ]/)
    end

    it "returns nil on missing downloadUrl" do
      allow_any_instance_of(Net::HTTP).to receive(:request)
        .and_return(fake_response(code: 200, body: '{"errcode":40000}'))
      expect(client.download_message_file("DC-X", "robot-1")).to be_nil
    end

    it "returns nil on empty downloadCode" do
      expect(client.download_message_file("", "robot-1")).to be_nil
    end

    it "returns nil on empty robotCode" do
      expect(client.download_message_file("DC-X", "")).to be_nil
    end
  end

  describe "#guess_ext (private)" do
    it "maps common image mime types" do
      expect(client.send(:guess_ext, "image/jpeg")).to eq(".jpg")
      expect(client.send(:guess_ext, "image/png")).to  eq(".png")
      expect(client.send(:guess_ext, "image/gif")).to  eq(".gif")
      expect(client.send(:guess_ext, "image/webp")).to eq(".webp")
    end

    it "maps document mime types" do
      expect(client.send(:guess_ext, "application/pdf")).to eq(".pdf")
      expect(client.send(:guess_ext, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")).to eq(".docx")
      expect(client.send(:guess_ext, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")).to eq(".xlsx")
    end

    it "maps text and archive mime types" do
      expect(client.send(:guess_ext, "text/plain")).to eq(".txt")
      expect(client.send(:guess_ext, "application/json")).to eq(".json")
      expect(client.send(:guess_ext, "application/zip")).to eq(".zip")
    end

    it "tolerates charset suffix in Content-Type header" do
      expect(client.send(:guess_ext, "text/plain; charset=utf-8")).to eq(".txt")
    end

    it "returns nil for unknown mime" do
      expect(client.send(:guess_ext, "application/x-something-novel")).to be_nil
    end
  end

  describe "#mime_for (private)" do
    it "maps image extensions" do
      expect(client.send(:mime_for, "a.png")).to  eq("image/png")
      expect(client.send(:mime_for, "a.jpg")).to  eq("image/jpeg")
      expect(client.send(:mime_for, "a.jpeg")).to eq("image/jpeg")
      expect(client.send(:mime_for, "a.gif")).to  eq("image/gif")
      expect(client.send(:mime_for, "a.webp")).to eq("image/webp")
    end

    it "falls back to octet-stream for unknown" do
      expect(client.send(:mime_for, "a.bin")).to eq("application/octet-stream")
    end
  end

  describe "#build_media_message (private)" do
    it "produces sampleImageMsg with photoURL=mediaId for :image (renders inline thumbnail)" do
      key, param = client.send(:build_media_message, "media-1", :image, "x.png")
      expect(key).to eq("sampleImageMsg")
      expect(param).to eq(photoURL: "media-1")
    end

    it "produces sampleFile with mediaId/fileName/fileType for :file" do
      key, param = client.send(:build_media_message, "media-2", :file, "report.pdf")
      expect(key).to eq("sampleFile")
      expect(param).to eq(mediaId: "media-2", fileName: "report.pdf", fileType: "pdf")
    end
  end

  describe "#build_multipart (private)" do
    let(:tempfile) do
      f = Tempfile.new(["up-", ".png"])
      f.write("\x89PNG fake")
      f.close
      f
    end

    it "includes the type field, media field, and file content" do
      body = client.send(:build_multipart, tempfile.path, "BOUND", "image")
      expect(body).to include('name="type"')
      expect(body).to include('image')
      expect(body).to include('name="media"')
      expect(body.b).to include("\x89PNG fake".b)
      expect(body).to include("--BOUND--")
    end

    # Regression: filenames with non-ASCII chars (e.g. CJK) used to crash
    # build_multipart with "incompatible character encodings: UTF-8 and BINARY"
    # because UTF-8 string parts were joined with a binary file body.
    it "handles UTF-8 filenames with binary content (no encoding crash)" do
      utf8_file = Tempfile.new(["一些api key-", ".txt"])
      utf8_file.binmode
      utf8_file.write("\x00\x01binary\xFF\xFE".b)
      utf8_file.close
      expect {
        client.send(:build_multipart, utf8_file.path, "BOUND", "file")
      }.not_to raise_error
    end
  end

  describe "#upload_media (C-5597)" do
    let(:tempfile) do
      f = Tempfile.new(["up-", ".png"])
      f.write("\x89PNG fake")
      f.close
      f
    end

    it "POSTs multipart to OAPI /media/upload and returns media_id on success" do
      captured_uri = nil
      captured     = nil
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        captured_uri = req.path
        captured     = req
        fake_response(code: 200, body: '{"errcode":0,"media_id":"media-abc","type":"image"}')
      end

      expect(client.upload_media(tempfile.path, kind: :image)).to eq("media-abc")
      expect(captured_uri).to start_with("/media/upload")
      expect(captured_uri).to include("access_token=OAPI-stub")
      expect(captured_uri).to include("type=image")
      expect(captured["Content-Type"]).to start_with("multipart/form-data")
      expect(captured["x-acs-dingtalk-access-token"]).to be_nil
      expect(captured.body).to include('name="media"')
    end

    it "returns nil on rejection" do
      allow_any_instance_of(Net::HTTP).to receive(:request)
        .and_return(fake_response(code: 200, body: '{"errcode":40078,"errmsg":"invalid type"}'))
      expect(client.upload_media(tempfile.path, kind: :image)).to be_nil
    end
  end

  describe "#send_media (C-5597)" do
    it "uses oToMessages/batchSend for DM (conv_type=1)" do
      captured_uri  = nil
      captured_body = nil
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        captured_uri  = req.path
        captured_body = JSON.parse(req.body)
        fake_response(code: 200, body: '{"processQueryKey":"q"}')
      end

      result = client.send_media(
        robot_code: "robot-1", conv_type: "1",
        conv_id:    "conv-1",  user_id:   "user-1",
        media_id:   "media-xyz", kind: :file, file_name: "report.pdf"
      )
      expect(result[:ok]).to eq(true)
      expect(captured_uri).to eq("/v1.0/robot/oToMessages/batchSend")
      expect(captured_body["msgKey"]).to eq("sampleFile")
      expect(captured_body["userIds"]).to eq(["user-1"])
      expect(captured_body["robotCode"]).to eq("robot-1")
      expect(JSON.parse(captured_body["msgParam"])["mediaId"]).to eq("media-xyz")
    end

    it "uses groupMessages/send for group (conv_type=2)" do
      captured_uri  = nil
      captured_body = nil
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        captured_uri  = req.path
        captured_body = JSON.parse(req.body)
        fake_response(code: 200, body: '{}')
      end

      client.send_media(
        robot_code: "robot-1", conv_type: "2",
        conv_id:    "conv-1",  user_id:   "user-1",
        media_id:   "media-xyz", kind: :file, file_name: "report.pdf"
      )
      expect(captured_uri).to eq("/v1.0/robot/groupMessages/send")
      expect(captured_body["openConversationId"]).to eq("conv-1")
      expect(captured_body["msgKey"]).to eq("sampleFile")
    end

    it "uses sampleFile msgKey for non-image kind" do
      captured_body = nil
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        captured_body = JSON.parse(req.body)
        fake_response(code: 200, body: '{}')
      end

      client.send_media(
        robot_code: "robot-1", conv_type: "1",
        conv_id:    "conv-1",  user_id:   "user-1",
        media_id:   "media-doc", kind: :file, file_name: "report.pdf"
      )
      msg_param = JSON.parse(captured_body["msgParam"])
      expect(captured_body["msgKey"]).to eq("sampleFile")
      expect(msg_param["mediaId"]).to eq("media-doc")
      expect(msg_param["fileName"]).to eq("report.pdf")
      expect(msg_param["fileType"]).to eq("pdf")
    end

    it "uses sampleImageMsg msgKey for :image kind (renders inline preview)" do
      captured_body = nil
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
        captured_body = JSON.parse(req.body)
        fake_response(code: 200, body: '{}')
      end

      client.send_media(
        robot_code: "robot-1", conv_type: "1",
        conv_id:    "conv-1",  user_id:   "user-1",
        media_id:   "media-img", kind: :image, file_name: "shot.png"
      )
      msg_param = JSON.parse(captured_body["msgParam"])
      expect(captured_body["msgKey"]).to eq("sampleImageMsg")
      expect(msg_param["photoURL"]).to eq("media-img")
    end

    it "returns ok=false on non-200 response" do
      allow_any_instance_of(Net::HTTP).to receive(:request)
        .and_return(fake_response(code: 500, body: '{"message":"server err"}'))

      result = client.send_media(
        robot_code: "robot-1", conv_type: "1",
        conv_id:    "conv-1",  user_id:   "user-1",
        media_id:   "media-xyz", kind: :image
      )
      expect(result[:ok]).to eq(false)
    end
  end
end
