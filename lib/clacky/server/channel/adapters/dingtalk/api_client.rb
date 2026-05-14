# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Clacky
  module Channel
    module Adapters
      module DingTalk
        # DingTalk Bot API client — sends messages via session webhook (Stream Mode).
        class ApiClient
          OPENAPI_BASE = "https://api.dingtalk.com"

          def initialize(client_id:, client_secret:)
            @client_id     = client_id
            @client_secret = client_secret
            @token         = nil
            @token_expires_at = 0
          end

          # Send a text (or Markdown) message via the session webhook URL.
          # In Stream Mode, inbound events carry a `sessionWebhook` — use that directly.
          # @param webhook_url [String]
          # @param text [String]
          # @param msg_type [:text, :markdown] (default :text)
          def send_via_webhook(webhook_url, text, msg_type: :text)
            body = if msg_type == :markdown
              { msgtype: "markdown", markdown: { title: "Reply", text: text } }
            else
              { msgtype: "text", text: { content: text } }
            end

            uri = URI.parse(webhook_url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
            req.body = JSON.generate(body)
            resp = http.request(req)
            data = JSON.parse(resp.body) rescue {}
            if resp.code.to_i != 200 || (data["errcode"] && data["errcode"] != 0)
              Clacky::Logger.warn("[dingtalk] webhook send rejected (#{resp.code}): #{resp.body}")
            end
            data
          rescue => e
            Clacky::Logger.warn("[dingtalk] webhook send failed: #{e.message}")
            {}
          end

          # Fetch a short-lived access token (cached for its lifetime).
          def access_token
            return @token if @token && Time.now.to_i < @token_expires_at - 60

            uri  = URI.parse("#{OPENAPI_BASE}/v1.0/oauth2/accessToken")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            req = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
            req.body = JSON.generate({ appKey: @client_id, appSecret: @client_secret })

            resp = http.request(req)
            data = JSON.parse(resp.body)

            raise "DingTalk token error (#{resp.code}): #{data["message"] || resp.body}" unless resp.code.to_i == 200

            @token = data["accessToken"] || raise("Missing accessToken in response")
            @token_expires_at = Time.now.to_i + (data["expireIn"] || 7200).to_i
            @token
          end

          # Validate credentials by fetching a token.
          # @return [Hash] { ok: Boolean, error: String? }
          def test_connection
            access_token
            { ok: true, message: "DingTalk access token obtained" }
          rescue => e
            { ok: false, error: e.message }
          end
        end
      end
    end
  end
end
