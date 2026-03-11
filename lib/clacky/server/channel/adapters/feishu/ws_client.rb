# frozen_string_literal: true

require "websocket/driver"
require "json"
require "net/http"
require "uri"

module Clacky
  module Channel
    module Adapters
      module Feishu
        # WebSocket client for Feishu long connection mode.
        # Feishu uses protobuf-encoded binary frames (pbbp2.Frame) over WebSocket.
        # Frame fields: SeqID(1), LogID(2), service(3), method(4), headers(5),
        #               payloadType(7), payload(8), LogIDNew(9)
        # method=0 → control (ping/pong/handshake), method=1 → data (event)
        class WSClient
          RECONNECT_DELAY = 5 # seconds

          def initialize(app_id:, app_secret:, domain: DEFAULT_DOMAIN)
            @app_id = app_id
            @app_secret = app_secret
            @domain = domain
            @running = false
            @ws = nil
            @ping_thread = nil
            @ping_interval = 90 # overridden by server config
            @seq_id = 0
            @service_id = 0
          end

          def start(&on_event)
            @running = true
            @on_event = on_event
            Clacky::Logger.info("[feishu-ws] Starting WebSocket client (app_id=#{@app_id})")

            while @running
              begin
                connect_and_listen
              rescue => e
                Clacky::Logger.warn("[feishu-ws] Connection error: #{e.message}")
                sleep RECONNECT_DELAY if @running
              end
            end
          end

          def stop
            @running = false
            @ping_thread&.kill
            @ws&.close
          end

          private

          def connect_and_listen
            Clacky::Logger.info("[feishu-ws] Fetching WebSocket endpoint...")
            endpoint = fetch_ws_endpoint
            Clacky::Logger.info("[feishu-ws] Connecting to #{endpoint.split("?").first}")
            uri = URI.parse(endpoint)

            port = uri.port || (uri.scheme == "wss" ? 443 : 80)
            tcp = TCPSocket.new(uri.host, port)

            socket = if uri.scheme == "wss"
              require "openssl"
              ssl_context = OpenSSL::SSL::SSLContext.new
              ssl_context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
              ssl = OpenSSL::SSL::SSLSocket.new(tcp, ssl_context)
              ssl.sync_close = true
              ssl.connect
              ssl
            else
              tcp
            end

            wrapper = SocketWrapper.new(socket, endpoint)
            @ws = WebSocket::Driver.client(wrapper)

            @ws.on :open do
              Clacky::Logger.info("[feishu-ws] WebSocket connected ✅")
            end

            @ws.on :message do |event|
              data = event.data
              handle_frame(data.respond_to?(:b) ? data.b : data)
            end

            @ws.on :error do |event|
              Clacky::Logger.warn("[feishu-ws] WebSocket error: #{event.message}")
            end

            @ws.on :close do |event|
              Clacky::Logger.info("[feishu-ws] WebSocket closed (code=#{event.code}), will reconnect")
            end

            @ws.start
            start_ping_thread

            loop do
              break unless @running
              data = socket.readpartial(4096)
              @ws.parse(data)
            end
          rescue EOFError, Errno::ECONNRESET
            Clacky::Logger.warn("[feishu-ws] Connection lost, reconnecting in #{RECONNECT_DELAY}s...")
          ensure
            socket&.close rescue nil
            @ping_thread&.kill
          end

          def fetch_ws_endpoint
            uri = URI.parse("#{@domain}/callback/ws/endpoint")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"

            request = Net::HTTP::Post.new(uri.path)
            request["Content-Type"] = "application/json"
            request["locale"] = "en"
            request.body = JSON.generate({ AppID: @app_id, AppSecret: @app_secret })

            response = http.request(request)
            data = JSON.parse(response.body)

            if data["code"] != 0
              Clacky::Logger.warn("[feishu-ws] Failed to get endpoint: code=#{data["code"]} msg=#{data["msg"]}")
              raise "Failed to get WebSocket endpoint: #{data['msg']}"
            end

            client_config = data.dig("data", "ClientConfig") || {}
            @ping_interval = (client_config["PingInterval"] || 90).to_i

            url = data.dig("data", "URL")
            if url =~ /service_id=(\d+)/
              @service_id = $1.to_i
            end
            url
          end

          # Parse and dispatch a Feishu protobuf binary frame
          def handle_frame(raw)
            raw = raw.b if raw.respond_to?(:b)
            frame = ProtoFrame.decode(raw)

            method_type = frame[:method]
            headers = frame[:headers] || {}

            case method_type
            when 0 # control frame
              handle_control_frame(frame, headers["type"])
            when 1 # data frame (event)
              Clacky::Logger.info("[feishu-ws] Received data frame (type=#{headers["type"]})")
              handle_data_frame(frame, headers)
            end
          rescue => e
            Clacky::Logger.warn("[feishu-ws] Failed to handle frame: #{e.message}")
          end

          def handle_control_frame(frame, msg_type)
            case msg_type
            when "ping"
              send_frame(
                seq_id: frame[:seq_id],
                log_id: frame[:log_id],
                service: frame[:service],
                method: 0,
                headers: frame[:headers].merge("type" => "pong")
              )
            when "handshake"
              status = frame[:headers]["handshake-status"]
              if status == "200"
                Clacky::Logger.info("[feishu-ws] Handshake successful ✅")
              else
                Clacky::Logger.warn("[feishu-ws] Handshake failed: #{frame[:headers]['handshake-msg']}")
              end
            end
          end

          def handle_data_frame(frame, headers)
            return unless headers["type"] == "event"

            payload_bytes = frame[:payload]
            return unless payload_bytes && !payload_bytes.empty?

            event_json = payload_bytes.force_encoding("UTF-8")
            event_data = JSON.parse(event_json)

            # Send ACK response
            send_frame(
              seq_id: frame[:seq_id],
              log_id: frame[:log_id],
              service: frame[:service],
              method: 1,
              headers: frame[:headers],
              payload: JSON.generate({ code: 200 })
            )

            event_type = event_data.dig("header", "event_type") || event_data["type"]
            Clacky::Logger.info("[feishu-ws] Dispatching event: #{event_type}")
            @on_event&.call(event_data)
          rescue JSON::ParserError => e
            Clacky::Logger.warn("[feishu-ws] Failed to parse event payload: #{e.message}")
          end

          def send_frame(seq_id:, log_id:, service:, method:, headers:, payload: nil)
            frame = {
              seq_id: seq_id,
              log_id: log_id,
              service: service,
              method: method,
              headers: headers,
              payload: payload
            }
            encoded = ProtoFrame.encode(frame)
            @ws.binary(encoded)
          rescue => e
            warn "[feishu-ws] failed to send frame: #{e.message}"
          end

          def start_ping_thread
            @ping_thread&.kill
            @ping_thread = Thread.new do
              loop do
                sleep @ping_interval
                break unless @running
                begin
                  @seq_id += 1
                  send_frame(
                    seq_id: @seq_id,
                    log_id: 0,
                    service: @service_id,
                    method: 0,
                    headers: { "type" => "ping" }
                  )
                rescue => e
                  warn "[feishu-ws] ping failed: #{e.message}"
                  break
                end
              end
            end
          end

          # Minimal protobuf encoder/decoder for pbbp2.Frame.
          # Fields: 1=SeqID(uint64), 2=LogID(uint64), 3=service(int32),
          #         4=method(int32), 5=headers(repeated msg{1=key,2=value}),
          #         8=payload(bytes)
          module ProtoFrame
            def self.encode(frame)
              buf = "".b
              buf << encode_varint(1, frame[:seq_id] || 0)
              buf << encode_varint(2, frame[:log_id] || 0)
              buf << encode_varint(3, frame[:service] || 0)
              buf << encode_varint(4, frame[:method] || 0)
              (frame[:headers] || {}).each do |k, v|
                header_bytes = encode_string(1, k.to_s) + encode_string(2, v.to_s)
                buf << encode_length_delimited(5, header_bytes)
              end
              if frame[:payload]
                payload_bytes = frame[:payload].respond_to?(:b) ? frame[:payload].b : frame[:payload].to_s.b
                buf << encode_length_delimited(8, payload_bytes)
              end
              buf
            end

            def self.decode(buf)
              buf = buf.b
              pos = 0
              result = { headers: {}, payload: "".b }

              while pos < buf.bytesize
                tag_byte, pos = read_varint(buf, pos)
                field_number = tag_byte >> 3
                wire_type = tag_byte & 0x7

                case wire_type
                when 0 # varint
                  val, pos = read_varint(buf, pos)
                  case field_number
                  when 1 then result[:seq_id] = val
                  when 2 then result[:log_id] = val
                  when 3 then result[:service] = val
                  when 4 then result[:method] = val
                  end
                when 2 # length-delimited
                  len, pos = read_varint(buf, pos)
                  bytes = buf.byteslice(pos, len)
                  pos += len
                  case field_number
                  when 5 # header entry
                    k, v = decode_header(bytes)
                    result[:headers][k] = v if k
                  when 7 then result[:payload_type] = bytes.force_encoding("UTF-8")
                  when 8 then result[:payload] = bytes
                  end
                else
                  break # unknown wire type, stop parsing
                end
              end

              result
            end

            def self.decode_header(buf)
              buf = buf.b
              pos = 0
              key = nil
              val = nil
              while pos < buf.bytesize
                tag_byte, pos = read_varint(buf, pos)
                field_number = tag_byte >> 3
                wire_type = tag_byte & 0x7
                if wire_type == 2
                  len, pos = read_varint(buf, pos)
                  bytes = buf.byteslice(pos, len)
                  pos += len
                  case field_number
                  when 1 then key = bytes.force_encoding("UTF-8")
                  when 2 then val = bytes.force_encoding("UTF-8")
                  end
                else
                  break
                end
              end
              [key, val]
            end

            def self.read_varint(buf, pos)
              result = 0
              shift = 0
              loop do
                byte = buf.getbyte(pos)
                raise "unexpected end of buffer at pos #{pos}" if byte.nil?
                pos += 1
                result |= (byte & 0x7F) << shift
                break unless byte & 0x80 != 0
                shift += 7
              end
              [result, pos]
            end

            def self.encode_varint(field_number, value)
              tag = (field_number << 3) | 0  # wire type 0
              encode_raw_varint(tag) + encode_raw_varint(value)
            end

            def self.encode_raw_varint(value)
              bytes = "".b
              loop do
                byte = value & 0x7F
                value >>= 7
                byte |= 0x80 if value > 0
                bytes << byte
                break if value == 0
              end
              bytes
            end

            def self.encode_string(field_number, str)
              bytes = str.encode("UTF-8").b
              encode_length_delimited(field_number, bytes)
            end

            def self.encode_length_delimited(field_number, bytes)
              tag = (field_number << 3) | 2  # wire type 2
              encode_raw_varint(tag) + encode_raw_varint(bytes.bytesize) + bytes
            end
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
