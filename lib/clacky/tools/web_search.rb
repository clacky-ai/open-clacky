# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"
require_relative "../utils/encoding"

module Clacky
  module Tools
    class WebSearch < Base
      self.tool_name = "web_search"
      self.tool_description = "Search the web for current information. Returns search results with titles, URLs, and snippets."
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "The search query"
          },
          max_results: {
            type: "integer",
            description: "Maximum number of results to return (default: 10)",
            default: 10
          }
        },
        required: %w[query]
      }

      def execute(query:, max_results: 10, working_dir: nil)
        # Validate query
        if query.nil? || query.strip.empty?
          return { error: "Query cannot be empty" }
        end

        begin
          # Use DuckDuckGo HTML search (no API key needed)
          results = search_duckduckgo(query, max_results)

          {
            query: query,
            results: results,
            count: results.length,
            error: nil
          }
        rescue StandardError => e
          { error: "Failed to perform web search: #{e.message}" }
        end
      end

      private def search_duckduckgo(query, max_results)
        # DuckDuckGo HTML search endpoint
        encoded_query = CGI.escape(query)
        url = URI("https://html.duckduckgo.com/html/?q=#{encoded_query}")

        # Make request with user agent
        request = Net::HTTP::Get.new(url)
        request["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

        response = Net::HTTP.start(url.hostname, url.port, use_ssl: true, read_timeout: 10) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          return []
        end

        # Parse HTML results (simple extraction)
        parse_duckduckgo_html(response.body, max_results)
      rescue StandardError => e
        # Fallback: return basic search URL
        [
          {
            title: "Search results for: #{query}",
            url: "https://duckduckgo.com/?q=#{CGI.escape(query)}",
            snippet: "Click to view search results in browser. Error: #{e.message}"
          }
        ]
      end

      private def parse_duckduckgo_html(html, max_results)
        results = []

        # Ensure HTML is valid UTF-8
        html = Clacky::Utils::Encoding.to_utf8(html)

        # Extract all result links and snippets
        # Pattern: <a class="result__a" href="//duckduckgo.com/l/?uddg=ENCODED_URL...">TITLE</a>
        links = html.scan(%r{<a[^>]*class="result__a"[^>]*href="//duckduckgo\.com/l/\?uddg=([^"&]+)[^"]*"[^>]*>(.*?)</a>}m)
        
        # Pattern: <a class="result__snippet">SNIPPET</a>
        snippets = html.scan(%r{<a[^>]*class="result__snippet"[^>]*>(.*?)</a>}m)

        # Combine links and snippets
        links.each_with_index do |link_data, index|
          break if results.length >= max_results

          url = Clacky::Utils::Encoding.to_utf8(CGI.unescape(link_data[0]))
          title = link_data[1].gsub(/<[^>]+>/, "").strip
          title = CGI.unescapeHTML(title) if title.include?("&")

          snippet = ""
          if snippets[index]
            snippet = snippets[index][0].gsub(/<[^>]+>/, "").strip
            snippet = CGI.unescapeHTML(snippet) if snippet.include?("&")
          end

          results << {
            title: title,
            url: url,
            snippet: snippet
          }
        end

        # If parsing failed, provide a fallback
        if results.empty?
          results << {
            title: "Web search results",
            url: "https://duckduckgo.com/",
            snippet: "Could not parse search results. Please try again."
          }
        end

        results
      rescue StandardError => e
        # Return fallback on error
        [{
          title: "Web search error",
          url: "https://duckduckgo.com/",
          snippet: "Error parsing results: #{e.message}"
        }]
      end

      def format_call(args)
        query = args[:query] || args['query'] || ''
        display_query = query.length > 40 ? "#{query[0..37]}..." : query
        "web_search(\"#{display_query}\")"
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error]}"
        else
          count = result[:count] || 0
          "[OK] Found #{count} results"
        end
      end
    end
  end
end
