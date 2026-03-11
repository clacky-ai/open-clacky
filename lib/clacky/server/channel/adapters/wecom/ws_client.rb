# frozen_string_literal: true

require "websocket/driver"
require "json"
require "uri"
require "securerandom"

module Clacky
  module Channel
    module Adapters
      module Wecom
        # WebSocket client for WeCom (Enterprise WeChat) intelligent robot long connection.
        # Protocol: plain JSON frames over wss://openws.work.weixin.qq.com
        #
        # Frame format: { cmd, headers: { req_id }, body }
        # Commands:
        #   aibot_subscribe      - auth (client → server)
        #   ping                 - heartbeat (client → server)
        #   aibot_msg_callback   - inbound message (server → client)
        #   aibot_respond_msg    - send reply (client → server)
        class WSClient
          WS_URL = "wss://openws.work.weixin.qq.com"
          HEARTBEAT_INTERVAL = 30 # seconds
          RECONNECT_DELAY = 5     # seconds

          def initialize(bot_id:, secret:, ws_url: WS_URL)
            @bot_id = bot_id
            @secret = secret
            @ws_url = ws_url
            @running = false
            @ws = nil
            @ping_thread = nil
          end

          def start(&on_message)
            @running = true
            @on_message = on_message

            while @running
              begin
                connect_and_listen
              rescue => e
                warn "WeCom WebSocket error: #{e.message}"
                sleep RECONNECT_DELAY if @running
              end
            end
          end

          def stop
            @running = false
            @ping_thread&.kill
            @ws&.close
          end

          # Proactively send a text message
          # @param chatid [String] chat ID
          # @param content [String] text content
          def send_message(chatid, content)
            send_frame(
              cmd: "aibot_send_msg",
              req_id: generate_req_id("send"),
              body: {
                chatid: chatid,
                msgtype: "markdown",
                markdown: { content: content }
              }
            )
          end

          private

          def connect_and_listen
            uri = URI.parse(@ws_url)
            port = uri.port || 443

            require "openssl"
            tcp = TCPSocket.new(uri.host, port)
            ssl_context = OpenSSL::SSL::SSLContext.new
            ssl_context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
            ssl = OpenSSL::SSL::SSLSocket.new(tcp, ssl_context)
            ssl.sync_close = true
            ssl.connect

            wrapper = SocketWrapper.new(ssl, @ws_url)
            @ws = WebSocket::Driver.client(wrapper)

            @ws.on :open do
              authenticate
              start_ping_thread
            end

            @ws.on :message do |event|
              handle_message(event.data)
            end

            @ws.on :error do |event|
              warn "WeCom WS error: #{event.message}"
            end

            @ws.on :close do
              # will reconnect
            end

            @ws.start

            loop do
              break unless @running
              data = ssl.readpartial(4096)
              @ws.parse(data)
            end
          rescue EOFError, Errno::ECONNRESET
            # connection lost, will reconnect
          ensure
            ssl&.close rescue nil
            @ping_thread&.kill
          end

          def authenticate
            send_frame(
              cmd: "aibot_subscribe",
              req_id: generate_req_id("subscribe"),
              body: { bot_id: @bot_id, secret: @secret }
            )
          end

          def handle_message(data)
            frame = JSON.parse(data)
            cmd = frame["cmd"]
            body = frame["body"] || {}
            req_id = frame.dig("headers", "req_id") || ""

            case cmd
            when "aibot_msg_callback"
              @on_message&.call(body.merge("_req_id" => req_id))
            when "aibot_event_callback"
              # ignore events for now
            when nil
              # auth/heartbeat ack — check for errors
              errcode = frame["errcode"] || body["errcode"]
              if errcode && errcode != 0
                warn "WeCom WS error response: #{frame.inspect}"
              end
            end
          rescue JSON::ParserError => e
            warn "WeCom WS failed to parse message: #{e.message}"
          end

          def send_frame(cmd:, req_id:, body: nil)
            frame = { cmd: cmd, headers: { req_id: req_id } }
            frame[:body] = body if body
            @ws.text(JSON.generate(frame))
          rescue => e
            warn "WeCom WS failed to send frame: #{e.message}"
          end

          def start_ping_thread
            @ping_thread&.kill
            @ping_thread = Thread.new do
              loop do
                sleep HEARTBEAT_INTERVAL
                break unless @running
                send_frame(cmd: "ping", req_id: generate_req_id("ping"))
              end
            end
          end

          def generate_req_id(prefix)
            "#{prefix}_#{SecureRandom.hex(8)}"
          end

          # Wraps a raw socket for websocket-driver client mode.
          class SocketWrapper
            attr_reader :url

            def initialize(socket, url)
              @socket = socket
              @url = url
            end

            def write(data)
              @socket.write(data)
            end
          end
        end
      end
    end
  end
end
