# frozen_string_literal: true

require "json"

module Clacky
  module Channel
    module Adapters
      module Feishu
        # Parses incoming Feishu webhook events into a standardized InboundMessage format.
        class MessageParser
          # Parse a Feishu webhook event body
          # @param body [String, Hash] Raw webhook body
          # @return [Hash, nil] Standardized inbound message, or nil if not a message event
          def self.parse(body)
            data = body.is_a?(Hash) ? body : JSON.parse(body)
            new(data).parse
          rescue JSON::ParserError
            nil
          end

          def initialize(data)
            @data = data
          end

          # @return [Hash, nil] Inbound message or nil
          def parse
            # Handle verification challenge
            if @data["type"] == "url_verification"
              return { type: :challenge, challenge: @data["challenge"] }
            end

            header = @data["header"]
            return nil unless header

            event_type = header["event_type"]

            case event_type
            when "im.message.receive_v1"
              parse_message_event
            else
              nil
            end
          end

          private

          # Parse message.receive event
          # @return [Hash, nil]
          def parse_message_event
            event = @data["event"]
            return nil unless event

            message = event["message"]
            sender = event["sender"]
            return nil unless message && sender

            # Only handle text messages for now
            msg_type = message["message_type"]
            return nil unless msg_type == "text"

            # Parse message content
            content_raw = message["content"]
            return nil unless content_raw

            content = JSON.parse(content_raw)
            text = content["text"].to_s.strip
            return nil if text.empty?

            # Remove @bot mentions from text
            text = strip_mentions(text)
            return nil if text.strip.empty?

            chat_id = message["chat_id"]
            message_id = message["message_id"]
            user_id = sender.dig("sender_id", "open_id")
            chat_type = message["chat_type"] == "p2p" ? :direct : :group
            create_time = message["create_time"]&.to_i
            timestamp = create_time ? Time.at(create_time / 1000.0) : Time.now

            {
              type: :message,
              platform: :feishu,
              chat_id: chat_id,
              user_id: user_id,
              text: text,
              message_id: message_id,
              timestamp: timestamp,
              chat_type: chat_type,
              raw: @data
            }
          rescue JSON::ParserError
            nil
          end

          # Strip bot @mentions from message text
          # @param text [String]
          # @return [String]
          def strip_mentions(text)
            # Feishu mentions are formatted as <at user_id="...">Name</at>
            text.gsub(/<at[^>]*>.*?<\/at>/, "").strip
          end
        end
      end
    end
  end
end
