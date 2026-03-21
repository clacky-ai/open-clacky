# frozen_string_literal: true

require "net/http"
require "uri"
require "tmpdir"
require "fileutils"
require_relative "../utils/encoding"

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
            description: "Maximum content length to return in characters (default: 3000)",
            default: 3000
          }
        },
        required: %w[url]
      }

      def execute(url:, max_length: 3000, working_dir: nil)
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

          # Extract content and force UTF-8 encoding at the source
          content = Clacky::Utils::Encoding.to_utf8(response.body)
          content_type = response["content-type"] || ""

          # Parse HTML if it's an HTML page
          if content_type.include?("text/html")
            result = parse_html(content, max_length, url)
            result[:url] = url
            result[:content_type] = content_type
            result[:status_code] = response.code.to_i
            result[:error] = nil
            result
          else
            # For non-HTML content, return raw text
            result = handle_raw_content(content, max_length, url, content_type, response.code.to_i)
            result
          end
        rescue StandardError => e
          { error: "Failed to fetch URL: #{e.message}" }
        end
      end

      def handle_raw_content(content, max_length, url, content_type, status_code)
        truncated = content.length > max_length
        temp_file = nil

        if truncated
          temp_dir = Dir.mktmpdir
          domain = extract_domain(url)
          safe_name = domain.gsub(/[^\w\-.]/, '_')[0...50]
          timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
          temp_file = File.join(temp_dir, "#{safe_name}_#{timestamp}.txt")
          File.write(temp_file, content)
        end

        {
          url: url,
          content_type: content_type,
          status_code: status_code,
          content: content[0, max_length],
          truncated: truncated,
          temp_file: temp_file,
          error: nil
        }
      end

      def extract_domain(url)
        uri = URI.parse(url)
        uri.host || url.gsub(/[^\w\-.]/, '_')
      rescue
        url.gsub(/[^\w\-.]/, '_')
      end

      def fetch_url(uri)
        # Follow redirects (max 5)
        redirects = 0
        max_redirects = 5

        loop do
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
          request["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
          request["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8"

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
            new_uri = URI.parse(location)
            # Handle relative redirects by merging with the current URI
            uri = new_uri.relative? ? uri.merge(new_uri) : new_uri
          else
            raise "HTTP error: #{response.code} #{response.message}"
          end
        end
      end

      def parse_html(html, max_length, url = nil)
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

        # Check if we need to save to temp file
        truncated = text.length > max_length
        temp_file = nil

        if truncated
          temp_dir = Dir.mktmpdir
          domain = url ? extract_domain(url) : "web_fetch"
          safe_name = domain.gsub(/[^\w\-.]/, '_')[0...50]
          timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
          temp_file = File.join(temp_dir, "#{safe_name}_#{timestamp}.txt")
          File.write(temp_file, text)
        end

        {
          title: title,
          description: description,
          content: text[0, max_length],
          truncated: truncated,
          temp_file: temp_file
        }
      end

      def format_call(args)
        url = args[:url] || args['url'] || ''
        # Extract domain from URL for display
        begin
          uri = URI.parse(url)
          domain = uri.host || url
          "web_fetch(#{domain})"
        rescue
          display_url = url.length > 40 ? "#{url[0..37]}..." : url
          "web_fetch(\"#{display_url}\")"
        end
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error]}"
        else
          title = result[:title] || 'Untitled'
          display_title = title.length > 40 ? "#{title[0..37]}..." : title
          "[OK] Fetched: #{display_title}"
        end
      end

      # Format result for LLM consumption - return compact version to save tokens
      def format_result_for_llm(result)
        # Return error as-is
        return result if result[:error]

        # Build compact result
        compact = {
          url: result[:url],
          title: result[:title],
          description: result[:description],
          status_code: result[:status_code]
        }

        # Add truncated notice and temp file info if content was truncated
        if result[:truncated] && result[:temp_file]
          compact[:content] = result[:content]
          compact[:truncated] = true
          compact[:temp_file] = result[:temp_file]
          compact[:message] = "[Content truncated - full content saved to: #{result[:temp_file]}. " \
                              "Use grep to search keywords, or file_reader with start_line/end_line to read sections.]"
        else
          compact[:content] = result[:content]
          compact[:truncated] = result[:truncated] || false
        end

        compact
      end
    end
  end
end
