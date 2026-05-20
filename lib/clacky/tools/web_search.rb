# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"
require "base64"
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

      # Ordered list of search providers to try in sequence.
      # cn.bing.com is accessible in mainland China without VPN.
      PROVIDERS = %i[duckduckgo bing].freeze

      def execute(query:, max_results: 10, working_dir: nil)
        if query.nil? || query.strip.empty?
          return { error: "Query cannot be empty" }
        end

        last_error = nil
        diagnostics = []

        providers = active_providers
        providers.each do |provider|
          begin
            results, provider_meta = send(:"search_#{provider}", query, max_results)
            filtered_results = filter_placeholder_results(provider, results)

            diagnostics << provider_diagnostic(
              provider: provider,
              status: filtered_results.empty? ? "no_results" : "ok",
              result_count: filtered_results.length,
              meta: provider_meta
            )

            return {
              query: query,
              results: filtered_results,
              count: filtered_results.length,
              provider: provider.to_s,
              diagnostics: diagnostics,
              error: nil
            } unless filtered_results.empty?
          rescue StandardError => e
            # DuckDuckGo failed — suppress it for 10 minutes
            @ddg_unavailable_until = Time.now + 600 if provider == :duckduckgo
            last_error = e
            diagnostics << provider_diagnostic(
              provider: provider,
              status: "error",
              result_count: 0,
              error: e.message
            )
            next
          end
        end

        # All providers failed or returned no results
        {
          query: query,
          results: [],
          count: 0,
          provider: nil,
          diagnostics: diagnostics,
          error: build_failure_message(diagnostics, last_error)
        }
      end

      # Skip DuckDuckGo if it failed recently (within last 10 minutes)
      private def active_providers
        if @ddg_unavailable_until && Time.now < @ddg_unavailable_until
          PROVIDERS.drop(1)
        else
          PROVIDERS
        end
      end

      # ── DuckDuckGo ─────────────────────────────────────────────────────────

      private def search_duckduckgo(query, max_results)
        encoded_query = CGI.escape(query)
        url = URI("https://html.duckduckgo.com/html/?q=#{encoded_query}")
        response = http_get(url)
        meta = { http_status: response&.code.to_i, body_size: response&.body&.bytesize.to_i }
        return [[], meta] unless response.is_a?(Net::HTTPSuccess)

        [parse_duckduckgo_html(response.body, max_results), meta]
      end

      private def parse_duckduckgo_html(html, max_results)
        results = []
        html = Clacky::Utils::Encoding.to_utf8(html)

        links = html.scan(%r{<a[^>]*class="result__a"[^>]*href="//duckduckgo\.com/l/\?uddg=([^"&]+)[^"]*"[^>]*>(.*?)</a>}m)
        snippets = html.scan(%r{<a[^>]*class="result__snippet"[^>]*>(.*?)</a>}m)

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

          results << { title: title, url: url, snippet: snippet }
        end

        results
      end

      # ── Bing ───────────────────────────────────────────────────────────────

      private def search_bing(query, max_results)
        encoded_query = CGI.escape(query)
        # cn.bing.com redirects to www.bing.com for non-China IPs (e.g. GitHub CI);
        # follow_redirects ensures both environments work with the same code path.
        url = URI("https://cn.bing.com/search?q=#{encoded_query}&count=#{max_results}")
        response = http_get(url, accept_language: "zh-CN,zh;q=0.9,en;q=0.8", follow_redirects: 2)
        meta = { http_status: response&.code.to_i, body_size: response&.body&.bytesize.to_i }
        return [[], meta] unless response.is_a?(Net::HTTPSuccess)

        [parse_bing_html(response.body, max_results), meta]
      end

      private def parse_bing_html(html, max_results)
        results = []
        html = Clacky::Utils::Encoding.to_utf8(html)

        # Bing result blocks: <li class="b_algo">...</li>
        blocks = html.scan(%r{<li[^>]*class="b_algo"[^>]*>(.*?)</li>}m)

        blocks.each do |block_arr|
          break if results.length >= max_results
          block = block_arr[0]

          # Extract URL and title from <h2><a href="URL">TITLE</a></h2>
          title_match = block.match(%r{<h2[^>]*>.*?<a[^>]*href="(https?://[^"]+)"[^>]*>(.*?)</a>}m)
          next unless title_match

          raw_url = CGI.unescapeHTML(title_match[1])
          url = decode_bing_url(raw_url)
          title = title_match[2].gsub(/<[^>]+>/, "").strip
          title = CGI.unescapeHTML(title) if title.include?("&")

          # Extract snippet from <p class="b_lineclamp..."> or <div class="b_caption"><p>
          snippet = ""
          snippet_match = block.match(%r{<p[^>]*class="b_lineclamp[^"]*"[^>]*>(.*?)</p>}m) ||
                          block.match(%r{<div[^>]*class="b_caption"[^>]*>.*?<p[^>]*>(.*?)</p>}m)
          if snippet_match
            snippet = snippet_match[1].gsub(/<[^>]+>/, "").strip
            snippet = CGI.unescapeHTML(snippet) if snippet.include?("&")
          end

          results << { title: title, url: url, snippet: snippet }
        end

        results
      end

      # Decode Bing's redirect URL: bing.com/ck/a?...&u=a1BASE64URL&ntb=1
      # The "u" param is "a1" prefix + base64-encoded real URL
      private def decode_bing_url(url)
        return url unless url.include?("bing.com/ck/")

        u_param = url.match(/[?&]u=([^&]+)/)
        return url unless u_param

        encoded = u_param[1]
        # Remove "a1" prefix then base64-decode
        return url unless encoded.start_with?("a1")

        base64_part = encoded[2..]
        # Bing uses URL-safe base64 without padding
        padded = base64_part + "=" * ((4 - base64_part.length % 4) % 4)
        decoded = Base64.urlsafe_decode64(padded)
        decoded.force_encoding("UTF-8").valid_encoding? ? decoded : url
      rescue StandardError
        url
      end

      private def filter_placeholder_results(provider, results)
        return results unless provider == :duckduckgo
        return [] if results.empty?

        first = results.first
        if first[:url].include?("duckduckgo.com") && first[:title] == "Web search results"
          return []
        end

        results
      end

      private def provider_diagnostic(provider:, status:, result_count:, meta: {}, error: nil)
        {
          provider: provider.to_s,
          status: status,
          result_count: result_count,
          http_status: meta[:http_status],
          body_size: meta[:body_size],
          error: error
        }
      end

      private def build_failure_message(diagnostics, last_error)
        summary = diagnostics.map do |item|
          fragment = "#{item[:provider]}: #{item[:status]}"
          fragment += "(http=#{item[:http_status]})" if item[:http_status]
          fragment += " error=#{item[:error]}" if item[:error]
          fragment
        end.join(", ")

        suffix = if summary.empty?
          "no provider diagnostics"
        else
          summary
        end

        if diagnostics.any? { |item| item[:status] == "no_results" }
          "No search results from providers. Details: #{suffix}"
        else
          "All search providers failed. Details: #{suffix}. Last error: #{last_error&.message}"
        end
      end

      # ── Shared HTTP helper ─────────────────────────────────────────────────

      USER_AGENTS = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
      ].freeze

      # Shared browser-like GET request — no Accept-Encoding to avoid gzip/br
      # detection tricks used by Bing. Supports redirect following.
      private def http_get(url, accept_language: "en-US,en;q=0.9", follow_redirects: 0)
        request = Net::HTTP::Get.new(url)
        request["User-Agent"] = USER_AGENTS.sample
        request["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        request["Accept-Language"] = accept_language
        # Deliberately omit Accept-Encoding — sending gzip causes Bing to return
        # a JS-only skeleton (~39KB) instead of the real HTML results (~120KB)
        request["Sec-Fetch-Dest"] = "document"
        request["Sec-Fetch-Mode"] = "navigate"
        request["Sec-Fetch-Site"] = "none"
        request["Upgrade-Insecure-Requests"] = "1"

        response = Net::HTTP.start(url.hostname, url.port,
          use_ssl: url.scheme == "https",
          read_timeout: 8,
          open_timeout: 5) { |http| http.request(request) }

        # Follow redirects (e.g. cn.bing.com redirects to www.bing.com for non-China IPs)
        if follow_redirects > 0 && response.is_a?(Net::HTTPRedirection)
          location = response["location"]
          redirect_url = location.start_with?("http") ? URI(location) : URI("#{url.scheme}://#{url.hostname}#{location}")
          return http_get(redirect_url, accept_language: accept_language, follow_redirects: follow_redirects - 1)
        end

        response
      end

      # ── Formatting ─────────────────────────────────────────────────────────

      def format_call(args)
        query = args[:query] || args["query"] || ""
        display_query = query.length > 40 ? "#{query[0..37]}..." : query
        "web_search(\"#{display_query}\")"
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error]}"
        else
          count = result[:count] || 0
          provider = result[:provider] ? " via #{result[:provider]}" : ""
          "[OK] Found #{count} results#{provider}"
        end
      end
    end
  end
end

