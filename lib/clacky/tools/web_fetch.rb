# frozen_string_literal: true

require "net/http"
require "uri"

module Clacky
  module Tools
    class WebFetch < Base
      self.tool_name = "web_fetch"
      self.tool_description = "Fetch and parse content from a web page. Returns the page content, title, and metadata."
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          url: {
            type: "string",
            description: "The URL to fetch (must be a valid HTTP/HTTPS URL)"
          },
          max_length: {
            type: "integer",
            description: "Maximum content length to return in characters (default: 50000)",
            default: 50000
          }
        },
        required: %w[url]
      }

      def execute(url:, max_length: 50000)
        # Validate URL
        begin
          uri = URI.parse(url)
          unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
            return { error: "URL must be HTTP or HTTPS" }
          end
        rescue URI::InvalidURIError => e
          return { error: "Invalid URL: #{e.message}" }
        end

        begin
          # Fetch the web page
          response = fetch_url(uri)

          # Extract content
          content = response.body
          content_type = response["content-type"] || ""

          # Parse HTML if it's an HTML page
          if content_type.include?("text/html")
            result = parse_html(content, max_length)
            result[:url] = url
            result[:content_type] = content_type
            result[:status_code] = response.code.to_i
            result[:error] = nil
            result
          else
            # For non-HTML content, return raw text
            truncated_content = content[0, max_length]
            {
              url: url,
              content_type: content_type,
              status_code: response.code.to_i,
              content: truncated_content,
              truncated: content.length > max_length,
              error: nil
            }
          end
        rescue StandardError => e
          { error: "Failed to fetch URL: #{e.message}" }
        end
      end

      private

      def fetch_url(uri)
        # Follow redirects (max 5)
        redirects = 0
        max_redirects = 5

        loop do
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = "Mozilla/5.0 (compatible; Clacky/1.0)"

          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 15) do |http|
            http.request(request)
          end

          case response
          when Net::HTTPSuccess
            return response
          when Net::HTTPRedirection
            redirects += 1
            raise "Too many redirects" if redirects > max_redirects

            location = response["location"]
            uri = URI.parse(location)
          else
            raise "HTTP error: #{response.code} #{response.message}"
          end
        end
      end

      def parse_html(html, max_length)
        # Extract title
        title = ""
        if html =~ %r{<title[^>]*>(.*?)</title>}mi
          title = $1.strip.gsub(/\s+/, " ")
        end

        # Extract meta description
        description = ""
        if html =~ /<meta[^>]*name=["']description["'][^>]*content=["']([^"']*)["']/mi
          description = $1.strip
        elsif html =~ /<meta[^>]*content=["']([^"']*)["'][^>]*name=["']description["']/mi
          description = $1.strip
        end

        # Remove script and style tags
        text = html.gsub(%r{<script[^>]*>.*?</script>}mi, "")
                   .gsub(%r{<style[^>]*>.*?</style>}mi, "")

        # Remove HTML tags
        text = text.gsub(/<[^>]+>/, " ")

        # Clean up whitespace
        text = text.gsub(/\s+/, " ").strip

        # Truncate if needed
        truncated = text.length > max_length
        text = text[0, max_length] if truncated

        {
          title: title,
          description: description,
          content: text,
          truncated: truncated
        }
      end
    end
  end
end
