# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"

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

      def execute(query:, max_results: 10)
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

      private

      def search_duckduckgo(query, max_results)
        # DuckDuckGo HTML search endpoint
        encoded_query = CGI.escape(query)
        url = URI("https://html.duckduckgo.com/html/?q=#{encoded_query}")

        # Make request with user agent
        request = Net::HTTP::Get.new(url)
        request["User-Agent"] = "Mozilla/5.0 (compatible; Clacky/1.0)"

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

      def parse_duckduckgo_html(html, max_results)
        results = []

        # Simple regex-based parsing (not perfect but works for basic cases)
        # Look for result blocks in DuckDuckGo HTML
        html.scan(%r{<div class="result__body">.*?</div>}m).each do |block|
          break if results.length >= max_results

          # Extract title and URL
          if block =~ %r{<a.*?href="//duckduckgo\.com/l/\?uddg=([^"&]+).*?".*?>(.*?)</a>}m
            url = CGI.unescape($1)
            title = $2.gsub(/<[^>]+>/, "").strip

            # Extract snippet
            snippet = ""
            if block =~ %r{<a class="result__snippet".*?>(.*?)</a>}m
              snippet = $1.gsub(/<[^>]+>/, "").strip
            end

            results << {
              title: title,
              url: url,
              snippet: snippet
            }
          end
        end

        # If parsing failed, provide a fallback
        if results.empty?
          results << {
            title: "Web search results",
            url: "https://duckduckgo.com/?q=#{CGI.escape(query)}",
            snippet: "Could not parse search results. Visit the URL to see results."
          }
        end

        results
      rescue StandardError
        []
      end
    end
  end
end
