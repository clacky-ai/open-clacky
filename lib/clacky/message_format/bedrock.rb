# frozen_string_literal: true

module Clacky
  module MessageFormat
    # Static helpers for AWS Bedrock Converse API message format.
    #
    # The Bedrock Converse API has a completely different format from Anthropic's Messages API:
    #   - Authentication: Authorization: Bearer <ABSK...key>
    #   - Endpoint: POST /model/{modelId}/converse
    #   - Request:  { messages: [{role:, content: [{text:}]}], toolConfig: {tools: [{toolSpec:...}]}, system: [{text:}] }
    #   - Response: { output: { message: { role:, content: [{text:} or {toolUse:}] } }, stopReason:, usage: }
    #
    # Internal canonical format (same as OpenAI-style):
    #   assistant tool_calls: { role: "assistant", tool_calls: [{id:, name:, arguments:}] }
    #   tool result:          { role: "tool", tool_call_id:, content: }
    #
    # This module converts canonical format ↔ Bedrock Converse API format.
    module Bedrock
      # Detect if the request should use the Bedrock Converse API.
      # Matches any of:
      #   - API key with "ABSK" prefix (native AWS Bedrock)
      #   - Model ID with "abs-" prefix (Clacky AI proxy that speaks Bedrock Converse)
      #
      # A bare "clacky-" key is NOT enough: that same workspace key is also
      # used for dsk-*, or-*, and other OpenAI-compatible aliases served by
      # the same Clacky proxy on a different endpoint. The *model prefix* is
      # the source of truth for which upstream format the proxy expects:
      #
      #   abs-*  → Bedrock Converse  (POST /model/{id}/converse)
      #   dsk-*  → OpenAI-compatible (POST /chat/completions)
      #   or-*   → OpenAI-compatible (POST /chat/completions)
      #   other  → depends on base_url + explicit anthropic_format flag
      #
      # Historically this method also returned true for any "clacky-" key,
      # which forced non-abs aliases into the Bedrock endpoint and produced
      # `unknown model "..."` errors. Keep the explicit-prefix rule: if you
      # add a new OpenAI-compatible alias family on the Clacky proxy, it
      # will route correctly without touching this file.
      def self.bedrock_api_key?(api_key, model)
        return true if api_key.to_s.start_with?("ABSK")
        model.to_s.start_with?("abs-")
      end

      module_function

      # ── Request building ──────────────────────────────────────────────────────

      # Convert canonical @messages + tools into a Bedrock Converse API request body.
      # @param messages [Array<Hash>] canonical messages (may include system)
      # @param model    [String]
      # @param tools    [Array<Hash>] OpenAI-style tool definitions
      # @param max_tokens [Integer]
      # @param caching_enabled [Boolean] (currently unused for Bedrock)
      # @return [Hash] ready to serialize as JSON body
      def build_request_body(messages, model, tools, max_tokens, caching_enabled = false)
        system_messages = messages.select { |m| m[:role] == "system" }
        regular_messages = messages.reject { |m| m[:role] == "system" }

        # Merge consecutive same-role messages (Bedrock requires alternating roles)
        api_messages = merge_consecutive_tool_results(regular_messages.map { |msg| to_api_message(msg) })

        # Inject cachePoint blocks AFTER conversion to Bedrock API format.
        # Doing this on canonical messages (before to_api_message) is incorrect because
        # tool-result messages (role: "tool") are converted to toolResult blocks, and
        # Bedrock does not support cachePoint inside toolResult.content.
        # Operating on the final Bedrock format ensures cachePoint is always a top-level
        # sibling block in the message's content array, which is what Bedrock expects.
        api_messages = apply_api_caching(api_messages) if caching_enabled

        body = { messages: api_messages }

        # Add system prompt if present
        unless system_messages.empty?
          system_text = system_messages.map { |m| extract_text(m[:content]) }.join("\n\n")
          body[:system] = [{ text: system_text }] unless system_text.empty?
        end

        # Add inference config for max_tokens
        body[:inferenceConfig] = { maxTokens: max_tokens }

        # Add tool config if tools are provided
        if tools&.any?
          body[:toolConfig] = { tools: tools.map { |t| to_api_tool(t) } }
        end

        body
      end

      # ── Response parsing ──────────────────────────────────────────────────────

      # Parse Bedrock Converse API response into canonical internal format.
      # @param data [Hash] parsed JSON response body
      # @return [Hash] canonical response: { content:, tool_calls:, finish_reason:, usage: }
      def parse_response(data)
        message = data.dig("output", "message") || {}
        blocks  = message["content"] || []
        usage   = data["usage"] || {}

        # Extract text content
        content = blocks.select { |b| b["text"] }.map { |b| b["text"] }.join("")

        # Extract tool calls from toolUse blocks
        tool_calls = blocks.select { |b| b["toolUse"] }.map do |b|
          tc = b["toolUse"]
          args = tc["input"].is_a?(String) ? tc["input"] : tc["input"].to_json
          { id: tc["toolUseId"], type: "function", name: tc["name"], arguments: args }
        end

        # Map Bedrock stopReason → canonical finish_reason
        finish_reason = case data["stopReason"]
                        when "end_turn"   then "stop"
                        when "tool_use"   then "tool_calls"
                        when "max_tokens" then "length"
                        else data["stopReason"]
                        end

        cache_read  = usage["cacheReadInputTokens"].to_i
        cache_write = usage["cacheWriteInputTokens"].to_i

        # Bedrock `inputTokens` = non-cached input only.
        # Anthropic direct `input_tokens` = ALSO non-cached input only
        # (cache_read_input_tokens and cache_creation_input_tokens are reported
        # separately and are disjoint from input_tokens — NOT included in it).
        # Normalise to the OpenAI/Bedrock convention so ModelPricing.calculate_cost
        # works correctly:
        #   prompt_tokens = inputTokens + cacheReadInputTokens
        # (calculate_cost subtracts cache_read_tokens from prompt_tokens to get
        #  the billable non-cached portion; cache_write is priced on top.)
        prompt_tokens = usage["inputTokens"].to_i + cache_read

        usage_data = {
          prompt_tokens:     prompt_tokens,
          completion_tokens: usage["outputTokens"].to_i,
          total_tokens:      usage["totalTokens"].to_i
        }
        usage_data[:cache_read_input_tokens]     = cache_read  if cache_read  > 0
        usage_data[:cache_creation_input_tokens] = cache_write if cache_write > 0

        { content: content, tool_calls: tool_calls, finish_reason: finish_reason,
          usage: usage_data, raw_api_usage: usage }
      end

      # ── Tool result formatting ────────────────────────────────────────────────

      # Format tool results into canonical messages to append to @messages.
      # (Same as Anthropic format — canonical tool messages)
      def format_tool_results(response, tool_results)
        results_map = tool_results.each_with_object({}) { |r, h| h[r[:id]] = r }

        response[:tool_calls].map do |tc|
          result = results_map[tc[:id]]
          {
            role: "tool",
            tool_call_id: tc[:id],
            content: result ? result[:content] : { error: "Tool result missing" }.to_json
          }
        end
      end

      # ── Private helpers ───────────────────────────────────────────────────────

      # Convert a single canonical message to Bedrock Converse API format.
      private_class_method def self.to_api_message(msg)
        role      = msg[:role]
        content   = msg[:content]
        tool_calls = msg[:tool_calls]

        # assistant with tool_calls → content blocks with toolUse
        if role == "assistant" && tool_calls&.any?
          blocks = []
          blocks << { text: content } if content.is_a?(String) && !content.empty?

          tool_calls.each do |tc|
            func  = tc[:function] || tc
            name  = func[:name]  || tc[:name]
            raw_args = func[:arguments] || tc[:arguments]
            input = raw_args.is_a?(String) ? (JSON.parse(raw_args) rescue {}) : (raw_args || {})
            blocks << { toolUse: { toolUseId: tc[:id], name: name, input: input } }
          end

          return { role: "assistant", content: blocks }
        end

        # canonical tool result (role: "tool") → Bedrock user message with toolResult block
        if role == "tool"
          result_content = msg[:content]
          # Bedrock toolResult content must be an array of Bedrock-native blocks.
          # If content is an Array of canonical blocks (e.g. image_url + text from file_reader),
          # convert each block to Bedrock format via normalize_block.
          result_blocks = if result_content.is_a?(String)
                           [{ text: result_content }]
                         elsif result_content.is_a?(Array)
                           result_content.map { |b| normalize_block(b) }.compact
                         else
                           [{ text: result_content.to_s }]
                         end
          return {
            role: "user",
            content: [{ toolResult: { toolUseId: msg[:tool_call_id], content: result_blocks } }]
          }
        end

        # regular user/assistant message
        blocks = content_to_blocks(content)
        # Bedrock rejects messages with an empty content array — use a placeholder text block.
        blocks = [{ text: "..." }] if blocks.empty?
        { role: role, content: blocks }
      end

      # Convert content (String or Array) to Bedrock content block array.
      private_class_method def self.content_to_blocks(content)
        case content
        when String
          # Bedrock rejects blank text blocks — skip empty strings
          return [] if content.empty?

          [{ text: content }]
        when Array
          content.map { |b| normalize_block(b) }.compact
        else
          str = content.to_s
          return [] if str.empty?

          [{ text: str }]
        end
      end

      # Normalize a content block to Bedrock format.
      private_class_method def self.normalize_block(block)
        return { text: block.to_s } unless block.is_a?(Hash)

        case block[:type]
        when "text"
          # Bedrock rejects blank text blocks — drop them
          text = block[:text].to_s
          return nil if text.empty?

          { text: text }
        when "image_url"
          # Bedrock image format — base64 only
          url = block.dig(:image_url, :url) || block[:url]
          url_to_image_block(url)
        when "image"
          block # already Bedrock format
        else
          # Pass through Bedrock-native blocks (e.g. cachePoint) unchanged
          return block if block[:cachePoint]
          # Fallback: try to extract text
          { text: (block[:text] || block.to_s) }
        end
      end

      # Convert an image URL to Bedrock image block.
      private_class_method def self.url_to_image_block(url)
        return nil unless url

        if url.start_with?("data:")
          match = url.match(/^data:image\/([^;]+);base64,(.*)$/)
          if match
            {
              image: {
                format: match[1],
                source: { bytes: match[2] }
              }
            }
          end
        else
          # Bedrock doesn't support URL-based images in all regions; skip
          nil
        end
      end

      # Convert OpenAI-style tool definition to Bedrock toolSpec format.
      private_class_method def self.to_api_tool(tool)
        func = tool[:function] || tool
        {
          toolSpec: {
            name: func[:name],
            description: func[:description],
            inputSchema: { json: func[:parameters] }
          }
        }
      end

      # Extract plain text from content (String or Array).
      private_class_method def self.extract_text(content)
        case content
        when String then content
        when Array  then content.map { |b| b.is_a?(Hash) ? (b[:text] || "") : b.to_s }.join("\n")
        else             content.to_s
        end
      end

      # Bedrock Converse API requires strict user/assistant alternation.
      # Merge consecutive tool result messages (role: "user") into a single message.
      private_class_method def self.merge_consecutive_tool_results(messages)
        return messages if messages.empty?

        merged = []
        messages.each do |msg|
          prev = merged.last
          # If current and previous are both user messages containing toolResult blocks,
          # merge their content arrays together
          if prev && prev[:role] == "user" && msg[:role] == "user" &&
             prev[:content].is_a?(Array) && msg[:content].is_a?(Array) &&
             prev[:content].any? { |b| b[:toolResult] } &&
             msg[:content].any? { |b| b[:toolResult] }
            merged.last[:content].concat(msg[:content])
          else
            merged << msg.dup
          end
        end
        merged
      end

      # Inject cachePoint blocks into already-converted Bedrock API format messages.
      # Marks the last 2 messages (from the tail) so Bedrock can cache the conversation
      # prefix up to those points.
      #
      # Why operate on Bedrock API format (not canonical):
      #   - tool-result canonical messages (role: "tool") become toolResult blocks inside
      #     a user message. Bedrock does NOT allow cachePoint inside toolResult.content.
      #   - After merge_consecutive_tool_results, message boundaries may differ from canonical.
      #   - Operating here guarantees cachePoint is always a top-level sibling block.
      private_class_method def self.apply_api_caching(api_messages)
        return api_messages if api_messages.empty?

        candidate_indices = []
        (api_messages.length - 1).downto(0) do |i|
          break if candidate_indices.length >= 2
          candidate_indices << i
        end

        api_messages.map.with_index do |msg, idx|
          next msg unless candidate_indices.include?(idx)

          content = msg[:content]
          next msg unless content.is_a?(Array)

          # Don't double-add cachePoint if already present
          already_marked = content.last.is_a?(Hash) && content.last[:cachePoint]
          next msg if already_marked

          msg.merge(content: content + [{ cachePoint: { type: "default" } }])
        end
      end
    end
  end
end
