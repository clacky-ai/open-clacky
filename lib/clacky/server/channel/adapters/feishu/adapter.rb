# frozen_string_literal: true

require_relative "../../adapters/base"
require_relative "bot"
require_relative "message_parser"
require_relative "file_processor"
require_relative "ws_client"

module Clacky
  module Channel
    module Adapters
      module Feishu
        DEFAULT_DOMAIN = "https://open.feishu.cn"

        # Feishu adapter implementation.
        # Handles message receiving via WebSocket and sending via Bot API.
        class Adapter < Base

          def self.platform_id
            :feishu
          end

          def self.env_keys
            %w[IM_FEISHU_APP_ID IM_FEISHU_APP_SECRET IM_FEISHU_DOMAIN IM_FEISHU_ALLOWED_USERS]
          end

          def self.platform_config(data)
            {
              app_id: data["IM_FEISHU_APP_ID"],
              app_secret: data["IM_FEISHU_APP_SECRET"],
              domain: data["IM_FEISHU_DOMAIN"] || DEFAULT_DOMAIN,
              allowed_users: data["IM_FEISHU_ALLOWED_USERS"]&.split(",")&.map(&:strip)&.reject(&:empty?)
            }
          end

          def self.set_env_data(data, config)
            data["IM_FEISHU_APP_ID"] = config[:app_id]
            data["IM_FEISHU_APP_SECRET"] = config[:app_secret]
            data["IM_FEISHU_DOMAIN"] = config[:domain] if config[:domain]
            data["IM_FEISHU_ALLOWED_USERS"] = Array(config[:allowed_users]).join(",")
          end

          # Test connectivity with provided credentials (does not persist).
          # @param fields [Hash] symbol-keyed credential fields
          # @return [Hash] { ok: Boolean, message: String }
          def self.test_connection(fields)
            app_id     = fields[:app_id].to_s.strip
            app_secret = fields[:app_secret].to_s.strip
            domain     = fields[:domain].to_s.strip
            domain     = DEFAULT_DOMAIN if domain.empty?

            return { ok: false, error: "app_id is required" }     if app_id.empty?
            return { ok: false, error: "app_secret is required" }  if app_secret.empty?

            bot = Bot.new(app_id: app_id, app_secret: app_secret, domain: domain)
            # Attempt to fetch a tenant access token — success means credentials are valid.
            token = bot.tenant_access_token
            if token && !token.empty?
              { ok: true, message: "Connected — tenant access token obtained" }
            else
              { ok: false, error: "Empty token returned — check app_id and app_secret" }
            end
          rescue StandardError => e
            { ok: false, error: e.message }
          end

          def initialize(config)
            @config = config
            @bot = Bot.new(
              app_id: config[:app_id],
              app_secret: config[:app_secret],
              domain: config[:domain] || DEFAULT_DOMAIN
            )
            @ws_client = nil
            @running = false
          end

          # Start listening for messages via WebSocket
          # @yield [event] Yields standardized inbound messages
          # @return [void]
          def start(&on_message)
            @running = true
            @on_message = on_message

            @ws_client = WSClient.new(
              app_id: @config[:app_id],
              app_secret: @config[:app_secret],
              domain: @config[:domain] || DEFAULT_DOMAIN
            )

            @ws_client.start do |raw_event|
              handle_event(raw_event)
            end
          end

          # Stop the adapter
          # @return [void]
          def stop
            @running = false
            @ws_client&.stop
          end

          # Send plain text message
          # @param chat_id [String] Chat ID
          # @param text [String] Message text
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] Result with :message_id
          def send_text(chat_id, text, reply_to: nil)
            @bot.send_text(chat_id, text, reply_to: reply_to)
          end

          # Update existing message
          # @param chat_id [String] Chat ID (unused for Feishu)
          # @param message_id [String] Message ID to update
          # @param text [String] New text
          # @return [Boolean] Success status
          def update_message(chat_id, message_id, text)
            @bot.update_message(message_id, text)
          end

          # @return [Boolean]
          def supports_message_updates?
            true
          end

          # Validate configuration
          # @param config [Hash] Configuration to validate
          # @return [Array<String>] Error messages
          def validate_config(config)
            errors = []
            errors << "app_id is required" if config[:app_id].nil? || config[:app_id].empty?
            errors << "app_secret is required" if config[:app_secret].nil? || config[:app_secret].empty?
            errors
          end

          private

          # Handle incoming WebSocket event
          # @param raw_event [Hash] Raw event data
          # @return [void]
          def handle_event(raw_event)
            parsed = MessageParser.parse(raw_event)
            return unless parsed

            case parsed[:type]
            when :message
              handle_message_event(parsed)
            when :challenge
              # Challenge is handled by MessageParser
            end
          rescue => e
            warn "Error handling event: #{e.message}"
            warn e.backtrace.join("\n")
          end

          # Handle message event
          # @param event [Hash] Parsed message event
          # @return [void]
          def handle_message_event(event)
            allowed_users = @config[:allowed_users]
            if allowed_users && !allowed_users.empty?
              return unless allowed_users.include?(event[:user_id])
            end

            # Download images and attach as data URLs
            if event[:image_keys] && !event[:image_keys].empty?
              images, errors = download_images(event[:image_keys], event[:message_id])
              if images.empty? && !errors.empty?
                @bot.send_text(event[:chat_id], "#{errors.first}", reply_to: event[:message_id])
                return
              end
              event = event.merge(images: images)
            end

            # Download and process file attachments
            if event[:file_attachments] && !event[:file_attachments].empty?
              # Reject unsupported formats before downloading
              unsupported = event[:file_attachments].filter_map do |a|
                FileProcessor.unsupported_error(a[:name])
              end
              if unsupported.size == event[:file_attachments].size && event[:text].to_s.strip.empty?
                @bot.send_text(event[:chat_id], "#{unsupported.first}", reply_to: event[:message_id])
                return
              end
              file_text = process_files(event[:file_attachments], event[:message_id])
              combined = [event[:text], file_text].reject(&:empty?).join("\n\n")
              event = event.merge(text: combined)
            end

            @on_message&.call(event)
          end

          # Download images from Feishu and return as base64 data URLs
          # Process file attachments: download and extract content/path for prompt
          # @param attachments [Array<Hash>] [{key:, name:}]
          # @param message_id [String]
          # @return [String] text to inject into prompt
          def process_files(attachments, message_id)
            attachments.filter_map do |attachment|
              name = attachment[:name]
              if (err = FileProcessor.unsupported_error(name))
                next err
              end
              result = @bot.download_message_resource(message_id, attachment[:key], type: "file")
              FileProcessor.process(result[:body], name)
            rescue => e
              warn "[Feishu] Failed to download file #{attachment[:name]}: #{e.message}"
              "[Attachment: #{attachment[:name]}]\nDownload failed: #{e.message}"
            end.join("\n\n")
          end

          MAX_IMAGE_BYTES = Clacky::Tools::FileAttachment::MAX_IMAGE_BYTES

          # @param image_keys [Array<String>]
          # @param message_id [String]
          # @return [Array<String>, Array<String>] [data_urls, error_messages]
          def download_images(image_keys, message_id)
            require "base64"
            data_urls = []
            errors = []
            image_keys.each do |image_key|
              result = @bot.download_message_resource(message_id, image_key, type: "image")
              if result[:body].bytesize > MAX_IMAGE_BYTES
                errors << "Image too large (#{(result[:body].bytesize / 1024.0 / 1024).round(1)}MB), max #{MAX_IMAGE_BYTES / 1024 / 1024}MB"
                next
              end
              mime = result[:content_type]
              mime = "image/jpeg" if mime.nil? || mime.empty? || !mime.start_with?("image/")
              data_urls << "data:#{mime};base64,#{Base64.strict_encode64(result[:body])}"
            rescue => e
              warn "[Feishu] Failed to download image #{image_key}: #{e.message}"
              errors << "Image download failed: #{e.message}"
            end
            [data_urls, errors]
          end
        end

        Adapters.register(:feishu, Adapter)
      end
    end
  end
end
