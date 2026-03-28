# frozen_string_literal: true

require "base64"
require_relative "../../adapters/base"
require_relative "api_client"

module Clacky
  module Channel
    module Adapters
      module Weixin
        # Weixin (WeChat iLink) adapter.
        #
        # Protocol: HTTP long-poll via ilinkai.weixin.qq.com
        # Auth: token obtained from QR login (stored in channels.yml as `token`)
        #
        # Config keys (channels.yml):
        #   token:         [String] bot token from QR login
        #   base_url:      [String] API base URL (default: https://ilinkai.weixin.qq.com)
        #   allowed_users: [Array<String>] optional whitelist of from_user_id values
        #
        # Event fields yielded to ChannelManager:
        #   platform:      :weixin
        #   chat_id:       String (from_user_id — used for replies)
        #   user_id:       String (from_user_id)
        #   text:          String
        #   files:         Array<Hash>
        #   message_id:    String
        #   timestamp:     Time
        #   chat_type:     :direct
        #   context_token: String (must be echoed in every reply)
        class Adapter < Base
          RECONNECT_DELAY = 5

          def self.platform_id
            :weixin
          end

          def self.env_keys
            %w[IM_WEIXIN_TOKEN IM_WEIXIN_BASE_URL IM_WEIXIN_ALLOWED_USERS]
          end

          def self.platform_config(data)
            {
              token:         data["IM_WEIXIN_TOKEN"] || data["token"],
              base_url:      data["IM_WEIXIN_BASE_URL"] || data["base_url"] || ApiClient::DEFAULT_BASE_URL,
              allowed_users: (data["IM_WEIXIN_ALLOWED_USERS"] || data["allowed_users"] || "")
                               .then { |v| v.is_a?(Array) ? v : v.to_s.split(",").map(&:strip).reject(&:empty?) }
            }.compact
          end

          def self.set_env_data(data, config)
            data["IM_WEIXIN_TOKEN"]         = config[:token]
            data["IM_WEIXIN_BASE_URL"]      = config[:base_url] if config[:base_url]
            data["IM_WEIXIN_ALLOWED_USERS"] = Array(config[:allowed_users]).join(",")
          end

          def self.test_connection(fields)
            token = fields[:token].to_s.strip

            return { ok: false, error: "token is required" } if token.empty?

            # Weixin iLink token is obtained via the QR scan flow and is already
            # confirmed valid by the iLink API before we store it. There is no
            # lightweight ping endpoint, so we just verify the token is present.
            { ok: true, message: "Connected to Weixin iLink" }
          end

          def initialize(config)
            @config        = config
            @token         = config[:token].to_s
            @base_url      = config[:base_url] || ApiClient::DEFAULT_BASE_URL
            @allowed_users = Array(config[:allowed_users])
            @running       = false
            @on_message    = nil
            # In-memory store: user_id → context_token (for reply threading)
            @context_tokens = {}
            @ctx_mutex      = Mutex.new
            @api_client     = ApiClient.new(base_url: @base_url, token: @token)
          end

          def start(&on_message)
            @running    = true
            @on_message = on_message

            get_updates_buf    = ""
            consecutive_errors = 0

            Clacky::Logger.info("[WeixinAdapter] starting long-poll (base_url=#{@base_url})")

            while @running
              begin
                resp = @api_client.get_updates(get_updates_buf: get_updates_buf)

                consecutive_errors = 0
                new_buf = resp["get_updates_buf"].to_s
                get_updates_buf = new_buf unless new_buf.empty?

                (resp["msgs"] || []).each do |msg|
                  process_message(msg)
                rescue => e
                  Clacky::Logger.warn("[WeixinAdapter] process_message error: #{e.message}")
                end

              rescue ApiClient::TimeoutError
                # Long-poll server-side timeout is expected — just retry
              rescue ApiClient::ApiError => e
                if e.code == ApiClient::SESSION_EXPIRED_ERRCODE
                  Clacky::Logger.warn("[WeixinAdapter] Session expired (token may need refresh), backing off 60s")
                  sleep 60
                else
                  consecutive_errors += 1
                  Clacky::Logger.warn("[WeixinAdapter] API error #{e.code}: #{e.message}")
                  sleep(consecutive_errors > 3 ? 30 : RECONNECT_DELAY)
                end
              rescue => e
                consecutive_errors += 1
                Clacky::Logger.error("[WeixinAdapter] poll error: #{e.message}")
                break unless @running
                sleep(consecutive_errors > 3 ? 30 : RECONNECT_DELAY)
              end
            end
          end

          def stop
            @running = false
          end

          # Send a plain text reply to a user.
          # The context_token from the inbound message is required by the Weixin protocol.
          def send_text(chat_id, text, reply_to: nil)
            ctoken = lookup_context_token(chat_id)
            unless ctoken
              Clacky::Logger.warn("[WeixinAdapter] send_text: no context_token for #{chat_id}, dropping message")
              return { message_id: nil }
            end

            plain = markdown_to_plain(text)
            split_message(plain).each do |chunk|
              @api_client.send_text(to_user_id: chat_id, text: chunk, context_token: ctoken)
            end

            { message_id: nil }
          rescue => e
            Clacky::Logger.error("[WeixinAdapter] send_text failed for #{chat_id}: #{e.message}")
            { message_id: nil }
          end

          # Send a file to a user.
          # file_path: local path to the file to send
          # file_name: optional display name (defaults to basename)
          def send_file(chat_id, file_path, name: nil, reply_to: nil)
            ctoken = lookup_context_token(chat_id)
            unless ctoken
              Clacky::Logger.warn("[WeixinAdapter] send_file: no context_token for #{chat_id}, dropping")
              return { message_id: nil }
            end

            @api_client.send_file(
              to_user_id:    chat_id,
              file_path:     file_path,
              file_name:     name || File.basename(file_path),
              context_token: ctoken
            )
            { message_id: nil }
          rescue => e
            Clacky::Logger.error("[WeixinAdapter] send_file failed for #{chat_id}: #{e.message}")
            { message_id: nil }
          end

          def validate_config(config)
            errors = []
            errors << "token is required" if config[:token].nil? || config[:token].to_s.strip.empty?
            errors
          end

          def supports_message_updates?
            false
          end


          def process_message(msg)
            # Only process inbound USER messages (message_type 1 = USER)
            return unless msg["message_type"] == 1

            from_user_id  = msg["from_user_id"].to_s
            context_token = msg["context_token"].to_s
            return if from_user_id.empty? || context_token.empty?

            if @allowed_users.any? && !@allowed_users.include?(from_user_id)
              Clacky::Logger.debug("[WeixinAdapter] ignoring message from #{from_user_id} (not in allowed_users)")
              return
            end

            # Cache context_token — needed when sending replies
            store_context_token(from_user_id, context_token)

            item_list = msg["item_list"] || []
            Clacky::Logger.debug("[WeixinAdapter] item_list raw: #{item_list.to_json}")
            text  = extract_text(item_list)
            files = extract_files(item_list)

            # Require at least some content (text or files)
            return if text.strip.empty? && files.empty?

            event = {
              type:          :message,
              platform:      :weixin,
              chat_id:       from_user_id,
              user_id:       from_user_id,
              text:          text.strip,
              files:         files,
              message_id:    msg["message_id"]&.to_s,
              timestamp:     msg["create_time_ms"] ? Time.at(msg["create_time_ms"] / 1000.0) : Time.now,
              chat_type:     :direct,
              context_token: context_token,
              raw:           msg
            }

            log_parts = []
            log_parts << text.slice(0, 80) unless text.strip.empty?
            log_parts << "#{files.size} file(s)" unless files.empty?
            Clacky::Logger.info("[WeixinAdapter] message from #{from_user_id}: #{log_parts.join(" + ")}")
            @on_message&.call(event)
          end

          def extract_text(item_list)
            parts = []
            item_list.each do |item|
              case item["type"]
              when 1  # TEXT
                raw_text = item.dig("text_item", "text").to_s.strip
                ref = item["ref_msg"]
                if ref && !ref.empty?
                  ref_parts = []
                  ref_parts << ref["title"] if ref["title"] && !ref["title"].empty?
                  if (ri = ref["message_item"]) && ri["type"] == 1
                    rt = ri.dig("text_item", "text").to_s.strip
                    ref_parts << rt unless rt.empty?
                  end
                  parts << "[引用: #{ref_parts.join(" | ")}]" unless ref_parts.empty?
                end
                parts << raw_text unless raw_text.empty?
              when 3  # VOICE — use transcription if available
                vt = item.dig("voice_item", "text").to_s.strip
                parts << vt unless vt.empty?
              end
            end
            parts.join("\n")
          end

          # Extract file attachments from item_list for inbound messages.
          # Returns array of hashes: { type:, name:, cdn_media: }
          # cdn_media contains { encrypt_query_param:, aes_key: } for potential download.
          # Extract and materialize file attachments from an inbound item_list.
          #
          # Images are downloaded from CDN and converted to data_url so the agent's
          # vision pipeline (partition_files → resolve_vision_images) picks them up
          # correctly. Other file types are returned with cdn_media metadata only
          # (download-on-demand is not yet implemented for non-image types).
          #
          # Returns Array of Hashes. Image entries include:
          #   { type: :image, name: String, mime_type: String, data_url: String }
          # Other entries include:
          #   { type: :file/:voice/:video, name: String, cdn_media: Hash }
          def extract_files(item_list)
            files = []
            item_list.each do |item|
              case item["type"]
              when 2  # IMAGE — download + convert to data_url for agent vision
                img = item["image_item"]
                next unless img
                cdn_media = img["media"]
                next unless cdn_media

                # Protocol: image_item may have a top-level aeskey field that overrides
                # the one inside media. Use image_item.aeskey first, fall back to media.aes_key.
                top_level_aeskey = img["aeskey"]
                effective_cdn_media = if top_level_aeskey && !top_level_aeskey.empty?
                                        cdn_media.merge("aes_key" => top_level_aeskey)
                                      else
                                        cdn_media
                                      end

                Clacky::Logger.debug("[WeixinAdapter] image cdn_media: #{effective_cdn_media.to_json}")

                begin
                  raw_bytes = @api_client.download_media(effective_cdn_media, ApiClient::MEDIA_TYPE_IMAGE)
                  mime_type = detect_image_mime(raw_bytes)
                  data_url  = "data:#{mime_type};base64,#{Base64.strict_encode64(raw_bytes)}"
                  files << {
                    type:      :image,
                    name:      "image.jpg",
                    mime_type: mime_type,
                    data_url:  data_url
                  }
                rescue => e
                  Clacky::Logger.warn("[WeixinAdapter] Failed to download image: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
                end

              when 3  # VOICE
                v = item["voice_item"]
                next unless v
                files << {
                  type:      :voice,
                  name:      "voice.amr",
                  cdn_media: v["media"]
                }
              when 4  # FILE
                fi = item["file_item"]
                next unless fi
                files << {
                  type:      :file,
                  name:      fi["file_name"],
                  md5:       fi["md5"],
                  len:       fi["len"],
                  cdn_media: fi["media"]
                }
              when 5  # VIDEO
                vi = item["video_item"]
                next unless vi
                files << {
                  type:      :video,
                  name:      "video.mp4",
                  cdn_media: vi["media"]
                }
              end
            end
            files
          end

          # Detect image MIME type from magic bytes.
          # Falls back to image/jpeg if unknown.
          def detect_image_mime(bytes)
            return "image/jpeg"  unless bytes && bytes.bytesize >= 4
            head = bytes.byteslice(0, 8).bytes
            if head[0] == 0xFF && head[1] == 0xD8
              "image/jpeg"
            elsif head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47
              "image/png"
            elsif head[0] == 0x47 && head[1] == 0x49 && head[2] == 0x46
              "image/gif"
            elsif head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46
              "image/webp"
            else
              "image/jpeg"
            end
          end

          def store_context_token(user_id, token)
            @ctx_mutex.synchronize { @context_tokens[user_id] = token }
          end

          def lookup_context_token(user_id)
            @ctx_mutex.synchronize { @context_tokens[user_id] }
          end

          # Split text into ≤4000-char chunks, preferring newline boundaries.
          def split_message(text, limit: 4000)
            return [text] if text.length <= limit
            chunks = []
            while text.length > limit
              cut = text.rindex("\n", limit) || limit
              chunks << text[0, cut].rstrip
              text = text[cut..].lstrip
            end
            chunks << text unless text.empty?
            chunks
          end

          # Strip markdown syntax for WeChat (no markdown rendering).
          def markdown_to_plain(text)
            r = text.dup
            r.gsub!(/```[^\n]*\n?([\s\S]*?)```/) { Regexp.last_match(1).strip }
            r.gsub!(/!\[[^\]]*\]\([^)]*\)/, "")
            r.gsub!(/\[([^\]]+)\]\([^)]*\)/, '\1')
            r.gsub!(/\*\*([^*]+)\*\*/, '\1')
            r.gsub!(/\*([^*]+)\*/, '\1')
            r.gsub!(/__([^_]+)__/, '\1')
            r.gsub!(/_([^_]+)_/, '\1')
            r.gsub!(/^#+\s+/, "")
            r.gsub!(/^[-*_]{3,}\s*$/, "")
            r.strip
          end
        end

        Adapters.register(:weixin, Adapter)
      end
    end
  end
end
