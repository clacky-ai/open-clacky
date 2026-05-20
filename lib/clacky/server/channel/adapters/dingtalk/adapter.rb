# frozen_string_literal: true

require_relative "../../adapters/base"
require_relative "stream_client"
require_relative "api_client"

module Clacky
  module Channel
    module Adapters
      module DingTalk
        class Adapter < Base
          def self.platform_id
            :dingtalk
          end

          def self.env_keys
            %w[IM_DINGTALK_CLIENT_ID IM_DINGTALK_CLIENT_SECRET IM_DINGTALK_ALLOWED_USERS]
          end

          def self.platform_config(data)
            {
              client_id:     data["IM_DINGTALK_CLIENT_ID"],
              client_secret: data["IM_DINGTALK_CLIENT_SECRET"],
              allowed_users: data["IM_DINGTALK_ALLOWED_USERS"]&.split(",")&.map(&:strip)&.reject(&:empty?)
            }
          end

          def self.set_env_data(data, config)
            data["IM_DINGTALK_CLIENT_ID"]     = config[:client_id]
            data["IM_DINGTALK_CLIENT_SECRET"]  = config[:client_secret]
            data["IM_DINGTALK_ALLOWED_USERS"]  = Array(config[:allowed_users]).join(",")
          end

          def self.test_connection(fields)
            client = ApiClient.new(
              client_id:     fields[:client_id].to_s.strip,
              client_secret: fields[:client_secret].to_s.strip
            )
            client.test_connection
          rescue => e
            { ok: false, error: e.message }
          end

          def initialize(config)
            @config        = config
            @api_client    = ApiClient.new(
              client_id:     config[:client_id],
              client_secret: config[:client_secret]
            )
            @stream_client = nil
            @running       = false
            # chat_id => { url:, expires_at_ms: } — sessionWebhook is per-message
            # and expires (~2h). We cache it from inbound events and validate on send.
            @webhook_urls  = {}
            @webhook_mutex = Mutex.new
            # chat_id => { robot_code:, conv_id:, user_id:, conv_type: } — needed
            # to route OAPI calls (e.g. send_file) which can't go through webhook.
            @routes        = {}
            @routes_mutex  = Mutex.new
          end

          WEBHOOK_SAFETY_MARGIN_MS = 5 * 60 * 1000

          def start(&on_message)
            @running    = true
            @on_message = on_message

            @stream_client = StreamClient.new(
              client_id:     @config[:client_id],
              client_secret: @config[:client_secret]
            )
            @stream_client.start { |frame| handle_frame(frame) }
          end

          def stop
            @running = false
            @stream_client&.stop
          end

          # @param chat_id [String] — for DingTalk Stream Mode, chat_id == webhook URL
          # Always sent as markdown so AI replies render rich text (headings,
          # bold, lists, links). DingTalk's markdown msgtype renders plain text
          # unchanged, so no detection branch is needed.
          def send_text(chat_id, text, reply_to: nil)
            webhook_url = resolve_webhook(chat_id)
            unless webhook_url
              Clacky::Logger.warn("[dingtalk] no valid sessionWebhook for chat #{chat_id} (expired or never received)")
              return { ok: false, error: "session_webhook_expired" }
            end
            @api_client.send_via_webhook(webhook_url, text, msg_type: :markdown)
          end

          # Send a local file (image or generic file) as a native attachment.
          # Webhook can't deliver attachments — use OAPI sendMessage with mediaId.
          # @param chat_id [String]
          # @param path [String] local file path
          # @param name [String, nil] display filename (not used by image msg)
          def send_file(chat_id, path, name: nil, reply_to: nil)
            unless File.exist?(path)
              Clacky::Logger.warn("[dingtalk] send_file: file not found #{path}")
              return { ok: false, error: "file_not_found" }
            end

            route = resolve_route(chat_id)
            unless route
              Clacky::Logger.warn("[dingtalk] send_file: no routing info for chat #{chat_id}")
              return { ok: false, error: "no_route" }
            end

            kind = image_file?(path) ? :image : :file

            # Non-image files outside DingTalk's accepted extension list
            # (sampleFile rejects anything not in SUPPORTED_FILE_EXTS).
            # Surface the failure directly to the user in the chat,
            # disguised as a DingTalk system message so it's clear the
            # restriction comes from the IM platform, not us.
            if kind == :file && !supported_file?(path)
              ext = File.extname(path).delete_prefix(".").downcase
              display_name = name || File.basename(path)
              Clacky::Logger.info("[dingtalk] send_file: unsupported extension .#{ext} (#{display_name})")
              supported_list = ApiClient::SUPPORTED_FILE_EXTS.map { |e| ".#{e}" }.join(", ")
              send_text(
                chat_id,
                %([DingTalk System] ⚠️ Failed to deliver file "#{display_name}": file type ".#{ext}" is not supported. Supported types: #{supported_list}.)
              )
              return { ok: false, error: :unsupported_extension }
            end

            media_id = @api_client.upload_media(path, kind: kind)
            unless media_id
              Clacky::Logger.warn("[dingtalk] send_file: upload failed for #{path}")
              return { ok: false, error: "upload_failed" }
            end

            @api_client.send_media(
              robot_code: route[:robot_code],
              conv_type:  route[:conv_type],
              conv_id:    route[:conv_id],
              user_id:    route[:user_id],
              media_id:   media_id,
              kind:       kind,
              file_name:  name || File.basename(path)
            )
          end

          def validate_config(config)
            errors = []
            errors << "client_id is required"     if config[:client_id].to_s.strip.empty?
            errors << "client_secret is required" if config[:client_secret].to_s.strip.empty?
            errors
          end

          private def handle_frame(frame)
            topic = frame.dig("headers", "topic").to_s
            return unless topic == "/v1.0/im/bot/messages/get"

            data = begin
              raw = frame["data"]
              raw.is_a?(String) ? JSON.parse(raw) : raw
            rescue JSON::ParserError
              Clacky::Logger.warn("[dingtalk] failed to parse event data")
              return
            end

            sender_id    = data.dig("senderStaffId") || data.dig("senderId") || ""
            chat_id      = data.dig("conversationId") || sender_id
            webhook_url  = data.dig("sessionWebhook") || ""
            expired_ms   = (data.dig("sessionWebhookExpiredTime") || 0).to_i
            conv_type    = data.dig("conversationType").to_s  # "1"=DM, "2"=group
            robot_code   = data["robotCode"].to_s

            cache_webhook(chat_id, webhook_url, expired_ms) unless webhook_url.empty?
            cache_route(chat_id, robot_code: robot_code, conv_id: data["conversationId"].to_s,
                        user_id: sender_id, conv_type: conv_type)

            return if sender_id.empty?

            # Group chats: only respond when @-mentioned
            if conv_type == "2"
              content  = data.dig("text", "content").to_s
              at_users = Array(data.dig("atUsers")).map { |u| u.dig("dingtalkId") || u.dig("staffId") || "" }
              bot_id   = data.dig("chatbotUserId").to_s
              unless at_users.include?(bot_id) || content.include?("@")
                return
              end
            end

            allowed = @config[:allowed_users]
            return if allowed && !allowed.empty? && !allowed.include?(sender_id)

            text, files = extract_payload(data, robot_code)
            return if text.strip.empty? && files.empty?

            event = {
              platform:   :dingtalk,
              user_id:    sender_id,
              chat_id:    chat_id,
              message_id: data.dig("msgId") || "",
              text:       text,
              files:      files,
              chat_type:  conv_type == "2" ? :group : :direct
            }

            log_parts = []
            log_parts << text.slice(0, 80) unless text.strip.empty?
            log_parts << "#{files.size} file(s)" unless files.empty?
            Clacky::Logger.info("[dingtalk] message from #{sender_id}: #{log_parts.join(' | ')}")
            @on_message&.call(event)
          rescue => e
            Clacky::Logger.warn("[dingtalk] handle_frame error: #{e.message}")
          end

          # Parse text + attachments from inbound event by msgtype.
          # Returns [text, files] where files is an array of { path:, mime:, name: }.
          private def extract_payload(data, robot_code)
            msgtype = data["msgtype"].to_s
            text    = ""
            files   = []

            case msgtype
            when "text"
              text = extract_text(data)
            when "picture"
              code = data.dig("content", "downloadCode")
              file = download_one(code, robot_code)
              files << file if file
            when "file"
              # Inbound file message — DingTalk's downloadCode → downloadUrl path
              # works for any file type (no whitelist on the inbound side).
              code = data.dig("content", "downloadCode")
              name = data.dig("content", "fileName")
              file = download_one(code, robot_code, prefer_name: name)
              files << file if file
            when "richText"
              Array(data.dig("content", "richText")).each do |part|
                if part["text"]
                  text += part["text"].to_s
                elsif part["downloadCode"] && part["type"] == "picture"
                  file = download_one(part["downloadCode"], robot_code)
                  files << file if file
                end
              end
            else
              Clacky::Logger.info("[dingtalk] unsupported msgtype=#{msgtype}, ignoring")
            end

            [text, files]
          end

          private def download_one(download_code, robot_code, prefer_name: nil)
            res = @api_client.download_message_file(download_code, robot_code, prefer_name: prefer_name)
            return nil unless res
            name = (prefer_name && !prefer_name.to_s.empty?) ? prefer_name.to_s : File.basename(res[:path])
            { path: res[:path], mime: res[:mime], name: name }
          end

          private def extract_text(data)
            content = data.dig("text", "content").to_s.strip
            # Strip leading @bot mention if present
            content.gsub(/^@\S+\s*/, "").strip
          end

          private def cache_webhook(chat_id, url, expired_ms)
            @webhook_mutex.synchronize do
              @webhook_urls[chat_id] = { url: url, expires_at_ms: expired_ms }
            end
          end

          private def resolve_webhook(chat_id)
            entry = @webhook_mutex.synchronize { @webhook_urls[chat_id] }
            return nil unless entry

            expires_at = entry[:expires_at_ms].to_i
            if expires_at > 0
              now_ms = (Time.now.to_f * 1000).to_i
              if now_ms + WEBHOOK_SAFETY_MARGIN_MS >= expires_at
                @webhook_mutex.synchronize { @webhook_urls.delete(chat_id) }
                return nil
              end
            end
            entry[:url]
          end

          private def cache_route(chat_id, robot_code:, conv_id:, user_id:, conv_type:)
            return if robot_code.empty?
            @routes_mutex.synchronize do
              @routes[chat_id] = {
                robot_code: robot_code,
                conv_id:    conv_id,
                user_id:    user_id,
                conv_type:  conv_type
              }
            end
          end

          private def resolve_route(chat_id)
            @routes_mutex.synchronize { @routes[chat_id] }
          end

          private def image_file?(path)
            %w[.jpg .jpeg .png .gif .webp].include?(File.extname(path).downcase)
          end

          private def supported_file?(path)
            ext = File.extname(path).delete_prefix(".").downcase
            ApiClient::SUPPORTED_FILE_EXTS.include?(ext)
          end
        end

        Adapters.register(:dingtalk, Adapter)
      end
    end
  end
end
