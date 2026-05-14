# frozen_string_literal: true

require "websocket"
require "json"
require "net/http"
require "uri"

module Clacky
  module Channel
    module Adapters
      module DingTalk
        DINGTALK_API_BASE = "https://api.dingtalk.com"
        RECONNECT_DELAY   = 5

        # WebSocket Stream Mode client for DingTalk.
        # DingTalk Stream Mode uses JSON frames (unlike Feishu's protobuf).
        # Frame shape:
        #   { "specVersion": "1.0", "type": "SYSTEM"|"EVENT"|"CALLBACK",
        #     "headers": { "messageId": "...", "time": "...", "topic": "...", ... },
        #     "data": "..." }
        class StreamClient
          def initialize(client_id:, client_secret:)
            @client_id     = client_id
            @client_secret = client_secret
            @running       = false
          end

          def start(&on_event)
            @running  = true
            @on_event = on_event
            Clacky::Logger.info("[dingtalk-ws] Starting stream client (client_id=#{@client_id})")

            while @running
              begin
                connect_and_listen
              rescue => e
                Clacky::Logger.warn("[dingtalk-ws] Connection error: #{e.class}: #{e.message}")
                sleep RECONNECT_DELAY if @running
              end
            end
          end

          def stop
            @running = false
            @ws_socket&.close rescue nil
          end

          private def connect_and_listen
            Clacky::Logger.info("[dingtalk-ws] Fetching stream endpoint...")
            endpoint, ticket = fetch_stream_endpoint
            full_url = "#{endpoint}?ticket=#{ticket}"
            Clacky::Logger.info("[dingtalk-ws] Connecting to #{endpoint}")

            uri  = URI.parse(full_url)
            port = uri.port || 443
            tcp  = TCPSocket.new(uri.host, port)

            socket = begin
              require "openssl"
              ctx = OpenSSL::SSL::SSLContext.new
              ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
              ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
              ssl.hostname = uri.host
              ssl.sync_close = true
              ssl.connect
              ssl
            end

            handshake = WebSocket::Handshake::Client.new(url: full_url)
            socket.write(handshake.to_s)
            until handshake.finished?
              handshake << socket.readpartial(4096)
            end
            raise "WebSocket handshake failed" unless handshake.valid?

            Clacky::Logger.info("[dingtalk-ws] WebSocket connected")
            @ws_version = handshake.version
            @ws_socket  = socket
            @incoming   = WebSocket::Frame::Incoming::Client.new(version: @ws_version)

            loop do
              break unless @running

              ready = IO.select([socket], nil, nil, 120)
              unless ready
                Clacky::Logger.warn("[dingtalk-ws] read timeout, reconnecting...")
                return
              end

              data = socket.read_nonblock(4096)
              @incoming << data
              while (frame = @incoming.next)
                case frame.type
                when :text   then handle_frame(frame.data)
                when :ping   then send_frame(:pong, frame.data)
                when :close
                  Clacky::Logger.info("[dingtalk-ws] Server closed connection, will reconnect")
                  return
                end
              end
            end
          rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE,
                 Errno::ETIMEDOUT, OpenSSL::SSL::SSLError => e
            raise
          ensure
            @ws_socket = nil
            socket&.close rescue nil
          end

          private def fetch_stream_endpoint
            uri  = URI.parse("#{DINGTALK_API_BASE}/v1.0/gateway/connections/open")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true

            req = Net::HTTP::Post.new(uri.path)
            req["Content-Type"]  = "application/json"
            req["Accept"]        = "application/json"
            req.body = JSON.generate({
              clientId:     @client_id,
              clientSecret: @client_secret,
              subscriptions: [
                { type: "CALLBACK", topic: "/v1.0/im/bot/messages/get" }
              ],
              ua:      self.class.client_identifier,
              localIp: "127.0.0.1"
            })

            resp = http.request(req)
            data = JSON.parse(resp.body)

            unless resp.code.to_i == 200
              raise "Stream endpoint error (#{resp.code}): #{data["message"] || resp.body}"
            end

            endpoint = data.dig("endpoint") || raise("Missing endpoint in response")
            ticket   = data.dig("ticket")   || ""
            [endpoint, ticket]
          end

          def self.client_identifier
            name = Clacky::BrandConfig.load.product_name
            name = "OpenClacky" if name.nil? || name.strip.empty?
            "#{name.strip}/#{Clacky::VERSION}"
          end

          private def handle_frame(json_text)
            frame = JSON.parse(json_text)
            type  = frame["type"]

            case type
            when "SYSTEM"
              handle_system(frame)
            when "EVENT", "CALLBACK"
              send_ack(frame)
              @on_event&.call(frame)
            end
          rescue JSON::ParserError => e
            Clacky::Logger.warn("[dingtalk-ws] JSON parse error: #{e.message}")
          end

          private def handle_system(frame)
            topic = frame.dig("headers", "topic").to_s
            case topic
            when "ping"
              pong = frame.merge("type" => "SYSTEM",
                                 "headers" => frame["headers"].merge("topic" => "pong"))
              send_text(JSON.generate(pong))
              Clacky::Logger.info("[dingtalk-ws] pong sent")
            when "disconnect"
              Clacky::Logger.warn("[dingtalk-ws] Server requested disconnect, will reconnect")
              @ws_socket&.close rescue nil
            end
          end

          private def send_ack(frame)
            ack = {
              "code"    => 200,
              "headers" => {
                "messageId" => frame.dig("headers", "messageId"),
                "topic"     => "ack"
              },
              "message" => "OK",
              "data"    => ""
            }
            send_text(JSON.generate(ack))
          end

          private def send_frame(type, data)
            return unless @ws_socket
            outgoing = WebSocket::Frame::Outgoing::Client.new(
              version: @ws_version || 13,
              data:    data,
              type:    type
            )
            @ws_socket.write(outgoing.to_s)
          end

          private def send_text(text)
            send_frame(:text, text)
          end
        end
      end
    end
  end
end
