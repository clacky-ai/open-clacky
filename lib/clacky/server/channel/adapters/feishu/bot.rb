# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "json"

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

            code = response["code"]
            if code != 0
              Clacky::Logger.warn("[feishu] send_text failed",
                code: code, msg: response["msg"],
                chat_id: chat_id, msg_type: msg_type)
            end

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

          # Upload a local file to Feishu and send it to a chat.
          # Images use /im/v1/images + msg_type "image".
          # All other files use /im/v1/files + msg_type "file".
          # @param chat_id [String] Chat ID
          # @param path [String] Local file path
          # @param name [String, nil] Display filename
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] Response with :message_id
          def send_file(chat_id, path, name: nil, reply_to: nil)
            raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

            # Always derive filename from the real path for type detection and upload.
            # The `name` param (often markdown alt text) may lack an extension,
            # causing images to be mis-detected as generic files.
            filename  = File.basename(path)
            file_data = File.binread(path)
            ext       = File.extname(filename).downcase

            if %w[.jpg .jpeg .png .gif .webp].include?(ext)
              image_key = upload_image(file_data, filename)
              content   = JSON.generate({ image_key: image_key })
              msg_type  = "image"
            else
              file_key = upload_file(file_data, filename)
              content  = JSON.generate({ file_key: file_key })
              msg_type = "file"
            end

            payload = { receive_id: chat_id, msg_type: msg_type, content: content }
            payload[:reply_to_message_id] = reply_to if reply_to

            response = post("/open-apis/im/v1/messages", payload, params: { receive_id_type: "chat_id" })
            { message_id: response.dig("data", "message_id") }
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


          # Build message content and type based on text content.
          # Uses interactive card (schema 2.0) for code blocks and tables,
          # post/md for everything else.
          # @param text [String]
          # @return [Array<String, String>] [content_json, msg_type]
          def build_message_payload(text)
            if has_code_block_or_table?(text)
              safe_text = sanitize_images_for_card(text)
              content = JSON.generate({
                schema: "2.0",
                config: { wide_screen_mode: true },
                body: { elements: [{ tag: "markdown", content: safe_text }] }
              })
              [content, "interactive"]
            else
              safe_text = sanitize_images_for_card(text)
              content = JSON.generate({
                zh_cn: { content: [[{ tag: "md", text: safe_text }]] }
              })
              [content, "post"]
            end
          end

          def has_code_block_or_table?(text)
            text.match?(/```[\s\S]*?```/) || text.match?(/\|.+\|[\r\n]+\|[-:| ]+\|/)
          end

          # Convert Markdown image syntax ![alt](url) to plain links [alt](url)
          # inside interactive card content.  Feishu interactive cards do NOT
          # support image markdown — sending it triggers error 230099 and the
          # entire message is silently dropped.
          #
          # Code blocks are preserved untouched (images inside ``` fences are
          # left as-is since they are literal text, not rendered markdown).
          #
          # This is a pure function with no side effects — thread-safe by design.
          # @param text [String] raw markdown text
          # @return [String] sanitised text safe for interactive cards
          def sanitize_images_for_card(text)
            # Split on code fences to avoid transforming inside code blocks
            parts = text.split(/(```[\s\S]*?```)/)
            parts.map { |segment|
              if segment.start_with?("```")
                segment  # code block — leave untouched
              else
                # ![alt](url) → [alt](url)   (drop the leading !)
                segment.gsub(/!\[([^\]]*)\]\(([^)]+)\)/) do
                  alt, url = Regexp.last_match(1), Regexp.last_match(2)
                  alt.empty? ? url : "[#{alt}](#{url})"
                end
              end
            }.join
          end

          # Get this bot's own open_id (cached, fetched lazily on first use).
          # Used to detect @bot mentions in group chats.
          # @return [String, nil] bot open_id, or nil if the API call fails
          def bot_open_id
            @bot_open_id ||= get("/open-apis/bot/v3/info").dig("bot", "open_id")
          rescue => e
            Clacky::Logger.warn("[feishu] Failed to fetch bot_open_id: #{e.message}")
            nil
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

          # Upload an image to Feishu and return image_key.
          # @param data [String] Binary file content
          # @param filename [String] Display filename
          # @return [String] image_key
          def upload_image(data, filename)
            conn = Faraday.new(url: @domain) do |f|
              f.options.timeout = DOWNLOAD_TIMEOUT
              f.options.open_timeout = API_TIMEOUT
              f.ssl.verify = false
              f.request :multipart
              f.adapter Faraday.default_adapter
            end

            response = conn.post("/open-apis/im/v1/images") do |req|
              req.headers["Authorization"] = "Bearer #{tenant_access_token}"
              req.body = {
                image_type: "message",
                image: Faraday::Multipart::FilePart.new(
                  StringIO.new(data), detect_mime(filename), filename
                )
              }
            end

            result = JSON.parse(response.body)
            raise "Failed to upload image: code=#{result["code"]} msg=#{result["msg"]}" if result["code"] != 0

            result.dig("data", "image_key") or raise "No image_key returned"
          end

          # Upload a file to Feishu and return file_key.
          # @param data [String] Binary file content
          # @param filename [String] Display filename
          # @return [String] file_key
          def upload_file(data, filename)
            conn = Faraday.new(url: @domain) do |f|
              f.options.timeout = DOWNLOAD_TIMEOUT
              f.options.open_timeout = API_TIMEOUT
              f.ssl.verify = false
              f.request :multipart
              f.adapter Faraday.default_adapter
            end

            response = conn.post("/open-apis/im/v1/files") do |req|
              req.headers["Authorization"] = "Bearer #{tenant_access_token}"
              req.body = {
                file_type: feishu_file_type(filename),
                file_name: filename,
                file: Faraday::Multipart::FilePart.new(
                  StringIO.new(data), detect_mime(filename), filename
                )
              }
            end

            result = JSON.parse(response.body)
            raise "Failed to upload file: code=#{result["code"]} msg=#{result["msg"]}" if result["code"] != 0

            result.dig("data", "file_key") or raise "No file_key returned"
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
