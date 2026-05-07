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
            @doc_retry_cache = {} # { chat_id => { doc_urls: [...], attempts: N } }
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

          # Send a file (or image) to a chat.
          # @param chat_id [String] Chat ID
          # @param path [String] Local file path
          # @param name [String, nil] Display filename
          # @param reply_to [String, nil] Message ID to reply to
          def send_file(chat_id, path, name: nil, reply_to: nil)
            @bot.send_file(chat_id, path, name: name, reply_to: reply_to)
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
            Clacky::Logger.warn("[feishu] Error handling event: #{e.message}")
            Clacky::Logger.warn(e.backtrace.first(5).join("\n"))
          end

          # Handle message event
          # @param event [Hash] Parsed message event
          # @return [void]
          def handle_message_event(event)
            # In group chats, only respond when the bot is explicitly @-mentioned.
            # Private chats always respond.
            if event[:chat_type] == :group
              bot_id = @bot.bot_open_id
              return if bot_id && !Array(event[:mentioned_open_ids]).include?(bot_id)
            end

            allowed_users = @config[:allowed_users]
            if allowed_users && !allowed_users.empty?
              return unless allowed_users.include?(event[:user_id])
            end

            # Download images and attach as file hashes
            image_files = []
            if event[:image_keys] && !event[:image_keys].empty?
              image_files, errors = download_images(event[:image_keys], event[:message_id])
              if image_files.empty? && !errors.empty?
                @bot.send_text(event[:chat_id], "#{errors.first}", reply_to: event[:message_id])
                return
              end
            end

            # Download and process file attachments
            disk_files = []
            if event[:file_attachments] && !event[:file_attachments].empty?
              disk_files = process_files(event[:file_attachments], event[:message_id])
            end

            all_files = image_files + disk_files
            event = event.merge(files: all_files) unless all_files.empty?

            # Merge cached doc_urls (from previous failed attempts) into current event
            cached = @doc_retry_cache[event[:chat_id]]
            if cached
              merged_urls = ((event[:doc_urls] || []) + cached[:doc_urls]).uniq
              event = event.merge(doc_urls: merged_urls)
            end

            # Fetch Feishu document content for any doc URLs in the message
            if event[:doc_urls] && !event[:doc_urls].empty?
              event = enrich_with_doc_content(event)
              return if event.nil?
            end

            @on_message&.call(event)
          end

          # Fetch Feishu document content and append to event[:text].
          # If the app lacks permission (91403), sends a guidance message and returns nil
          # so the caller can skip forwarding the event to the agent.
          # @param event [Hash]
          # @return [Hash, nil] enriched event or nil if permission error
          DOC_RETRY_MAX = 3

          def enrich_with_doc_content(event)
            doc_sections = []
            failed_urls = []

            event[:doc_urls].each do |url|
              content = @bot.fetch_doc_content(url)
              doc_sections << "📄 [Doc content from #{url}]\n#{content}" unless content.empty?
            rescue Feishu::FeishuDocPermissionError
              failed_urls << url
              doc_sections << "#{url}\n[System Notice] Cannot read the above Feishu doc: the app has no access (error 91403). Tell user to: open the doc → top-right \"...\" → \"Add Document App\" → add this bot → just send any message to retry."
            rescue Feishu::FeishuDocScopeError => e
              failed_urls << url
              scope_hint = e.auth_url ? "Admin can approve with one click: [点击授权](#{e.auth_url})" : "Admin needs to enable 'docx:document:readonly' scope in Feishu Open Platform."
              doc_sections << "#{url}\n[System Notice] Cannot read the above Feishu doc: app is missing docx API scope (error 99991672). #{scope_hint} Tell user to just send any message to retry after approval."
            rescue => e
              failed_urls << url
              Clacky::Logger.warn("[feishu] Failed to fetch doc #{url}: #{e.message}")
              doc_sections << "#{url}\n[System Notice] Cannot read the above Feishu doc: #{e.message}. Tell user to just send any message to retry."
            end

            # Update retry cache
            chat_id = event[:chat_id]
            if failed_urls.any?
              existing = @doc_retry_cache[chat_id]
              attempts = (existing&.dig(:attempts) || 0) + 1
              if attempts >= DOC_RETRY_MAX
                @doc_retry_cache.delete(chat_id)
              else
                @doc_retry_cache[chat_id] = { doc_urls: failed_urls, attempts: attempts }
              end
            else
              # All docs fetched successfully, clear cache
              @doc_retry_cache.delete(chat_id)
            end

            return event if doc_sections.empty?

            enriched_text = [event[:text], *doc_sections].reject(&:empty?).join("\n\n")
            event.merge(text: enriched_text)
          end

          MAX_IMAGE_BYTES = Clacky::Utils::FileProcessor::MAX_IMAGE_BYTES

          # Download images from Feishu and return as file hashes.
          # Images within MAX_IMAGE_BYTES are returned with data_url for vision.
          # Oversized images are rejected with an error message.
          # @param image_keys [Array<String>]
          # @param message_id [String]
          # @return [Array<Hash>, Array<String>] [file_hashes, error_messages]
          def download_images(image_keys, message_id)
            require "base64"
            file_hashes = []
            errors = []
            image_keys.each do |image_key|
              result = @bot.download_message_resource(message_id, image_key, type: "image")
              if result[:body].bytesize > MAX_IMAGE_BYTES
                errors << "Image too large (#{(result[:body].bytesize / 1024.0).round(0).to_i}KB), max #{MAX_IMAGE_BYTES / 1024}KB"
                next
              end
              mime = result[:content_type]
              mime = "image/jpeg" if mime.nil? || mime.empty? || !mime.start_with?("image/")
              data_url = "data:#{mime};base64,#{Base64.strict_encode64(result[:body])}"
              file_hashes << { name: "image.jpg", mime_type: mime, data_url: data_url }
            rescue => e
              Clacky::Logger.warn("[feishu] Failed to download image #{image_key}: #{e.message}")
              errors << "Image download failed: #{e.message}"
            end
            [file_hashes, errors]
          end

          # Download and save file attachments, returning file hashes for agent.
          # Parsing happens inside agent.run, not here.
          # @param attachments [Array<Hash>] [{key:, name:}]
          # @param message_id [String]
          # @return [Array<Hash>] { name:, path: }
          def process_files(attachments, message_id)
            attachments.filter_map do |attachment|
              result = @bot.download_message_resource(message_id, attachment[:key], type: "file")
              Clacky::Utils::FileProcessor.save(body: result[:body], filename: attachment[:name])
            rescue => e
              Clacky::Logger.warn("[feishu] Failed to download file #{attachment[:name]}: #{e.message}")
              nil
            end.compact
          end
        end

        Adapters.register(:feishu, Adapter)
      end
    end
  end
end
