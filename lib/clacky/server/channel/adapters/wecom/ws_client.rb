# frozen_string_literal: true

require "websocket"
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

          # Raised when WeCom rejects credentials — signals caller not to retry.
          class AuthError < StandardError; end

          def initialize(bot_id:, secret:, ws_url: WS_URL)
            @bot_id = bot_id
            @secret = secret
            @ws_url = ws_url
            @running = false
            @ws = nil
            @ping_thread = nil
            @mutex = Mutex.new
            @pending_acks = {}
          end

          def start(&on_message)
            @running = true
            @on_message = on_message

            while @running
              begin
                connect_and_listen
              rescue AuthError => e
                Clacky::Logger.error("[WecomWSClient] Authentication failed (not retrying): #{e.message}")
                @running = false
                raise
              rescue => e
                Clacky::Logger.error("[WecomWSClient] WebSocket error: #{e.message}")
                sleep RECONNECT_DELAY if @running
              end
            end
          end

          def stop
            @running = false
            @ping_thread&.kill
            send_raw_frame(:close, "") rescue nil
            @ws_socket&.close rescue nil
          end

          # Proactively send a text message
          # @param chatid [String] chat ID
          # @param content [String] text content
          def send_message(chatid, content)
            Clacky::Logger.info("[WecomWSClient] send_message chat=#{chatid} length=#{content.length}")
            send_frame_and_wait(
              cmd: "aibot_send_msg",
              req_id: generate_req_id("send"),
              body: {
                chatid: chatid,
                msgtype: "markdown",
                markdown: { content: content }
              }
            )
          end

          # Upload a local file as a temporary media asset and send it to a chat.
          # Uses the three-step chunked upload protocol:
          #   aibot_upload_media_init → aibot_upload_media_chunk × N → aibot_upload_media_finish
          # Then sends the resulting media_id via aibot_send_msg.
          #
          # @param chatid   [String] target chat ID
          # @param path     [String] absolute path to the local file
          # @param name     [String, nil] display filename (defaults to File.basename(path))
          # @param type     [String] media type — "file" or "image"
          def send_file(chatid, path, name: nil, type: nil)
            Clacky::Logger.info("[WecomWSClient] send_file chat=#{chatid} path=#{path}")
            raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

            data      = File.binread(path)
            filename  = name || File.basename(path)
            media_type = type || detect_media_type(path)

            Clacky::Logger.info("[WecomWSClient] uploading #{filename} (#{data.bytesize} bytes, type=#{media_type})")
            media_id = upload_media(data, filename: filename, type: media_type)
            Clacky::Logger.info("[WecomWSClient] upload done media_id=#{media_id}")

            req_id = generate_req_id("send_file")
            send_frame_and_wait(
              cmd: "aibot_send_msg",
              req_id: req_id,
              body: {
                chatid: chatid,
                msgtype: media_type,
                media_type => { media_id: media_id }
              }
            )
            Clacky::Logger.info("[WecomWSClient] send_file frame sent chat=#{chatid} filename=#{filename}")
          rescue => e
            Clacky::Logger.error("[WecomWSClient] send_file failed (#{File.basename(path)}): #{e.message}")
            raise
          end


          # Timeout for IO.select on the read loop. If no data arrives within this
          # window we treat the connection as dead and reconnect. This catches the
          # silent-drop case where the TCP stack never delivers a FIN/RST (e.g.
          # NAT timeout, firewall idle-kill). The WeCom server sends pings every
          # ~30 s, so 75 s gives two missed pings before we give up.
          READ_TIMEOUT_S = 75

          def connect_and_listen
            uri = URI.parse(@ws_url)
            port = uri.port || 443

            Clacky::Logger.info("[WecomWSClient] connecting to #{uri.host}:#{port}")

            require "openssl"
            tcp = TCPSocket.new(uri.host, port)
            ssl_context = OpenSSL::SSL::SSLContext.new
            ssl_context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
            ssl = OpenSSL::SSL::SSLSocket.new(tcp, ssl_context)
            ssl.sync_close = true
            ssl.connect

            # WebSocket handshake
            handshake = WebSocket::Handshake::Client.new(url: @ws_url)
            ssl.write(handshake.to_s)

            until handshake.finished?
              handshake << ssl.readpartial(4096)
            end
            raise "WebSocket handshake failed" unless handshake.valid?

            Clacky::Logger.info("[WecomWSClient] connected, authenticating")
            @ws_version = handshake.version
            @ws_socket  = ssl
            @ws_open    = true
            @incoming   = WebSocket::Frame::Incoming::Client.new(version: @ws_version)

            authenticate
            start_ping_thread

            loop do
              break unless @running

              # Use IO.select with a timeout so we detect silent connection drops
              # (e.g. NAT expiry) that never deliver a TCP FIN/RST. Without this,
              # readpartial blocks forever and the thread hangs permanently.
              ready = IO.select([ssl], nil, nil, READ_TIMEOUT_S)
              unless ready
                Clacky::Logger.warn("[WecomWSClient] read timeout (#{READ_TIMEOUT_S}s), reconnecting...")
                return
              end

              data = ssl.read_nonblock(4096)
              @incoming << data
              while (frame = @incoming.next)
                case frame.type
                when :text
                  handle_message(frame.data)
                when :ping
                  send_raw_frame(:pong, frame.data)
                when :close
                  Clacky::Logger.info("[WecomWSClient] connection closed by server")
                  return
                end
              end
            end
          rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE,
                 Errno::ETIMEDOUT, OpenSSL::SSL::SSLError => e
            Clacky::Logger.info("[WecomWSClient] connection lost (#{e.class}: #{e.message}), reconnecting...")
          ensure
            @ws_open = false
            @ws_socket = nil
            ssl&.close rescue nil
            @ping_thread&.kill
          end

          def authenticate
            Clacky::Logger.info("[WecomWSClient] sending auth (bot_id=#{@bot_id})")
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

            # Dispatch ack to any waiting send_frame_and_wait caller
            if req_id && !req_id.empty?
              queue = @mutex.synchronize { @pending_acks&.[](req_id) }
              if queue
                queue.push(frame)
                return
              end
            end

            case cmd
            when "aibot_msg_callback"
              Clacky::Logger.info("[WecomWSClient] inbound message req_id=#{req_id}")
              cb_body = body.merge("_req_id" => req_id)
              Thread.new { @on_message&.call(cb_body) }
            when "aibot_event_callback"
              Clacky::Logger.info("[WecomWSClient] event_callback (ignored)")
            when nil
              errcode = frame["errcode"] || body["errcode"]
              if errcode && errcode != 0
                Clacky::Logger.error("[WecomWSClient] error response: #{frame.inspect}")
                if req_id.start_with?("subscribe_")
                  errmsg = frame["errmsg"] || body["errmsg"] || "unknown error"
                  @running = false
                  raise AuthError, "WeCom authentication failed (errcode=#{errcode}): #{errmsg}"
                end
              else
                if req_id.start_with?("ping_")
                  Clacky::Logger.debug("[WecomWSClient] ack/heartbeat req_id=#{req_id}")
                else
                  Clacky::Logger.info("[WecomWSClient] ack/heartbeat req_id=#{req_id}")
                end
              end
            else
              Clacky::Logger.info("[WecomWSClient] unknown cmd=#{cmd}")
            end
          rescue JSON::ParserError => e
            Clacky::Logger.error("[WecomWSClient] failed to parse message: #{e.message}")
          end

          def send_frame(cmd:, req_id:, body: nil)
            frame = { cmd: cmd, headers: { req_id: req_id } }
            frame[:body] = body if body
            if cmd == "ping"
              Clacky::Logger.debug("[WecomWSClient] >> cmd=#{cmd} req_id=#{req_id}")
            else
              Clacky::Logger.info("[WecomWSClient] >> cmd=#{cmd} req_id=#{req_id}")
            end
            send_raw_frame(:text, JSON.generate(frame))
          rescue => e
            Clacky::Logger.error("[WecomWSClient] failed to send frame cmd=#{cmd}: #{e.message}")
          end

          def send_raw_frame(type, data)
            return unless @ws_socket && @ws_open
            outgoing = WebSocket::Frame::Outgoing::Client.new(
              version: @ws_version || 13,
              data: data,
              type: type
            )
            @ws_socket.write(outgoing.to_s)
          end

          def start_ping_thread
            @ping_thread&.kill
            @ping_thread = Thread.new do
              loop do
                sleep HEARTBEAT_INTERVAL
                break unless @running
                begin
                  send_frame(cmd: "ping", req_id: generate_req_id("ping"))
                rescue => e
                  Clacky::Logger.warn("[WecomWSClient] ping failed (#{e.class}: #{e.message}), forcing reconnect")
                  # Close the socket so IO.select in the read loop immediately
                  # returns nil / read_nonblock raises IOError, triggering reconnect.
                  @ws_socket&.close rescue nil
                  break
                end
              end
            end
          end

          def generate_req_id(prefix)
            "#{prefix}_#{SecureRandom.hex(8)}"
          end

          CHUNK_SIZE = 512 * 1024  # 512 KB per chunk (before Base64)
          MAX_CHUNKS = 100

          # Three-step chunked media upload over WebSocket.
          # Returns media_id on success.
          def upload_media(data, filename:, type: "file")
            require "base64"
            require "digest"

            total_size   = data.bytesize
            total_chunks = (total_size.to_f / CHUNK_SIZE).ceil
            total_chunks = 1 if total_chunks == 0
            raise ArgumentError, "File too large: #{total_chunks} chunks (max #{MAX_CHUNKS})" if total_chunks > MAX_CHUNKS

            md5 = Digest::MD5.hexdigest(data)

            Clacky::Logger.info("[WecomWSClient] upload_media_init filename=#{filename} size=#{total_size} chunks=#{total_chunks} md5=#{md5}")

            # Step 1: init
            init_req_id = generate_req_id("upload_init")
            init_result = send_frame_and_wait(
              cmd: "aibot_upload_media_init",
              req_id: init_req_id,
              body: { type: type, filename: filename, total_size: total_size, total_chunks: total_chunks, md5: md5 }
            )
            upload_id = init_result.dig("body", "upload_id")
            raise "upload_media init failed: #{init_result.inspect}" unless upload_id
            Clacky::Logger.info("[WecomWSClient] upload_id=#{upload_id}")

            # Step 2: chunks
            total_chunks.times do |i|
              chunk_start = i * CHUNK_SIZE
              chunk       = data[chunk_start, CHUNK_SIZE]
              b64         = Base64.strict_encode64(chunk)

              Clacky::Logger.info("[WecomWSClient] uploading chunk #{i + 1}/#{total_chunks}")
              chunk_req_id = generate_req_id("upload_chunk")
              send_frame_and_wait(
                cmd: "aibot_upload_media_chunk",
                req_id: chunk_req_id,
                body: { upload_id: upload_id, chunk_index: i, base64_data: b64 }
              )
            end

            # Step 3: finish
            Clacky::Logger.info("[WecomWSClient] upload_media_finish upload_id=#{upload_id}")
            finish_req_id = generate_req_id("upload_finish")
            finish_result = send_frame_and_wait(
              cmd: "aibot_upload_media_finish",
              req_id: finish_req_id,
              body: { upload_id: upload_id }
            )
            media_id = finish_result.dig("body", "media_id")
            raise "upload_media finish failed: #{finish_result.inspect}" unless media_id

            media_id
          end

          # Send a frame and block until an ack frame with the same req_id arrives.
          # Timeout after 30s. Returns the ack frame hash.
          def send_frame_and_wait(cmd:, req_id:, body: nil)
            queue = Queue.new

            @mutex.synchronize do
              @pending_acks ||= {}
              @pending_acks[req_id] = queue
            end

            send_frame(cmd: cmd, req_id: req_id, body: body)

            result = queue.pop(timeout: 30)
            raise "Timeout waiting for ack (req_id=#{req_id}, cmd=#{cmd})" if result.nil?

            errcode = result["errcode"] || result.dig("body", "errcode")
            if errcode && errcode != 0
              errmsg = result["errmsg"] || result.dig("body", "errmsg") || "unknown"
              raise "WeCom API error #{errcode}: #{errmsg} (cmd=#{cmd})"
            end

            result
          ensure
            @mutex.synchronize { @pending_acks&.delete(req_id) }
          end

          # Detect media type from file extension
          def detect_media_type(path)
            case File.extname(path).downcase
            when ".jpg", ".jpeg", ".png", ".gif", ".webp" then "image"
            when ".mp4", ".avi", ".mov", ".mkv"           then "video"
            when ".mp3", ".wav", ".amr", ".m4a"           then "voice"
            else "file"
            end
          end


        end
      end
    end
  end
end
