# frozen_string_literal: true

require_relative "base_component"

module Clacky
  module UI2
    module Components
      # MessageComponent renders user and assistant messages
      class MessageComponent < BaseComponent
        # Render a message
        # @param data [Hash] Message data
        #   - :role [String] "user" or "assistant"
        #   - :content [String] Message content
        #   - :timestamp [Time, nil] Optional timestamp
        #   - :files [Array<Hash>] Optional file hashes (for user messages)
        #   - :prefix_newline [Boolean] Whether to add newline before message (for system messages)
        # @return [String] Rendered message
        def render(data)
          role = data[:role]
          content = data[:content]
          timestamp = data[:timestamp]
          files = data[:files] || []
          prefix_newline = data.fetch(:prefix_newline, true)
          
          case role
          when "user"
            render_user_message(content, timestamp, files)
          when "assistant"
            render_assistant_message(content, timestamp)
          else
            render_system_message(content, timestamp, prefix_newline)
          end
        end


        # Render user message
        # @param content [String] Message content
        # @param timestamp [Time, nil] Optional timestamp
        # @param files [Array<Hash>] Optional file hashes { name:, mime_type:, ... }
        # @return [String] Rendered message
        def render_user_message(content, timestamp = nil, files = [])
          symbol = format_symbol(:user)
          text = format_text(content, :user)
          time_str = timestamp ? @pastel.dim("[#{format_timestamp(timestamp)}]") : ""

          result = "\n#{symbol} #{text} #{time_str}".rstrip

          # Append file attachment info if present
          if files && files.any?
            files.each_with_index do |f, idx|
              filename = f[:name] || f["name"] || "file"
              result += "\n" + @pastel.dim("    [File #{idx + 1}] #{filename}")
            end
          end

          result
        end

        private def format_filesize(bytes)
          if bytes < 1024
            "#{bytes}b"
          elsif bytes < 1024 * 1024
            "#{(bytes / 1024.0).round(1)}kb"
          else
            "#{(bytes / (1024.0 * 1024)).round(1)}mb"
          end
        end

        # Render assistant message
        # @param content [String] Message content
        # @param timestamp [Time, nil] Optional timestamp
        # @return [String] Rendered message
        def render_assistant_message(content, timestamp = nil)
          return "" if content.nil? || content.empty?

          symbol = format_symbol(:assistant)
          text = format_text(content, :assistant)
          time_str = timestamp ? @pastel.dim("[#{format_timestamp(timestamp)}]") : ""

          "\n#{symbol} #{text} #{time_str}".rstrip
        end

        # Render system message
        # @param content [String] Message content
        # @param timestamp [Time, nil] Optional timestamp
        # @param prefix_newline [Boolean] Whether to add newline before message
        # @return [String] Rendered message
        private def render_system_message(content, timestamp = nil, prefix_newline = true)
          symbol = format_symbol(:info)
          text = format_text(content, :info)
          time_str = timestamp ? @pastel.dim("[#{format_timestamp(timestamp)}]") : ""

          prefix = prefix_newline ? "\n" : ""
          "#{prefix}#{symbol} #{text} #{time_str}".rstrip
        end
      end
    end
  end
end
