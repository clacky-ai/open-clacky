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

          # Send a local file to the Feishu chat.
          # Automatically detects the file type and uses the appropriate
          # Feishu upload + send API (image / audio / video / file).
          #
          # @param chat_id [String] Chat ID
          # @param path [String] Local file path
          # @param name [String, nil] Override display filename
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash, nil] { message_id: String } or nil on failure
          def send_file(chat_id, path, name: nil, reply_to: nil)
            filename  = name || File.basename(path)
            file_data = File.binread(path)

            if image_file?(filename)
              image_key = @bot.upload_image(file_data, filename)
              @bot.send_image(chat_id, image_key, reply_to: reply_to)
            else
              file_type = feishu_file_type(filename)
              duration  = nil
              if file_type == "opus"
                duration = parse_ogg_duration(file_data)
              elsif file_type == "mp4"
                duration = parse_mp4_duration(file_data)
              end
              file_key = @bot.upload_file(file_data, filename, file_type, duration: duration)
              case file_type
              when "opus" then @bot.send_audio(chat_id, file_key, reply_to: reply_to)
              when "mp4"  then @bot.send_video(chat_id, file_key, reply_to: reply_to)
              else             @bot.send_file_message(chat_id, file_key, reply_to: reply_to)
              end
            end
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

          # Known image file extensions for Feishu image upload path.
          IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .gif .bmp .webp .ico .tiff .tif .heic].freeze

          # Extension-to-Feishu-file-type mapping.
          # Feishu accepts: "opus" | "mp4" | "pdf" | "doc" | "xls" | "ppt" | "stream"
          FEISHU_FILE_TYPE_MAP = {
            ".opus" => "opus", ".ogg" => "opus",
            ".mp4"  => "mp4",  ".mov" => "mp4",  ".avi" => "mp4", ".mkv" => "mp4", ".webm" => "mp4",
            ".pdf"  => "pdf",
            ".doc"  => "doc",  ".docx" => "doc",
            ".xls"  => "xls",  ".xlsx" => "xls", ".csv" => "xls",
            ".ppt"  => "ppt",  ".pptx" => "ppt"
          }.freeze

          # Return true when the filename has an image extension.
          # @param filename [String]
          # @return [Boolean]
          def image_file?(filename)
            ext = File.extname(filename).downcase
            IMAGE_EXTENSIONS.include?(ext)
          end

          # Map a filename extension to the Feishu file type string.
          # Falls back to "stream" for unknown extensions.
          # @param filename [String]
          # @return [String] Feishu file type
          def feishu_file_type(filename)
            ext = File.extname(filename).downcase
            FEISHU_FILE_TYPE_MAP[ext] || "stream"
          end

          # Parse the duration (ms) from an OGG/Opus binary buffer.
          # Scans backwards for the last OggS page and reads the granule position.
          # Returns nil when the buffer cannot be parsed.
          # @param data [String] Raw binary content
          # @return [Integer, nil] Duration in milliseconds
          def parse_ogg_duration(data)
            # OggS magic: "OggS"
            oggs = "OggS"
            offset = -1
            i = data.bytesize - 4
            while i >= 0
              if data.getbyte(i) == 0x4f && data[i, 4] == oggs
                offset = i
                break
              end
              i -= 1
            end
            return nil if offset < 0

            # Granule position: 8 bytes at offset+6 (little-endian)
            granule_off = offset + 6
            return nil if granule_off + 8 > data.bytesize

            lo = data[granule_off,     4].unpack1("V")
            hi = data[granule_off + 4, 4].unpack1("V")
            granule = hi * 0x1_0000_0000 + lo
            return nil if granule <= 0

            ((granule.to_f / 48_000) * 1000).ceil
          rescue
            nil
          end

          # Parse the duration (ms) from an MP4 binary buffer.
          # Finds the moov/mvhd box and reads timescale + duration.
          # Returns nil when the buffer cannot be parsed.
          # @param data [String] Raw binary content
          # @return [Integer, nil] Duration in milliseconds
          def parse_mp4_duration(data)
            moov = find_mp4_box(data, 0, data.bytesize, "moov")
            return nil unless moov

            mvhd = find_mp4_box(data, moov[:data_start], moov[:data_end], "mvhd")
            return nil unless mvhd

            off     = mvhd[:data_start]
            version = data.getbyte(off)

            if version == 0
              return nil if off + 20 > data.bytesize
              timescale = data[off + 12, 4].unpack1("N")
              duration  = data[off + 16, 4].unpack1("N")
            else
              return nil if off + 32 > data.bytesize
              timescale = data[off + 20, 4].unpack1("N")
              hi        = data[off + 24, 4].unpack1("N")
              lo        = data[off + 28, 4].unpack1("N")
              duration  = hi * 0x1_0000_0000 + lo
            end

            return nil if timescale <= 0 || duration <= 0

            (duration.to_f / timescale * 1000).round
          rescue
            nil
          end

          # Find a 4-char-typed MP4 box within the given byte range.
          # @param data [String] Raw binary content
          # @param start [Integer] Start offset
          # @param stop [Integer] End offset
          # @param type [String] 4-character box type
          # @return [Hash, nil] { data_start:, data_end: } or nil
          def find_mp4_box(data, start, stop, type)
            offset = start
            while offset + 8 <= stop
              size     = data[offset, 4].unpack1("N")
              box_type = data[offset + 4, 4]

              if size == 0
                box_end    = stop
                data_start = offset + 8
              elsif size == 1
                break if offset + 16 > stop
                hi         = data[offset + 8,  4].unpack1("N")
                lo         = data[offset + 12, 4].unpack1("N")
                box_end    = offset + hi * 0x1_0000_0000 + lo
                data_start = offset + 16
              else
                break if size < 8
                box_end    = offset + size
                data_start = offset + 8
              end

              return { data_start: data_start, data_end: [box_end, stop].min } if box_type == type

              offset = box_end
            end
            nil
          rescue
            nil
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
