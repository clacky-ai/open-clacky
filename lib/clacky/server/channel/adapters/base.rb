# frozen_string_literal: true

module Clacky
  module Channel
    module Adapters
      # Adapter registry: maps platform symbol → adapter class.
      # Each adapter registers itself by calling Adapters.register at load time.
      @registry = {}

      def self.register(platform, klass)
        @registry[platform] = klass
      end

      def self.find(platform)
        @registry[platform.to_sym]
      end

      def self.all
        @registry.values
      end

      # Base adapter interface for IM platforms.
      # Subclasses must implement every abstract method below.
      class Base
        # @return [Symbol] e.g. :feishu, :wecom
        def self.platform_id
          raise NotImplementedError, "#{self} must implement .platform_id"
        end

        # Map raw config hash (from ChannelConfig) to symbol-keyed platform config.
        # @param raw [Hash] symbol-keyed raw config
        # @return [Hash]
        def self.platform_config(raw)
          raise NotImplementedError, "#{self} must implement .platform_config"
        end

        # @return [Symbol]
        def platform_id
          self.class.platform_id
        end

        # Start the adapter and begin receiving messages.
        # This method blocks until stopped — call it inside a Thread.
        # @yield [event Hash] yields one standardized event per inbound message
        def start(&on_message)
          raise NotImplementedError, "#{self.class} must implement #start"
        end

        # Stop the adapter and release resources.
        def stop
          raise NotImplementedError, "#{self.class} must implement #stop"
        end

        # Send a plain text (or Markdown) message to a chat.
        # @param chat_id [String]
        # @param text [String]
        # @param reply_to [String, nil] optional message_id to thread under
        # @return [Hash] { message_id: String }
        def send_text(chat_id, text, reply_to: nil)
          raise NotImplementedError, "#{self.class} must implement #send_text"
        end

        # Update an existing message in-place (for streaming progress).
        # @return [Boolean] true if successful
        def update_message(chat_id, message_id, text)
          false
        end

        # @return [Boolean] true if the platform supports editing a sent message
        def supports_message_updates?
          false
        end

        # Validate the provided config hash.
        # @return [Array<String>] list of error strings; empty means valid
        def validate_config(config)
          []
        end
      end
    end
  end
end
