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
          def send_text(chat_id, text, reply_to: nil)
            webhook_url = resolve_webhook(chat_id)
            unless webhook_url
              Clacky::Logger.warn("[dingtalk] no valid sessionWebhook for chat #{chat_id} (expired or never received)")
              return { ok: false, error: "session_webhook_expired" }
            end
            @api_client.send_via_webhook(webhook_url, text)
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
            text         = extract_text(data)
            conv_type    = data.dig("conversationType").to_s  # "1"=DM, "2"=group

            cache_webhook(chat_id, webhook_url, expired_ms) unless webhook_url.empty?

            return if sender_id.empty?

            # Group chats: only respond when @-mentioned
            if conv_type == "2"
              content = data.dig("text", "content").to_s
              at_users = Array(data.dig("atUsers")).map { |u| u.dig("dingtalkId") || u.dig("staffId") || "" }
              bot_id   = data.dig("chatbotUserId").to_s
              unless at_users.include?(bot_id) || content.include?("@")
                return
              end
            end

            allowed = @config[:allowed_users]
            return if allowed && !allowed.empty? && !allowed.include?(sender_id)

            event = {
              platform:   :dingtalk,
              user_id:    sender_id,
              chat_id:    chat_id,
              message_id: data.dig("msgId") || "",
              text:       text,
              files:      [],
              chat_type:  conv_type == "2" ? :group : :direct
            }

            Clacky::Logger.info("[dingtalk] message from #{sender_id}: #{text.to_s[0, 80]}")
            @on_message&.call(event)
          rescue => e
            Clacky::Logger.warn("[dingtalk] handle_frame error: #{e.message}")
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
        end

        Adapters.register(:dingtalk, Adapter)
      end
    end
  end
end
