# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "json"
require "net/http"
require "openssl"
require "securerandom"

module Clacky
  module Channel
    module Adapters
      module Feishu
        # Raised when the app lacks read permission for a specific Feishu document (error code 91403).
        # The user needs to add the app as a collaborator on the document.
        class FeishuDocPermissionError < StandardError
          attr_reader :doc_token

          def initialize(doc_token)
            @doc_token = doc_token
            super("App has no permission to access document: #{doc_token}")
          end
        end

        # Raised when the app hasn't been granted the API scope for documents (error code 99991672).
        # The admin needs to approve the scope via the returned auth_url.
        class FeishuDocScopeError < StandardError
          attr_reader :auth_url

          def initialize(auth_url)
            @auth_url = auth_url
            super("App is missing docx API scope")
          end
        end

        # Feishu Bot API client.
        # Handles authentication, message sending, and API calls.
        class Bot
          API_TIMEOUT = 10
          DOWNLOAD_TIMEOUT = 60

          def initialize(app_id:, app_secret:, domain: DEFAULT_DOMAIN)
            @app_id = app_id
            @app_secret = app_secret
            @domain = domain
            @token_cache = nil
            @token_expires_at = nil
          end

          # Send plain text message
          # @param chat_id [String] Chat ID (open_chat_id)
          # @param text [String] Message text
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] Response with :message_id
          def send_text(chat_id, text, reply_to: nil)
            content, msg_type = build_message_payload(text)
            payload = {
              receive_id: chat_id,
              msg_type: msg_type,
              content: content
            }
            payload[:reply_to_message_id] = reply_to if reply_to

            response = post("/open-apis/im/v1/messages", payload, params: { receive_id_type: "chat_id" })
            { message_id: response.dig("data", "message_id") }
          end

          # Update an existing message
          # @param message_id [String] Message ID to update
          # @param text [String] New text content
          # @return [Boolean] Success status
          def update_message(message_id, text)
            content, msg_type = build_message_payload(text)
            payload = {
              msg_type: msg_type,
              content: content
            }

            response = patch("/open-apis/im/v1/messages/#{message_id}", payload)
            response["code"] == 0
          rescue => e
            Clacky::Logger.warn("[feishu] Failed to update message: #{e.message}")
            false
          end

          # Upload an image to Feishu IM storage.
          # @param image_data [String] Raw binary image data
          # @param filename [String] Image filename (used for MIME detection)
          # @param image_type [String] "message" (default) or "avatar"
          # @return [String] image_key assigned by Feishu
          def upload_image(image_data, filename, image_type: "message")
            response = post_multipart("/open-apis/im/v1/images", {
              "image_type" => image_type,
              "image"      => [image_data, filename]
            })
            image_key = response.dig("data", "image_key")
            raise "Image upload failed: no image_key in response (#{response.inspect})" unless image_key
            image_key
          end

          # Upload a file to Feishu IM storage.
          # @param file_data [String] Raw binary file data
          # @param filename [String] Display filename
          # @param file_type [String] Feishu file type: "opus"|"mp4"|"pdf"|"doc"|"xls"|"ppt"|"stream"
          # @param duration [Integer, nil] Duration in milliseconds (for audio/video)
          # @return [String] file_key assigned by Feishu
          def upload_file(file_data, filename, file_type, duration: nil)
            fields = {
              "file_type" => file_type,
              "file_name" => filename,
              "file"      => [file_data, filename]
            }
            fields["duration"] = duration.to_s if duration
            response = post_multipart("/open-apis/im/v1/files", fields)
            file_key = response.dig("data", "file_key")
            raise "File upload failed: no file_key in response (#{response.inspect})" unless file_key
            file_key
          end

          # Send an image message to a chat.
          # @param chat_id [String] Chat ID
          # @param image_key [String] image_key from upload_image
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] { message_id: String }
          def send_image(chat_id, image_key, reply_to: nil)
            content = JSON.generate({ image_key: image_key })
            send_media_message(chat_id, "image", content, reply_to: reply_to)
          end

          # Send a file message to a chat.
          # @param chat_id [String] Chat ID
          # @param file_key [String] file_key from upload_file
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] { message_id: String }
          def send_file_message(chat_id, file_key, reply_to: nil)
            content = JSON.generate({ file_key: file_key })
            send_media_message(chat_id, "file", content, reply_to: reply_to)
          end

          # Send an audio message to a chat (renders as playable voice bubble).
          # @param chat_id [String] Chat ID
          # @param file_key [String] file_key from upload_file (opus type)
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] { message_id: String }
          def send_audio(chat_id, file_key, reply_to: nil)
            content = JSON.generate({ file_key: file_key })
            send_media_message(chat_id, "audio", content, reply_to: reply_to)
          end

          # Send a video message to a chat (renders as playable video).
          # @param chat_id [String] Chat ID
          # @param file_key [String] file_key from upload_file (mp4 type)
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] { message_id: String }
          def send_video(chat_id, file_key, reply_to: nil)
            content = JSON.generate({ file_key: file_key })
            send_media_message(chat_id, "media", content, reply_to: reply_to)
          end

          # Upload a local file to Feishu and send it to a chat.
          # Deprecated: use Adapter#send_file for full type detection (audio/video/image/file).
          # Kept for backward compatibility. Images use /im/v1/images, others use /im/v1/files.
          # @param chat_id [String] Chat ID
          # @param path [String] Local file path
          # @param name [String, nil] Display filename
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] Response with :message_id
          def send_file(chat_id, path, name: nil, reply_to: nil)
            raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

            filename  = name || File.basename(path)
            file_data = File.binread(path)
            ext       = File.extname(filename).downcase

            if %w[.jpg .jpeg .png .gif .webp].include?(ext)
              image_key = upload_image(file_data, filename)
              send_image(chat_id, image_key, reply_to: reply_to)
            else
              file_key = upload_file(file_data, filename, "stream")
              send_file_message(chat_id, file_key, reply_to: reply_to)
            end
          end

          # Download a message resource (image or file) from Feishu.
          # For message attachments, must use messageResource API — not im/v1/images.
          # @param message_id [String] Message ID containing the resource
          # @param file_key [String] Resource key (image_key or file_key from message content)
          # @param type [String] "image" or "file"
          # @return [Hash] { body: String, content_type: String }
          def download_message_resource(message_id, file_key, type: "image")
            conn = Faraday.new(url: @domain) do |f|
              f.options.timeout = DOWNLOAD_TIMEOUT
              f.options.open_timeout = API_TIMEOUT
              f.ssl.verify = false
              f.adapter Faraday.default_adapter
            end
            response = conn.get("/open-apis/im/v1/messages/#{message_id}/resources/#{file_key}") do |req|
              req.headers["Authorization"] = "Bearer #{tenant_access_token}"
              req.params["type"] = type
            end

            unless response.success?
              raise "Failed to download message resource: HTTP #{response.status}"
            end

            {
              body: response.body,
              content_type: response.headers["content-type"].to_s.split(";").first.strip
            }
          end

          # Fetch the plain-text content of a Feishu document (docx / docs / wiki).
          # Raises FeishuDocPermissionError (code 91403) when the app has no access.
          # @param url [String] Feishu document URL
          # @return [String] Document plain text
          def fetch_doc_content(url)
            doc_token, doc_type = parse_doc_url(url)
            raise ArgumentError, "Unsupported Feishu doc URL: #{url}" unless doc_token

            if doc_type == :wiki
              # Wiki: first resolve the real docToken via get_node
              node = fetch_wiki_node(doc_token)
              actual_token = node["obj_token"]
              actual_type  = node["obj_type"]   # "docx" / "doc" / etc.
              raise "Unsupported wiki node type: #{actual_type}" unless %w[docx doc].include?(actual_type)
              fetch_docx_raw_content(actual_token)
            else
              fetch_docx_raw_content(doc_token)
            end
          end

          private

          # Send a media message (image/file/audio/video) to a chat.
          # @param chat_id [String] Chat ID
          # @param msg_type [String] "image"|"file"|"audio"|"media"
          # @param content [String] JSON-encoded content string
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] { message_id: String }
          def send_media_message(chat_id, msg_type, content, reply_to: nil)
            payload = {
              receive_id: chat_id,
              msg_type:   msg_type,
              content:    content
            }
            payload[:reply_to_message_id] = reply_to if reply_to
            response = post("/open-apis/im/v1/messages", payload, params: { receive_id_type: "chat_id" })
            { message_id: response.dig("data", "message_id") }
          end

          # Post a multipart/form-data request to the Feishu API.
          # Used for file/image upload endpoints.
          # @param path [String] API path
          # @param fields [Hash] Form fields. Values are either String (plain) or
          #   Array [binary_data, filename] for file parts.
          # @return [Hash] Parsed JSON response
          def post_multipart(path, fields)
            require "net/http"
            require "uri"

            uri = URI.parse("#{@domain}#{path}")
            boundary = "----FeishuRubyBoundary#{SecureRandom.hex(16)}"

            body_parts = []
            fields.each do |name, value|
              if value.is_a?(Array)
                # File part: [binary_data, filename]
                binary_data, filename = value
                body_parts << "--#{boundary}\r\n"
                body_parts << "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n"
                body_parts << "Content-Type: application/octet-stream\r\n"
                body_parts << "\r\n"
                body_parts << binary_data
                body_parts << "\r\n"
              else
                # Plain text field
                body_parts << "--#{boundary}\r\n"
                body_parts << "Content-Disposition: form-data; name=\"#{name}\"\r\n"
                body_parts << "\r\n"
                body_parts << value.to_s
                body_parts << "\r\n"
              end
            end
            body_parts << "--#{boundary}--\r\n"

            # Build body string preserving binary encoding
            body = "".b
            body_parts.each do |part|
              body << part.b
            end

            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == "https")
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
            http.read_timeout = DOWNLOAD_TIMEOUT
            http.open_timeout = API_TIMEOUT

            request = Net::HTTP::Post.new(uri.request_uri)
            request["Authorization"] = "Bearer #{tenant_access_token}"
            request["Content-Type"]  = "multipart/form-data; boundary=#{boundary}"
            request.body = body

            response = http.request(request)
            unless response.is_a?(Net::HTTPSuccess)
              raise "Multipart upload failed: HTTP #{response.code} — #{response.body}"
            end

            JSON.parse(response.body)
          rescue JSON::ParserError => e
            raise "Failed to parse multipart upload response: #{e.message}"
          end

          # Build message content and type based on text content.
          # Uses interactive card (schema 2.0) for code blocks and tables,
          # post/md for everything else.
          # @param text [String]
          # @return [Array<String, String>] [content_json, msg_type]
          def build_message_payload(text)
            if has_code_block_or_table?(text)
              content = JSON.generate({
                schema: "2.0",
                config: { wide_screen_mode: true },
                body: { elements: [{ tag: "markdown", content: text }] }
              })
              [content, "interactive"]
            else
              content = JSON.generate({
                zh_cn: { content: [[{ tag: "md", text: text }]] }
              })
              [content, "post"]
            end
          end

          def has_code_block_or_table?(text)
            text.match?(/```[\s\S]*?```/) || text.match?(/\|.+\|[\r\n]+\|[-:| ]+\|/)
          end

          # Get tenant access token (cached)
          # @return [String] Access token
          def tenant_access_token
            return @token_cache if @token_cache && @token_expires_at && Time.now < @token_expires_at

            response = post_without_auth("/open-apis/auth/v3/tenant_access_token/internal", {
              app_id: @app_id,
              app_secret: @app_secret
            })

            raise "Failed to get tenant access token: #{response['msg']}" if response["code"] != 0

            @token_cache = response["tenant_access_token"]
            # Token expires in 2 hours, refresh 5 minutes early
            @token_expires_at = Time.now + (2 * 60 * 60 - 5 * 60)
            @token_cache
          end

          # Make authenticated GET request
          # @param path [String] API path
          # @param params [Hash] Query parameters
          # @return [Hash] Parsed response
          def get(path, params: {})
            conn = build_connection
            response = conn.get(path) do |req|
              req.headers["Authorization"] = "Bearer #{tenant_access_token}"
              req.params.update(params)
            end

            parse_response(response)
          end

          # Make authenticated POST request
          # @param path [String] API path
          # @param body [Hash] Request body
          # @param params [Hash] Query parameters
          # @return [Hash] Parsed response
          def post(path, body, params: {})
            conn = build_connection
            response = conn.post(path) do |req|
              req.headers["Authorization"] = "Bearer #{tenant_access_token}"
              req.headers["Content-Type"] = "application/json"
              req.params.update(params)
              req.body = JSON.generate(body)
            end

            parse_response(response)
          end

          # Make authenticated PATCH request
          # @param path [String] API path
          # @param body [Hash] Request body
          # @return [Hash] Parsed response
          def patch(path, body)
            conn = build_connection
            response = conn.patch(path) do |req|
              req.headers["Authorization"] = "Bearer #{tenant_access_token}"
              req.headers["Content-Type"] = "application/json"
              req.body = JSON.generate(body)
            end

            parse_response(response)
          end

          # Make POST request without authentication (for token endpoint)
          # @param path [String] API path
          # @param body [Hash] Request body
          # @return [Hash] Parsed response
          def post_without_auth(path, body)
            conn = build_connection
            response = conn.post(path) do |req|
              req.headers["Content-Type"] = "application/json"
              req.body = JSON.generate(body)
            end

            parse_response(response)
          end

          # Map file extension to Feishu file_type enum.
          # Feishu accepts: opus, mp4, pdf, doc, xls, ppt, stream (others)
          def feishu_file_type(filename)
            case File.extname(filename).downcase
            when ".pdf"             then "pdf"
            when ".doc", ".docx"   then "doc"
            when ".xls", ".xlsx"   then "xls"
            when ".ppt", ".pptx"   then "ppt"
            when ".mp4"            then "mp4"
            when ".opus"           then "opus"
            else                        "stream"
            end
          end

          # Detect MIME type from filename extension.
          def detect_mime(filename)
            case File.extname(filename).downcase
            when ".jpg", ".jpeg" then "image/jpeg"
            when ".png"          then "image/png"
            when ".gif"          then "image/gif"
            when ".webp"         then "image/webp"
            when ".pdf"          then "application/pdf"
            when ".mp4"          then "video/mp4"
            else                      "application/octet-stream"
            end
          end

          # Parse Feishu doc URL and return [doc_token, type]
          # type is :docx, :docs, or :wiki
          # @param url [String]
          # @return [Array<String, Symbol>, nil]
          def parse_doc_url(url)
            if (m = url.match(%r{/(?:docx|docs)/([A-Za-z0-9_-]+)}))
              [m[1], :docx]
            elsif (m = url.match(%r{/wiki/([A-Za-z0-9_-]+)}))
              [m[1], :wiki]
            end
          end

          # Fetch raw text content of a docx document.
          # Raises FeishuDocPermissionError on 91403.
          # @param doc_token [String]
          # @return [String]
          def fetch_docx_raw_content(doc_token)
            response = get("/open-apis/docx/v1/documents/#{doc_token}/raw_content")
            check_doc_error!(response, doc_token)
            response.dig("data", "content").to_s.strip
          end

          # Resolve wiki node to get real obj_token and obj_type.
          # @param wiki_token [String]
          # @return [Hash] node data with "obj_token" and "obj_type"
          def fetch_wiki_node(wiki_token)
            response = get("/open-apis/wiki/v2/spaces/get_node", params: { token: wiki_token, obj_type: "wiki" })
            check_doc_error!(response, wiki_token)
            response.dig("data", "node") or raise "No node in wiki response"
          end

          # Check doc API response for known permission errors and raise accordingly.
          def check_doc_error!(response, token)
            code = response["code"].to_i
            return if code == 0

            if code == 91403
              raise FeishuDocPermissionError, token
            elsif code == 99991672
              # Extract auth URL from the error message if present
              auth_url = response.dig("error", "permission_violations", 0, "attach_url") ||
                         response["msg"].to_s[/https:\/\/open\.feishu\.cn\/app\/[^\s"]+/]
              raise FeishuDocScopeError.new(auth_url)
            else
              raise "Failed to fetch doc: code=#{code} msg=#{response["msg"]}"
            end
          end

          # Build Faraday connection
          # @return [Faraday::Connection]
          def build_connection
            Faraday.new(url: @domain) do |f|
              f.options.timeout = API_TIMEOUT
              f.options.open_timeout = API_TIMEOUT
              f.ssl.verify = false
              f.adapter Faraday.default_adapter
            end
          end

          # Parse API response
          # @param response [Faraday::Response]
          # @return [Hash] Parsed JSON
          def parse_response(response)
            # Feishu returns JSON even on 4xx — parse it so callers can inspect error codes
            parsed = JSON.parse(response.body)
            return parsed if response.success? || parsed.key?("code")

            raise "API request failed: HTTP #{response.status} body=#{response.body.to_s[0..300]}"
          rescue JSON::ParserError
            raise "API request failed: HTTP #{response.status} body=#{response.body.to_s[0..300]}"
          end
        end
      end
    end
  end
end
