# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"

module Clacky
  module Channel
    module Adapters
      module DingTalk
        # DingTalk Bot API client — sends messages via session webhook (Stream Mode).
        class ApiClient
          OPENAPI_BASE = "https://api.dingtalk.com"
          OAPI_BASE    = "https://oapi.dingtalk.com"

          # File extensions accepted by DingTalk sampleFile message (fileType field).
          # Anything outside this list is rejected by DingTalk's API — we surface
          # a friendly text notice to the user instead of attempting upload.
          #
          # Why 9 entries instead of the 6 the public doc lists? The official
          # doc (open.dingtalk.com / sampleFile) explicitly names only:
          #   xlsx, pdf, zip, rar, doc, docx
          # However old-format Office types (xls / ppt / pptx) are accepted in
          # practice and were verified by hand during the C-5597 rollout.
          # We deliberately keep the empirical 9-entry list because
          # downgrading to the doc's 6 would silently reject files users
          # routinely send. If DingTalk ever tightens enforcement and the
          # extra 3 start failing, prefer adding a converter (e.g. xls→xlsx)
          # over shrinking the list — the goal is "things users send arrive".
          SUPPORTED_FILE_EXTS = %w[doc docx xls xlsx ppt pptx pdf zip rar].freeze

          def initialize(client_id:, client_secret:)
            @client_id     = client_id
            @client_secret = client_secret
            @token         = nil
            @token_expires_at = 0
            @oapi_token    = nil
            @oapi_token_expires_at = 0
          end

          # Send a text (or Markdown) message via the session webhook URL.
          # In Stream Mode, inbound events carry a `sessionWebhook` — use that directly.
          # @param webhook_url [String]
          # @param text [String]
          # @param msg_type [:text, :markdown] (default :text)
          def send_via_webhook(webhook_url, text, msg_type: :text)
            body = if msg_type == :markdown
              { msgtype: "markdown", markdown: { title: "Reply", text: text } }
            else
              { msgtype: "text", text: { content: text } }
            end

            uri = URI.parse(webhook_url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
            req.body = JSON.generate(body)
            resp = http.request(req)
            data = JSON.parse(resp.body) rescue {}
            if resp.code.to_i != 200 || (data["errcode"] && data["errcode"] != 0)
              Clacky::Logger.warn("[dingtalk] webhook send rejected (#{resp.code}): #{resp.body}")
            end
            data
          rescue => e
            Clacky::Logger.warn("[dingtalk] webhook send failed: #{e.message}")
            {}
          end

          # Fetch a short-lived access token (cached for its lifetime).
          def access_token
            return @token if @token && Time.now.to_i < @token_expires_at - 60

            uri  = URI.parse("#{OPENAPI_BASE}/v1.0/oauth2/accessToken")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            req = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
            req.body = JSON.generate({ appKey: @client_id, appSecret: @client_secret })

            resp = http.request(req)
            data = JSON.parse(resp.body)

            raise "DingTalk token error (#{resp.code}): #{data["message"] || resp.body}" unless resp.code.to_i == 200

            @token = data["accessToken"] || raise("Missing accessToken in response")
            @token_expires_at = Time.now.to_i + (data["expireIn"] || 7200).to_i
            @token
          end

          # OAPI access token — required by legacy /media/upload endpoint.
          # Independent token system from /v1.0/oauth2/accessToken.
          def oapi_access_token
            return @oapi_token if @oapi_token && Time.now.to_i < @oapi_token_expires_at - 60

            uri = URI.parse("#{OAPI_BASE}/gettoken?appkey=#{@client_id}&appsecret=#{@client_secret}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            resp = http.request(Net::HTTP::Get.new(uri.request_uri))
            data = JSON.parse(resp.body)

            unless resp.code.to_i == 200 && data["errcode"].to_i.zero? && data["access_token"]
              raise "DingTalk OAPI token error (#{resp.code}): #{data["errmsg"] || resp.body}"
            end

            @oapi_token = data["access_token"]
            @oapi_token_expires_at = Time.now.to_i + (data["expires_in"] || 7200).to_i
            @oapi_token
          end

          # Validate credentials by fetching a token.
          # @return [Hash] { ok: Boolean, error: String? }
          def test_connection
            access_token
            { ok: true, message: "DingTalk access token obtained" }
          rescue => e
            { ok: false, error: e.message }
          end

          # Download a file the bot received, given its downloadCode + robotCode
          # from the inbound event. Two-step: exchange downloadCode for a temporary
          # downloadUrl, then persist bytes to UPLOAD_DIR via FileProcessor.save.
          # @param download_code [String]
          # @param robot_code [String]
          # @param prefer_name [String, nil] original filename from inbound event
          #   (DingTalk's content.fileName) — used to pick the file extension so
          #   downstream consumers (parsers, vision models) route by suffix correctly.
          # @return [Hash, nil] { name:, path:, mime: } or nil on failure
          def download_message_file(download_code, robot_code, prefer_name: nil)
            return nil if download_code.to_s.empty? || robot_code.to_s.empty?

            url = fetch_download_url(download_code, robot_code)
            return nil unless url

            download_to_disk(url, prefer_name: prefer_name)
          rescue => e
            Clacky::Logger.warn("[dingtalk] download_message_file failed: #{e.message}")
            nil
          end

          private def fetch_download_url(download_code, robot_code)
            uri  = URI.parse("#{OPENAPI_BASE}/v1.0/robot/messageFiles/download")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            req = Net::HTTP::Post.new(uri.path,
              "Content-Type"                => "application/json",
              "x-acs-dingtalk-access-token" => access_token)
            req.body = JSON.generate(downloadCode: download_code, robotCode: robot_code)
            resp = http.request(req)
            data = JSON.parse(resp.body) rescue {}
            unless resp.code.to_i == 200 && data["downloadUrl"]
              Clacky::Logger.warn("[dingtalk] fetch_download_url rejected (#{resp.code}): #{resp.body}")
              return nil
            end
            data["downloadUrl"]
          end

          private def download_to_disk(url, prefer_name: nil)
            uri  = URI.parse(url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            resp = http.get(uri.request_uri)
            return nil unless resp.code.to_i == 200

            mime = resp["content-type"].to_s
            # Prefer extension from the original fileName supplied by DingTalk
            # (e.g. report.pdf, notes.txt). Fall back to MIME mapping, then .bin.
            ext  = ext_from_name(prefer_name) || guess_ext(mime) || ".bin"

            base     = prefer_name && !prefer_name.to_s.empty? ?
                         File.basename(prefer_name.to_s, ".*") : "dingtalk"
            base     = sanitize_basename(base)
            filename = "#{base}-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}#{ext}"
            saved    = Clacky::Utils::FileProcessor.save(body: resp.body, filename: filename)
            saved.merge(mime: mime)
          end

          private def ext_from_name(name)
            return nil if name.to_s.empty?
            ext = File.extname(name.to_s).downcase
            ext.empty? ? nil : ext
          end

          private def sanitize_basename(name)
            # Keep ASCII letters/digits/dash/underscore; drop everything else
            # (CJK, spaces, slashes) so the final filename stays filesystem-safe.
            cleaned = name.to_s.gsub(/[^A-Za-z0-9_\-]/, "_").gsub(/_+/, "_").gsub(/^_+|_+$/, "")
            cleaned.empty? ? "dingtalk" : cleaned
          end

          private def guess_ext(mime)
            case mime.to_s.split(";").first.to_s.strip.downcase
            # Images
            when "image/jpeg", "image/jpg" then ".jpg"
            when "image/png"               then ".png"
            when "image/gif"               then ".gif"
            when "image/webp"              then ".webp"
            when "image/bmp"               then ".bmp"
            when "image/svg+xml"           then ".svg"
            # Documents
            when "application/pdf"         then ".pdf"
            when "application/msword"      then ".doc"
            when "application/vnd.openxmlformats-officedocument.wordprocessingml.document" then ".docx"
            when "application/vnd.ms-excel" then ".xls"
            when "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" then ".xlsx"
            when "application/vnd.ms-powerpoint" then ".ppt"
            when "application/vnd.openxmlformats-officedocument.presentationml.presentation" then ".pptx"
            # Archives
            when "application/zip"         then ".zip"
            when "application/x-rar-compressed", "application/vnd.rar" then ".rar"
            when "application/x-7z-compressed" then ".7z"
            when "application/x-tar"       then ".tar"
            when "application/gzip"        then ".gz"
            # Text
            when "text/plain"              then ".txt"
            when "text/markdown"           then ".md"
            when "text/csv"                then ".csv"
            when "text/html"               then ".html"
            when "application/json"        then ".json"
            when "application/xml", "text/xml" then ".xml"
            when "application/x-yaml", "text/yaml" then ".yml"
            # Audio / video
            when "audio/mpeg"              then ".mp3"
            when "audio/wav", "audio/x-wav" then ".wav"
            when "audio/aac"               then ".aac"
            when "audio/ogg"               then ".ogg"
            when "video/mp4"               then ".mp4"
            when "video/quicktime"         then ".mov"
            end
          end

          # Upload a local file to DingTalk and return its media_id.
          # Webhook delivery doesn't support image/file attachments — uploaded
          # mediaId is used by the OAPI sendMessage path below.
          # @param path [String]
          # @param kind [Symbol] :image | :file
          # @return [String, nil] media_id
          def upload_media(path, kind:)
            type_str = kind == :image ? "image" : "file"
            # NB: legacy OAPI /media/upload — the new /v1.0/robot/messageFiles/*
            # path returns 404, this is the only working endpoint as of 2026-05.
            token    = oapi_access_token
            uri      = URI.parse("#{OAPI_BASE}/media/upload?access_token=#{token}&type=#{type_str}")
            boundary = "----DingTalkBoundary#{rand(1 << 64).to_s(16)}"
            body     = build_multipart(path, boundary, type_str)

            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            req = Net::HTTP::Post.new(uri.request_uri,
              "Content-Type" => "multipart/form-data; boundary=#{boundary}")
            req.body = body
            resp = http.request(req)
            data = JSON.parse(resp.body) rescue {}
            unless resp.code.to_i == 200 && data["errcode"].to_i.zero? && data["media_id"]
              Clacky::Logger.warn("[dingtalk] upload_media rejected (#{resp.code}): #{resp.body}")
              return nil
            end
            # Operational log: confirm upload succeeded and surface the
            # media_id shape (length + first 4 chars). We keep this at info
            # level because outbound failures correlate strongly with
            # media_id format drift (e.g. DingTalk silently changing the
            # `@` prefix policy). Avoid logging the full body to keep the
            # token / id from leaking into shared log channels.
            mid = data["media_id"].to_s
            Clacky::Logger.info("[dingtalk] upload_media ok type=#{type_str} media_id_len=#{mid.length} media_id_prefix=#{mid[0, 4].inspect}")
            mid
          rescue => e
            Clacky::Logger.warn("[dingtalk] upload_media failed: #{e.message}")
            nil
          end

          # Send a media message via OAPI (not webhook).
          # DM    → /v1.0/robot/oToMessages/batchSend (needs userIds)
          # Group → /v1.0/robot/groupMessages/send   (needs openConversationId)
          # @param conv_type [String] "1"=DM, "2"=group
          # @param kind [Symbol] :image | :file
          def send_media(robot_code:, conv_type:, conv_id:, user_id:, media_id:, kind:, file_name: nil)
            msg_key, msg_param = build_media_message(media_id, kind, file_name)

            if conv_type == "2"
              path = "/v1.0/robot/groupMessages/send"
              body = {
                msgKey:             msg_key,
                msgParam:           JSON.generate(msg_param),
                openConversationId: conv_id,
                robotCode:          robot_code
              }
            else
              path = "/v1.0/robot/oToMessages/batchSend"
              body = {
                msgKey:    msg_key,
                msgParam:  JSON.generate(msg_param),
                userIds:   [user_id],
                robotCode: robot_code
              }
            end

            uri  = URI.parse("#{OPENAPI_BASE}#{path}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            req = Net::HTTP::Post.new(uri.request_uri,
              "Content-Type"                => "application/json",
              "x-acs-dingtalk-access-token" => access_token)
            req.body = JSON.generate(body)
            resp = http.request(req)
            data = JSON.parse(resp.body) rescue {}
            if resp.code.to_i != 200
              Clacky::Logger.warn("[dingtalk] send_media rejected (#{resp.code}): #{resp.body}")
              return { ok: false, error: data["message"] || resp.body }
            end
            # Operational log: success path. We log msgKey (image vs file)
            # so the operator can correlate "sampleImageMsg" with image
            # delivery and "sampleFile" with file delivery without parsing
            # the full request body.
            Clacky::Logger.info("[dingtalk] send_media ok kind=#{kind} msgKey=#{msg_key}")
            { ok: true, data: data }
          rescue => e
            Clacky::Logger.warn("[dingtalk] send_media failed: #{e.message}")
            { ok: false, error: e.message }
          end

          private def build_media_message(media_id, kind, file_name)
            # Images: `sampleImageMsg` with the OAPI-uploaded mediaId (type=image)
            # renders an inline original-resolution image in the chat. The doc
            # field is named `photoURL`, but DingTalk explicitly documents that
            # photoURL accepts either a public URL OR a mediaId — and the
            # mediaId form is what we use (the only way to send local files
            # without standing up a public file server).
            #
            # NOTE — implementation pitfalls hard-won (2026-05-19):
            #   1. Pass the raw mediaId returned by /media/upload AS-IS.
            #      Despite the sampleLink doc example showing `picUrl: "@lADO..."`
            #      with an `@` prefix, sampleImageMsg.photoURL must NOT be
            #      prefixed — the upload response already includes whatever
            #      shape DingTalk wants. Adding `@` produces "原图加载失败".
            #   2. msgKey is `sampleImageMsg`, NOT `msgtype: "image"`.
            #      `msgtype:image` belongs to the corpconversation/asyncsend_v2
            #      work-notification protocol and does NOT work on the group
            #      robot endpoint we use here.
            #   3. msgParam must be a JSON-stringified object (handled by the
            #      caller), not a nested hash.
            return ["sampleImageMsg", { photoURL: media_id }] if kind == :image

            # Generic files: sampleFile. fileType must be one of
            # SUPPORTED_FILE_EXTS (see top of file for why we keep the
            # empirically-verified 9-entry list rather than the 6-entry
            # doc list). Upstream `Adapter#send_file` already screens out
            # unsupported extensions before we reach here, so we just pass
            # `ext` through.
            ext = File.extname(file_name.to_s).delete(".")
            ["sampleFile", { mediaId: media_id, fileName: file_name.to_s, fileType: ext }]
          end

          private def build_multipart(path, boundary, type_str)
            filename = File.basename(path)
            mime     = mime_for(filename)
            content  = File.binread(path)

            # All parts must be ASCII-8BIT before joining; mixing UTF-8 (e.g. a
            # filename with CJK chars) with binary file content raises
            # "incompatible character encodings: UTF-8 and BINARY".
            parts = []
            parts << "--#{boundary}\r\n".b
            parts << "Content-Disposition: form-data; name=\"type\"\r\n\r\n#{type_str}\r\n".b
            parts << "--#{boundary}\r\n".b
            parts << "Content-Disposition: form-data; name=\"media\"; filename=\"#{filename}\"\r\n".b
            parts << "Content-Type: #{mime}\r\n\r\n".b
            parts << content.b
            parts << "\r\n--#{boundary}--\r\n".b
            parts.join
          end

          private def mime_for(filename)
            case File.extname(filename).downcase
            when ".jpg", ".jpeg" then "image/jpeg"
            when ".png"          then "image/png"
            when ".gif"          then "image/gif"
            when ".webp"         then "image/webp"
            when ".txt", ".log"  then "text/plain"
            when ".md"           then "text/markdown"
            when ".pdf"          then "application/pdf"
            when ".json"         then "application/json"
            when ".csv"          then "text/csv"
            when ".zip"          then "application/zip"
            else                       "application/octet-stream"
            end
          end
        end
      end
    end
  end
end
