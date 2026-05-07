# frozen_string_literal: true

module Clacky
  module MessageFormat
    # Static helpers for Anthropic API message format.
    #
    # Responsibilities:
    #   - Identify Anthropic-style messages stored in @messages
    #   - Convert internal @messages → Anthropic API request body
    #   - Parse Anthropic API response → internal format
    #   - Format tool results for the next turn
    #
    # Internal @messages always use OpenAI-style canonical format:
    #   assistant tool_calls: { role: "assistant", tool_calls: [{id:, function:{name:,arguments:}}] }
    #   tool result:          { role: "tool", tool_call_id:, content: }
    #
    # This module converts that canonical format to Anthropic native on the way OUT,
    # and converts Anthropic native back to canonical on the way IN.
    module Anthropic
      module_function

      # ── Message type identification ───────────────────────────────────────────

      # Returns true if the message is an Anthropic-native tool result stored in
      # @messages (role: "user" with content array containing tool_result blocks).
      # NOTE: After the refactor, new tool results are stored in canonical format
      # (role: "tool"). This helper handles legacy messages that might exist in
      # older sessions.
      def tool_result_message?(msg)
        msg[:role] == "user" &&
          msg[:content].is_a?(Array) &&
          msg[:content].any? { |b| b.is_a?(Hash) && b[:type] == "tool_result" }
      end

      # Returns the tool_use_ids referenced in an Anthropic-native tool result message.
      def tool_use_ids(msg)
        return [] unless tool_result_message?(msg)

        msg[:content].select { |b| b[:type] == "tool_result" }.map { |b| b[:tool_use_id] }
      end

      # ── Request building ──────────────────────────────────────────────────────

      # Convert canonical @messages + tools into an Anthropic API request body.
      # @param messages [Array<Hash>] canonical messages (may include system)
      # @param model    [String]
      # @param tools    [Array<Hash>] OpenAI-style tool definitions
      # @param max_tokens [Integer]
      # @param caching_enabled [Boolean]
      # @return [Hash] ready to serialize as JSON body
      def build_request_body(messages, model, tools, max_tokens, caching_enabled)
        system_messages = messages.select { |m| m[:role] == "system" }
        regular_messages = messages.reject { |m| m[:role] == "system" }

        system_text = system_messages.map { |m| extract_text(m[:content]) }.join("\n\n")

        api_messages = regular_messages.map { |msg| to_api_message(msg, caching_enabled) }
        api_tools    = tools&.map { |t| to_api_tool(t) }

        if caching_enabled && api_tools&.any?
          api_tools.last[:cache_control] = { type: "ephemeral" }
        end

        body = { model: model, max_tokens: max_tokens, messages: api_messages }
        body[:system] = system_text unless system_text.empty?
        body[:tools]  = api_tools   if api_tools&.any?
        body
      end

      # Build a streaming request body (same as build_request_body but with
      # stream: true).  Used for the streaming-first strategy when the client
      # prefers streaming over non-streaming Anthropic requests.
      def build_stream_request_body(messages, model, tools, max_tokens, caching_enabled)
        body = build_request_body(messages, model, tools, max_tokens, caching_enabled)
        body[:stream] = true
        body
      end

      # ── Response parsing ──────────────────────────────────────────────────────

      # Parse Anthropic API response into canonical internal format.
      # @param data [Hash] parsed JSON response body
      # @return [Hash] canonical response: { content:, tool_calls:, finish_reason:, usage: }
      def parse_response(data)
        blocks  = data["content"] || []
        usage   = data["usage"]   || {}

        content = blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("")

        # tool_calls use canonical format (id, function: {name, arguments})
        tool_calls = blocks.select { |b| b["type"] == "tool_use" }.map do |tc|
          args = tc["input"].is_a?(String) ? tc["input"] : tc["input"].to_json
          { id: tc["id"], type: "function", name: tc["name"], arguments: args }
        end

        finish_reason = case data["stop_reason"]
                        when "end_turn"   then "stop"
                        when "tool_use"   then "tool_calls"
                        when "max_tokens" then "length"
                        else data["stop_reason"]
                        end

        # Anthropic native `input_tokens` counts ONLY the non-cached, freshly-billed
        # input — cache_read_input_tokens and cache_creation_input_tokens are
        # reported separately and are disjoint from input_tokens.
        #
        # Normalise to the codebase's canonical shape (OpenAI-style) so downstream
        # (ModelPricing.calculate_cost, CostTracker, show_token_usage) stays
        # provider-agnostic:
        #
        #   prompt_tokens     = non_cached + cache_read     (OpenAI convention:
        #                                                    includes cache_read
        #                                                    but NOT cache_write;
        #                                                    ModelPricing does
        #                                                    `regular_input = prompt_tokens - cache_read`.)
        #   completion_tokens = output
        #   total_tokens      = THIS TURN'S new compute volume
        #                     = raw_input + cache_creation + output
        #                       (cache_read is excluded because hits are ~free /
        #                        already-paid-for; cache_creation IS new work this
        #                        turn even though it's billed at write_rate.)
        #   cache_read_input_tokens / cache_creation_input_tokens → independent fields
        #
        # total_tokens is purely presentational. CostTracker treats it as the
        # per-iteration delta directly (no subtraction of previous_total), which
        # is the correct reading when total_tokens already means "new work this
        # turn" rather than "cumulative".
        raw_input_tokens  = usage["input_tokens"].to_i
        cache_read        = usage["cache_read_input_tokens"].to_i
        cache_creation    = usage["cache_creation_input_tokens"].to_i
        output_tokens     = usage["output_tokens"].to_i

        prompt_tokens = raw_input_tokens + cache_read

        usage_data = {
          prompt_tokens:      prompt_tokens,
          completion_tokens:  output_tokens,
          # Per-turn new compute: what the server freshly processed this request.
          # Excludes cache_read (nearly free, already-paid-for).
          total_tokens:       raw_input_tokens + cache_creation + output_tokens,
          # Signal to CostTracker: total_tokens above is already the per-turn
          # delta (not a running cumulative like OpenAI's). CostTracker should
          # NOT subtract previous_total when this flag is truthy.
          # OpenAI parse leaves this field unset; Bedrock may adopt the same
          # convention in future if we normalise it there too.
          total_is_per_turn: true
        }
        usage_data[:cache_read_input_tokens]     = cache_read     if cache_read     > 0
        usage_data[:cache_creation_input_tokens] = cache_creation if cache_creation > 0

        { content: content, tool_calls: tool_calls, finish_reason: finish_reason,
          usage: usage_data, raw_api_usage: usage }
      end

      # Parse Anthropic SSE streaming chunks into canonical format.
      #
      # Anthropic streaming format (SSE):
      #   event: message_start
      #   data: {"type":"message_start","message":{"id":"msg_...","usage":{"input_tokens":N}}}
      #
      #   event: content_block_start
      #   data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
      #
      #   event: content_block_delta
      #   data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
      #
      #   event: content_block_stop
      #   data: {"type":"content_block_stop","index":0}
      #
      #   event: message_delta
      #   data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":N}}
      #
      #   event: message_stop
      #   data: {"type":"message_stop"}
      #
      # Tool calls arrive as content blocks with type "tool_use":
      #   event: content_block_start
      #   data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_...","name":"func","input":{}}}
      #
      #   event: content_block_delta
      #   data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"..."}}
      #
      # @param raw_chunks [Array<String>] raw response body chunks from Faraday on_data
      # @return [Hash] canonical response: { content:, tool_calls:, finish_reason:, usage:, raw_api_usage: }
      def parse_stream_response(raw_chunks)
        body = raw_chunks.join
        events = parse_anthropic_sse_events(body)

        content       = +""
        tool_calls    = []
        current_tool  = nil   # { id:, name:, arguments: }
        finish_reason = nil
        usage_data    = {}
        cache_read    = 0
        cache_creation = 0

        events.each do |event|
          event_type = event[:type]
          data       = event[:data]

          case event_type
          when "message_start"
            msg = data["message"] || {}
            msg_usage = msg["usage"] || {}
            raw_input = msg_usage["input_tokens"].to_i
            cache_read = msg_usage["cache_read_input_tokens"].to_i
            cache_creation = msg_usage["cache_creation_input_tokens"].to_i
            usage_data["input_tokens"] = raw_input

          when "content_block_start"
            block = data["content_block"] || {}
            if block["type"] == "tool_use"
              current_tool = {
                id:   block["id"],
                name: block["name"],
                arguments: +""
              }
            end

          when "content_block_delta"
            delta = data["delta"] || {}
            case delta["type"]
            when "text_delta"
              content << delta["text"] if delta["text"]
            when "input_json_delta"
              if current_tool
                current_tool[:arguments] << delta["partial_json"] if delta["partial_json"]
              end
            end

          when "content_block_stop"
            if current_tool
              tool_calls << current_tool
              current_tool = nil
            end

          when "message_delta"
            delta = data["delta"] || {}
            finish_reason = case delta["stop_reason"]
                            when "end_turn"   then "stop"
                            when "tool_use"   then "tool_calls"
                            when "max_tokens" then "length"
                            else delta["stop_reason"]
                            end
            delta_usage = data["usage"] || {}
            usage_data["output_tokens"] = delta_usage["output_tokens"]
            cache_read += delta_usage["cache_read_input_tokens"].to_i
            cache_creation += delta_usage["cache_creation_input_tokens"].to_i

          when "message_stop"
            # End of stream — nothing to extract
          end
        end

        tool_calls = tool_calls.map do |tc|
          args = tc[:arguments].to_s
          # Validate and normalize JSON arguments
          begin
            JSON.parse(args)
          rescue JSON::ParserError
            # If arguments are not valid JSON, wrap them
            args = args.to_json
          end
          { id: tc[:id], type: "function", name: tc[:name], arguments: args }
        end
        tool_calls = nil if tool_calls.empty?

        # When tool_calls are present, override finish_reason
        finish_reason = "tool_calls" if tool_calls && !tool_calls.empty?

        # Normalise usage to canonical (OpenAI-style) format, same logic as parse_response
        raw_input_tokens  = usage_data["input_tokens"].to_i
        output_tokens     = usage_data["output_tokens"].to_i
        prompt_tokens     = raw_input_tokens + cache_read

        usage = {
          prompt_tokens:      prompt_tokens,
          completion_tokens:  output_tokens,
          total_tokens:       raw_input_tokens + cache_creation + output_tokens,
          total_is_per_turn:  true
        }
        usage[:cache_read_input_tokens]     = cache_read     if cache_read     > 0
        usage[:cache_creation_input_tokens] = cache_creation if cache_creation > 0

        {
          content:       content.empty? ? nil : content,
          tool_calls:    tool_calls,
          finish_reason: finish_reason,
          usage:         usage,
          raw_api_usage: usage_data.merge(
            "cache_read_input_tokens" => cache_read,
            "cache_creation_input_tokens" => cache_creation
          )
        }
      end

      # ── Tool result formatting ────────────────────────────────────────────────

      # Format tool results into canonical messages to append to @messages.
      # Input:  response (canonical, has :tool_calls), tool_results array
      # Output: canonical messages: [{ role: "tool", tool_call_id:, content: }]
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

      # Convert a single canonical message to Anthropic API format.
      # caching_enabled is kept for signature compatibility but is no longer used here —
      # cache_control markers are embedded into messages by Client#apply_message_caching
      # before build_request_body is called.
      private_class_method def self.to_api_message(msg, _caching_enabled)
        role      = msg[:role]
        content   = msg[:content]
        tool_calls = msg[:tool_calls]

        # assistant with tool_calls → content blocks with tool_use
        if role == "assistant" && tool_calls&.any?
          blocks = []
          blocks << { type: "text", text: content } if content.is_a?(String) && !content.empty?
          blocks.concat(content_to_blocks(content)) if content.is_a?(Array)

          tool_calls.each do |tc|
            func  = tc[:function] || tc
            name  = func[:name]  || tc[:name]
            raw_args = func[:arguments] || tc[:arguments]
            input = raw_args.is_a?(String) ? JSON.parse(raw_args) : raw_args
            blocks << { type: "tool_use", id: tc[:id], name: name, input: input || {} }
          end

          return { role: "assistant", content: blocks }
        end

        # canonical tool result (role: "tool") → Anthropic user message with tool_result block
        if role == "tool"
          # Strip any cache_control that Client#apply_message_caching may have
          # embedded INSIDE msg[:content] (it wraps string content as
          # [{type:"text", text:..., cache_control:{...}}]). We hoist that
          # marker up to the tool_result block itself below — that's where
          # Anthropic expects the marker for a tool_result turn.
          #
          # CRITICAL: if we leave cache_control on the inner text block, the
          # tool_result.content shape flips between "string" and
          # "[{text,cache_control}]" depending on whether this message is the
          # current cache breakpoint — which mutates the cached prefix every
          # turn and destroys cache_read hit-rate (the classic "cache_read
          # stuck at tiny number" symptom).
          hoisted_cache_control = nil
          raw_content = msg[:content]
          if raw_content.is_a?(Array) &&
             raw_content.length == 1 &&
             raw_content.first.is_a?(Hash) &&
             raw_content.first[:type] == "text" &&
             raw_content.first[:cache_control]
            hoisted_cache_control = raw_content.first[:cache_control]
            raw_content = raw_content.first[:text]
          end

          # If content is an Array of canonical blocks (e.g. image_url + text from file_reader),
          # convert each block to Anthropic format via content_to_blocks.
          # Plain strings pass through unchanged.
          tool_content = if raw_content.is_a?(Array)
                           content_to_blocks(raw_content)
                         else
                           raw_content
                         end
          block = { type: "tool_result", tool_use_id: msg[:tool_call_id], content: tool_content }
          block[:cache_control] = hoisted_cache_control if hoisted_cache_control
          return { role: "user", content: [block] }
        end

        # legacy Anthropic-native tool result already in user+tool_result format — pass through
        if role == "user" && content.is_a?(Array) && content.any? { |b| b.is_a?(Hash) && b[:type] == "tool_result" }
          return { role: "user", content: content }
        end

        # regular user/assistant message
        # NOTE: cache_control markers are applied by Client#apply_message_caching before
        # build_request_body is called. We must NOT add extra cache_control here, because:
        #   1. apply_message_caching already placed the marker on the correct breakpoint message.
        #   2. Adding cache_control to every user message causes Anthropic to treat every
        #      user message as a cache breakpoint, which invalidates the intended cache boundary
        #      and results in cache misses (cache_read=0) every turn.
        blocks = content_to_blocks(content)
        # Anthropic rejects messages with an empty content array — use a placeholder text block.
        blocks = [{ type: "text", text: "..." }] if blocks.empty?
        { role: role, content: blocks }
      end

      # Convert content (String or Array) to Anthropic content block array.
      # cache_control markers already embedded by Client#apply_message_caching are preserved.
      private_class_method def self.content_to_blocks(content)
        case content
        when String
          # Anthropic rejects blank text blocks — skip empty strings
          return [] if content.empty?

          [{ type: "text", text: content }]
        when Array
          content.map { |b| normalize_block(b) }.compact
        else
          str = content.to_s
          return [] if str.empty?

          [{ type: "text", text: str }]
        end
      end

      # Normalize a single content block to Anthropic format.
      private_class_method def self.normalize_block(block)
        return block unless block.is_a?(Hash)

        case block[:type]
        when "text"
          # Anthropic rejects blank text blocks — drop them instead of sending { type:"text", text:"" }
          text = block[:text]
          return nil if text.nil? || text.empty?

          # Preserve cache_control if present (placed by Client#apply_message_caching)
          result = { type: "text", text: text }
          result[:cache_control] = block[:cache_control] if block[:cache_control]
          result
        when "image_url"
          url = block.dig(:image_url, :url) || block[:url]
          url_to_image_block(url)
        when "image"
          block  # already Anthropic format
        when "tool_result", "tool_use"
          block  # pass through
        else
          block
        end
      end

      # Convert an image URL to Anthropic image block.
      private_class_method def self.url_to_image_block(url)
        return nil unless url

        if url.start_with?("data:")
          match = url.match(/^data:([^;]+);base64,(.*)$/)
          if match
            { type: "image", source: { type: "base64", media_type: match[1], data: match[2] } }
          else
            { type: "image", source: { type: "url", url: url } }
          end
        else
          { type: "image", source: { type: "url", url: url } }
        end
      end

      # Convert OpenAI-style tool definition to Anthropic format.
      private_class_method def self.to_api_tool(tool)
        func = tool[:function] || tool
        { name: func[:name], description: func[:description], input_schema: func[:parameters] }
      end

      # Extract plain text from content (String or Array).
      private_class_method def self.extract_text(content)
        case content
        when String then content
        when Array  then content.map { |b| b.is_a?(Hash) ? (b[:text] || "") : b.to_s }.join("\n")
        else             content.to_s
        end
      end

      # Parse raw Anthropic SSE body into an array of { type:, data: } hashes.
      # Anthropic streaming uses both `event:` and `data:` lines:
      #   event: message_start
      #   data: {"type":"message_start",...}
      #
      # The parser is tolerant: if `event:` lines are absent, it falls back
      # to inspecting the data payload's `type` field to classify the event.
      private_class_method def self.parse_anthropic_sse_events(body)
        events       = []
        current_type = nil
        current_data = nil

        body.each_line do |line|
          line = line.chomp

          if line.start_with?("event: ")
            current_type = line[7..].strip
          elsif line.start_with?("data: ")
            data_str = line[6..]
            next if data_str.strip == "[DONE]"

            parsed = begin
              JSON.parse(data_str)
            rescue JSON::ParserError
              nil
            end
            next unless parsed

            # If no event type was declared, infer it from the data's "type" field
            unless current_type
              current_type = parsed["type"]
            end

            current_data = parsed
          elsif line.empty?
            # Empty line = end of event. Flush the current event.
            if current_type && current_data
              events << { type: current_type, data: current_data }
            end
            current_type = nil
            current_data = nil
          end
        end

        # Flush the last event if the stream didn't end with a blank line
        if current_type && current_data
          events << { type: current_type, data: current_data }
        end

        events
      end
    end
  end
end
