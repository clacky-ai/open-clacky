# frozen_string_literal: true

require_relative "../../adapters/base"
require_relative "ws_client"
require_relative "media_downloader"
require_relative "../feishu/file_processor"

module Clacky
  module Channel
    module Adapters
      module Wecom
        # WeCom (Enterprise WeChat) adapter.
        # Receives messages via WebSocket long connection and sends via bot API.
        class Adapter < Base
          def self.platform_id
            :wecom
          end

          def self.env_keys
            %w[IM_WECOM_BOT_ID IM_WECOM_SECRET]
          end

          def self.platform_config(data)
            {
              bot_id: data["IM_WECOM_BOT_ID"],
              secret: data["IM_WECOM_SECRET"]
            }
          end

          def self.set_env_data(data, config)
            data["IM_WECOM_BOT_ID"] = config[:bot_id]
            data["IM_WECOM_SECRET"] = config[:secret]
          end

          def initialize(config)
            @config = config
            @ws_client = WSClient.new(
              bot_id: config[:bot_id],
              secret: config[:secret],
              ws_url: config[:ws_url] || WSClient::WS_URL
            )
            @running = false
            @on_message = nil
          end

          def start(&on_message)
            @running = true
            @on_message = on_message

            @ws_client.start do |raw|
              handle_raw_message(raw)
            end
          end

          def stop
            @running = false
            @ws_client.stop
          end

          def send_text(chat_id, text, reply_to: nil)
            @ws_client.send_message(chat_id, text)
          end

          def validate_config(config)
            errors = []
            errors << "bot_id is required" if config[:bot_id].nil? || config[:bot_id].empty?
            errors << "secret is required" if config[:secret].nil? || config[:secret].empty?
            errors
          end

          private

          def handle_raw_message(raw)
            msgtype = raw["msgtype"]
            return unless %w[text image file].include?(msgtype)

            chat_id = raw["chatid"] || raw.dig("from", "userid")
            return unless chat_id

            user_id = raw.dig("from", "userid")
            chat_type = raw["chattype"] == "group" ? :group : :direct
            text = ""
            images = []

            case msgtype
            when "text"
              text = raw.dig("text", "content").to_s.strip
              return if text.empty?
            when "image"
              url    = raw.dig("image", "url")
              aeskey = raw.dig("image", "aeskey")
              return unless url
              result = MediaDownloader.download(url, aeskey)
              mime = MediaDownloader.detect_mime(result[:body])
              if result[:body].bytesize > MAX_IMAGE_BYTES
                @ws_client.send_message(chat_id, "Image too large (#{(result[:body].bytesize / 1024.0 / 1024).round(1)}MB), max #{MAX_IMAGE_BYTES / 1024 / 1024}MB")
                return
              end
              require "base64"
              images = ["data:#{mime};base64,#{Base64.strict_encode64(result[:body])}"]
            when "file"
              url      = raw.dig("file", "url")
              aeskey   = raw.dig("file", "aeskey")
              return unless url
              filename = raw.dig("file", "name") || raw.dig("file", "filename") || "attachment"
              if (err = Feishu::FileProcessor.unsupported_error(filename))
                @ws_client.send_message(chat_id, "#{err}")
                return
              end
              result = MediaDownloader.download(url, aeskey)
              filename = result[:filename] || filename
              text = Feishu::FileProcessor.process(result[:body], filename)
            end

            event = {
              type: :message,
              platform: :wecom,
              chat_id: chat_id,
              user_id: user_id,
              text: text,
              images: images,
              message_id: raw["msgid"],
              timestamp: raw["create_time"] ? Time.at(raw["create_time"]) : Time.now,
              chat_type: chat_type,
              raw: raw
            }

            @on_message&.call(event)
          rescue => e
            warn "WeCom handle_raw_message error: #{e.message}"
            begin
              @ws_client.send_message(chat_id, "Error processing message: #{e.message}") if chat_id
            rescue
              nil
            end
          end

          MAX_IMAGE_BYTES = Clacky::Tools::FileAttachment::MAX_IMAGE_BYTES
        end

        Adapters.register(:wecom, Adapter)
      end
    end
  end
end
