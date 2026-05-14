# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  module Channel
    module Adapters
      module Discord
        class ApiClient
          DEFAULT_HOMEPAGE_URL = "https://discord.com"
          BASE_URL             = "#{DEFAULT_HOMEPAGE_URL}/api/v10/"

          class ApiError < StandardError; end

          def initialize(bot_token:)
            @bot_token = bot_token
            @conn = Faraday.new(url: BASE_URL) do |f|
              f.headers["Authorization"] = "Bot #{@bot_token}"
              f.headers["User-Agent"]    = self.class.user_agent
              f.request :multipart
              f.response :raise_error
              f.adapter Faraday.default_adapter
            end
          end

          def me
            request(:get, "users/@me")
          end

          def send_message(channel_id, content, reply_to: nil)
            payload = { content: content.to_s }
            payload[:message_reference] = { message_id: reply_to.to_s } if reply_to
            request(:post, "channels/#{channel_id}/messages", payload)
          end

          def edit_message(channel_id, message_id, content)
            request(:patch, "channels/#{channel_id}/messages/#{message_id}", { content: content.to_s })
          end

          def send_file(channel_id, path, name: nil)
            raise ArgumentError, "File not found: #{path}" unless File.exist?(path)
            filename = name || File.basename(path)
            payload  = { attachments: [{ id: 0, filename: filename }] }
            io       = Faraday::UploadIO.new(path, detect_mime(path), filename)

            res = @conn.post("channels/#{channel_id}/messages") do |req|
              req.body = { "payload_json" => JSON.generate(payload), "files[0]" => io }
            end
            parse_json(res.body)
          rescue Faraday::Error => e
            raise_api_error(e)
          end

          def download(url)
            res = Faraday.get(url)
            { body: res.body, content_type: res.headers["content-type"] }
          end

          # Discord requires User-Agent of the form "DiscordBot ($url, $versionNumber)".
          # Requests with an invalid UA may be blocked at Cloudflare.
          def self.user_agent
            url = (Clacky::BrandConfig.load.homepage_url rescue nil) || DEFAULT_HOMEPAGE_URL
            "DiscordBot (#{url}, #{Clacky::VERSION})"
          end

          private def request(verb, path, body = nil)
            res = @conn.run_request(verb, path, body ? JSON.generate(body) : nil,
                                    { "Content-Type" => "application/json" })
            parse_json(res.body)
          rescue Faraday::Error => e
            raise_api_error(e)
          end

          private def raise_api_error(err)
            status = err.response&.dig(:status)
            body   = err.response&.dig(:body).to_s
            parsed = (JSON.parse(body) rescue nil)
            msg    = (parsed.is_a?(Hash) && parsed["message"]) || err.message
            raise ApiError, "Discord API #{status}: #{msg}"
          end

          private def parse_json(body)
            return {} if body.to_s.empty?
            JSON.parse(body)
          rescue JSON::ParserError => e
            raise ApiError, "Invalid JSON response: #{e.message}"
          end

          private def detect_mime(path)
            case File.extname(path).downcase
            when ".jpg", ".jpeg" then "image/jpeg"
            when ".png"          then "image/png"
            when ".gif"          then "image/gif"
            when ".webp"         then "image/webp"
            when ".mp4"          then "video/mp4"
            when ".mp3"          then "audio/mpeg"
            when ".pdf"          then "application/pdf"
            when ".txt"          then "text/plain"
            when ".json"         then "application/json"
            else                      "application/octet-stream"
            end
          end
        end
      end
    end
  end
end
