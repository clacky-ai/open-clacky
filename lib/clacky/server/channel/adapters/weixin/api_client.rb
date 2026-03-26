# frozen_string_literal: true

require "net/http"
require "json"
require "openssl"
require "securerandom"
require "base64"
require "digest"
require "tempfile"

module Clacky
  module Channel
    module Adapters
      module Weixin
        # HTTP API client for Weixin iLink bot protocol.
        #
        # All requests POST JSON to <base_url>/<endpoint>.
        # Required headers per request:
        #   Content-Type:      application/json
        #   AuthorizationType: ilink_bot_token
        #   Authorization:     Bearer <token>
        #   X-WECHAT-UIN:      base64(random uint32 as decimal string)
        class ApiClient
          DEFAULT_BASE_URL     = "https://ilinkai.weixin.qq.com"
          CDN_BASE_URL         = "https://novac2c.cdn.weixin.qq.com/c2c"
          API_PATH_PREFIX      = "ilink/bot"
          CHANNEL_VERSION      = "1.0.2"
          LONG_POLL_TIMEOUT_S  = 40   # slightly above the server's 35s
          API_TIMEOUT_S        = 15

          # media_type values for getuploadurl
          MEDIA_TYPE_IMAGE = 1
          MEDIA_TYPE_VIDEO = 2
          MEDIA_TYPE_FILE  = 3
          MEDIA_TYPE_VOICE = 4

          # Raised for non-zero API return codes or HTTP errors.
          class ApiError < StandardError
            attr_reader :code
            def initialize(code, msg)
              @code = code
              super("WeixinApiError(#{code}): #{msg.to_s.slice(0, 200)}")
            end
          end

          # Raised on network/read timeouts.
          class TimeoutError < StandardError; end

          # Server errcode for expired sessions.
          SESSION_EXPIRED_ERRCODE = -14

          def initialize(base_url:, token:)
            @base_url = base_url.to_s.chomp("/")
            @token    = token.to_s
          end

          # Long-poll for new messages.
          # @param get_updates_buf [String] cursor from last response ("" for first call)
          # @return [Hash] { ret:, msgs: [], get_updates_buf:, longpolling_timeout_ms: }
          def get_updates(get_updates_buf:)
            post("getupdates", { get_updates_buf: get_updates_buf }, timeout: LONG_POLL_TIMEOUT_S)
          end

          # Send a plain text message.
          # context_token is required by the Weixin protocol for conversation association.
          def send_text(to_user_id:, text:, context_token:)
            body = {
              msg: {
                from_user_id: "",
                to_user_id:   to_user_id,
                client_id:    "clacky-#{SecureRandom.hex(8)}",
                message_type: 2,   # BOT
                message_state: 2,  # FINISH
                item_list:     [{ type: 1, text_item: { text: text } }],
                context_token: context_token
              }
            }
            post("sendmessage", body)
          end

          # Send a file (any type) to a user.
          #
          # @param to_user_id [String]
          # @param file_path  [String] local path to the file
          # @param file_name  [String] display name (defaults to basename)
          # @param context_token [String]
          # @param media_type [Integer] MEDIA_TYPE_* constant (default: auto-detect)
          # @return [Hash] API response
          def send_file(to_user_id:, file_path:, context_token:, file_name: nil, media_type: nil)
            file_name  ||= File.basename(file_path)
            media_type ||= detect_media_type(file_name)
            raw_bytes    = File.binread(file_path)

            cdn_media = upload_media(
              raw_bytes:    raw_bytes,
              file_name:    file_name,
              media_type:   media_type,
              to_user_id:   to_user_id
            )

            item = build_media_item(media_type, cdn_media, raw_bytes, file_name)
            body = {
              msg: {
                from_user_id:  "",
                to_user_id:    to_user_id,
                client_id:     "clacky-#{SecureRandom.hex(8)}",
                message_type:  2,  # BOT
                message_state: 2,  # FINISH
                item_list:     [item],
                context_token: context_token
              }
            }
            Clacky::Logger.debug("[WeixinApiClient] send_file item: #{item.to_json}")
            post("sendmessage", body)
          end

          # Download and decrypt a media file from the Weixin CDN.
          #
          # @param cdn_media  [Hash]    { "encrypt_query_param" => String, "aes_key" => String }
          #                            Keys may be Symbol or String.
          # @param media_type [Integer] MEDIA_TYPE_* constant — controls aeskey decoding.
          # @return [String] raw (decrypted) file bytes.
          def download_media(cdn_media, media_type)
            encrypted_param = cdn_media[:encrypt_query_param] || cdn_media["encrypt_query_param"]
            aeskey_b64      = cdn_media[:aes_key]             || cdn_media["aes_key"]

            raise ApiError.new(0, "download_media: missing encrypt_query_param") unless encrypted_param
            raise ApiError.new(0, "download_media: missing aes_key")             unless aeskey_b64

            # Decode aes_key. The encoding depends on who generated the key:
            #
            # Outbound (we upload): image → base64(raw 16 bytes), others → base64(hex 32 chars)
            # Inbound (WeChat client uploaded): aes_key is a plain hex string (32 hex chars, no base64)
            #
            # Detection strategy — try to figure out the actual key by checking decoded size:
            #   decoded 16 bytes → raw AES key (our outbound image encoding)
            #   decoded 24 bytes → aes_key was a plain hex string (32 chars) passed as-is,
            #                      meaning aeskey_b64 IS the hex string, not base64 at all.
            #                      Use the original string directly: [aeskey_b64].pack("H*")
            #   decoded 32 bytes → base64(hex 32 chars) → [decoded].pack("H*") → 16 bytes
            raw_aes_key = begin
                            decoded = Base64.strict_decode64(aeskey_b64)
                            case decoded.bytesize
                            when 16
                              # Our outbound image encoding: base64(raw 16 bytes)
                              decoded
                            when 32
                              # Our outbound non-image encoding: base64(hex 32 chars)
                              [decoded].pack("H*")
                            else
                              # Unexpected — fall through to hex-string path
                              raise ArgumentError, "unexpected decoded size #{decoded.bytesize}"
                            end
                          rescue ArgumentError
                            # aes_key is a plain hex string (32 hex chars), not base64.
                            # This is the inbound format used by WeChat clients.
                            if aeskey_b64.match?(/\A[0-9a-fA-F]{32}\z/)
                              [aeskey_b64].pack("H*")
                            else
                              Clacky::Logger.warn("[WeixinApiClient] unknown aeskey format: len=#{aeskey_b64.bytesize}")
                              aeskey_b64[0, 16]  # last-resort: first 16 bytes
                            end
                          end

            Clacky::Logger.debug("[WeixinApiClient] download_media key_bytes=#{raw_aes_key.bytesize} media_type=#{media_type}")

            # GET encrypted bytes from CDN.
            cdn_url = "#{CDN_BASE_URL}/download" \
                      "?encrypted_query_param=#{URI.encode_uri_component(encrypted_param)}"
            encrypted_bytes = cdn_get(cdn_url)

            # Decrypt with AES-128-ECB.
            aes_ecb_decrypt(encrypted_bytes, raw_aes_key)
          end

          private

          # Full upload pipeline: encrypt → getuploadurl → CDN PUT → return CDNMedia hash.
          def upload_media(raw_bytes:, file_name:, media_type:, to_user_id:)
            # Generate a random 16-byte AES key.
            aes_key_raw = SecureRandom.bytes(16)

            # Encrypt file bytes with AES-128-ECB + PKCS7.
            encrypted_bytes = aes_ecb_encrypt(raw_bytes, aes_key_raw)

            # filekey: arbitrary unique string (use hex of random bytes).
            filekey = SecureRandom.hex(16)

            # aeskey for getuploadurl: hex string of raw 16 bytes (32 hex chars), NOT base64.
            # Confirmed from @tencent-weixin/openclaw-weixin source: aeskey.toString("hex")
            aeskey_hex = aes_key_raw.unpack1("H*")

            # aes_key for CDNMedia: base64 of the hex string as UTF-8 bytes.
            # Confirmed: Buffer.from(aeskey_hex).toString("base64") in Node.js = base64 of hex string bytes
            aeskey_b64 = Base64.strict_encode64(aeskey_hex)

            raw_md5 = Digest::MD5.hexdigest(raw_bytes)

            # Step 1: get CDN upload URL from iLink API.
            upload_resp = post("getuploadurl", {
              filekey:        filekey,
              media_type:     media_type,
              to_user_id:     to_user_id,
              rawsize:        raw_bytes.bytesize,
              rawfilemd5:     raw_md5,
              filesize:       encrypted_bytes.bytesize,
              aeskey:         aeskey_hex,
              no_need_thumb:  true
            })

            upload_param = upload_resp["upload_param"]
            Clacky::Logger.debug("[WeixinApiClient] getuploadurl resp: #{upload_resp.to_json}")
            raise ApiError.new(0, "getuploadurl: missing upload_param") unless upload_param

            # Step 2: upload encrypted bytes to CDN.
            download_param = cdn_upload(
              upload_param:    upload_param,
              filekey:         filekey,
              encrypted_bytes: encrypted_bytes
            )

            # Return CDNMedia structure for use in sendmessage item_list.
            # encrypt_type: 1 confirmed from @tencent-weixin/openclaw-weixin source.
            {
              encrypt_query_param: download_param,
              aes_key:             aeskey_b64,
              encrypt_type:        1
            }
          end

          # POST encrypted bytes to CDN. Returns the x-encrypted-param header value.
          def cdn_upload(upload_param:, filekey:, encrypted_bytes:)
            cdn_url = "#{CDN_BASE_URL}/upload" \
                      "?encrypted_query_param=#{URI.encode_uri_component(upload_param)}" \
                      "&filekey=#{URI.encode_uri_component(filekey)}"
            uri = URI(cdn_url)

            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl      = true
            http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
            http.read_timeout = API_TIMEOUT_S
            http.open_timeout = 10

            req = Net::HTTP::Post.new("#{uri.path}?#{uri.query}")
            req["Content-Type"]   = "application/octet-stream"
            req["Content-Length"] = encrypted_bytes.bytesize.to_s
            req.body = encrypted_bytes

            Clacky::Logger.debug("[WeixinApiClient] CDN upload #{encrypted_bytes.bytesize} bytes")

            res = http.request(req)
            raise ApiError.new(res.code.to_i, res.body.to_s.slice(0, 200)), "CDN upload HTTP #{res.code}" \
              unless res.is_a?(Net::HTTPSuccess)

            download_param = res["x-encrypted-param"]
            raise ApiError.new(0, "CDN upload: missing x-encrypted-param header") unless download_param

            download_param
          end

          # GET raw bytes from a CDN URL (no iLink auth headers needed for download).
          def cdn_get(url)
            uri  = URI(url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl      = true
            http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
            http.read_timeout = API_TIMEOUT_S
            http.open_timeout = 10

            req = Net::HTTP::Get.new("#{uri.path}?#{uri.query}")
            Clacky::Logger.debug("[WeixinApiClient] CDN GET #{uri.host}#{uri.path}")

            res = http.request(req)
            raise ApiError.new(res.code.to_i, "CDN download HTTP #{res.code}") \
              unless res.is_a?(Net::HTTPSuccess)

            res.body.force_encoding("BINARY")
          end

          # Decrypt bytes with AES-128-ECB + PKCS7 unpadding using OpenSSL.
          def aes_ecb_decrypt(data, key)
            cipher = OpenSSL::Cipher.new("AES-128-ECB")
            cipher.decrypt
            cipher.key = key
            cipher.update(data) + cipher.final
          end

          # Encrypt bytes with AES-128-ECB + PKCS7 padding using OpenSSL.
          def aes_ecb_encrypt(data, key)
            cipher = OpenSSL::Cipher.new("AES-128-ECB")
            cipher.encrypt
            cipher.key = key
            cipher.update(data) + cipher.final
          end

          # Guess media_type from file extension.
          def detect_media_type(file_name)
            ext = File.extname(file_name).downcase
            case ext
            when ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"
              MEDIA_TYPE_IMAGE
            when ".mp4", ".mov", ".avi", ".mkv", ".flv"
              MEDIA_TYPE_VIDEO
            when ".mp3", ".m4a", ".amr", ".wav", ".ogg"
              MEDIA_TYPE_VOICE
            else
              MEDIA_TYPE_FILE
            end
          end

          # Build the item_list entry for sendmessage based on media type.
          def build_media_item(media_type, cdn_media, raw_bytes, file_name)
            case media_type
            when MEDIA_TYPE_IMAGE
              { type: 2, image_item: { media: cdn_media } }
            when MEDIA_TYPE_VIDEO
              { type: 5, video_item: { media: cdn_media } }
            when MEDIA_TYPE_VOICE
              { type: 3, voice_item: { media: cdn_media } }
            else
              {
                type: 4,
                file_item: {
                  media:     cdn_media,
                  file_name: file_name,
                  md5:       Digest::MD5.hexdigest(raw_bytes),
                  len:       raw_bytes.bytesize.to_s
                }
              }
            end
          end

          def post(endpoint, body_hash, timeout: API_TIMEOUT_S)
            uri  = URI("#{@base_url}/#{API_PATH_PREFIX}/#{endpoint}")
            # All POST bodies must include base_info per iLink protocol spec.
            body = JSON.generate(body_hash.merge(base_info: { channel_version: CHANNEL_VERSION }))

            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl      = uri.scheme == "https"
            http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
            http.read_timeout = timeout
            http.open_timeout = 10

            req = Net::HTTP::Post.new(uri.path)
            req["Content-Type"]      = "application/json"
            req["AuthorizationType"] = "ilink_bot_token"
            req["Content-Length"]    = body.bytesize.to_s
            req["X-WECHAT-UIN"]      = random_wechat_uin
            req["Authorization"]     = "Bearer #{@token}" unless @token.empty?
            req.body = body

            Clacky::Logger.debug("[WeixinApiClient] POST #{endpoint}")

            res = http.request(req)
            raise ApiError.new(res.code.to_i, res.body), "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

            data = JSON.parse(res.body)
            ret  = data["ret"] || data["errcode"]
            raise ApiError.new(ret, data["errmsg"]) if ret && ret != 0

            data
          rescue Net::ReadTimeout, Net::OpenTimeout
            raise TimeoutError, "#{endpoint} timed out"
          rescue JSON::ParserError => e
            raise ApiError.new(0, "Invalid JSON: #{e.message}")
          end

          # X-WECHAT-UIN: random uint32 → decimal string → base64
          def random_wechat_uin
            uint32 = SecureRandom.random_bytes(4).unpack1("N")
            Base64.strict_encode64(uint32.to_s)
          end
        end
      end
    end
  end
end
