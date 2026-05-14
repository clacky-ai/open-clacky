# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "tmpdir"
require "shellwords"
require "yaml"
require "base64"
require "fileutils"
require "securerandom"
require_relative "base"

module Clacky
  module Tools
    # Browser tool — controls the user's real Chromium-based browser (Chrome 146+)
    # via the Chrome DevTools MCP server (chrome-devtools-mcp).
    #
    # Architecture: uses the existing-session driver (Chrome MCP).
    #   chrome-devtools-mcp --autoConnect --experimentalStructuredContent
    #       --experimental-page-id-routing
    #
    # Communication: MCP stdio JSON-RPC 2.0 over a *persistent* (daemon) process.
    # The MCP server process is started once, kept alive across all tool calls,
    # and only restarted when the process dies unexpectedly.
    #
    # Page ownership model (strict isolation, since 2026-05):
    #   Every Browser instance maintains its own @owned_pages — the list
    #   of Chrome page ids that this Clacky process has explicitly opened
    #   (via action=open) or adopted (via action=adopt).  Tabs opened by
    #   other Clacky processes, by the user, or as side-effects of clicks
    #   (target=_blank / window.open) are INVISIBLE to this process:
    #     • action=tabs   only lists owned tabs
    #     • action=focus  only accepts owned tab ids
    #     • action=close  only closes owned tabs
    #     • snapshot/act/navigate only operate on the owned @last_page_id
    #   This eliminates cross-session race conditions on shared pages
    #   (uid reuse, page-state interference, tab-close-from-under-me) by
    #   simply forbidding two Clacky processes from touching the same tab.
    #
    #   New tabs spawned by a user-initiated act (e.g. middle-click, JS
    #   window.open) are surfaced to the AI as a hint with id, and must
    #   be explicitly claimed via action=adopt before any operation can
    #   be performed against them.
    #
    #   When the selected page has been closed externally, mcp_call falls
    #   through to a "no active tab" error — the AI is expected to
    #   action=open a new one.
    class Browser < Base
      def initialize
        super
        @owned_pages  = []     # Array<Integer> — keeps open-order
        @last_page_id = nil    # Integer, must always be ∈ @owned_pages or nil
        @known_page_ids = nil  # Snapshot of all live page ids at start of last act; used to detect new tabs spawned by act
      end

      self.tool_name = "browser"
      self.tool_description = <<~DESC.strip
        Control user's real Chrome (146+) for web automation. Prefer web_fetch/web_search for read-only pages.
        Actions: snapshot | act | open | navigate | tabs | focus | close | screenshot | status | adopt.
        Always snapshot(interactive:true) before act. screenshot is EXPENSIVE — use ref= for a single element.
        act kinds: click, dblclick, type, fill, press, hover, scroll, drag, select, wait, evaluate, click_at (coord fallback).

        Page ownership: each Clacky process only sees tabs it opened (action=open) or adopted (action=adopt).
        Other tabs are invisible. If a click spawns a new tab, the AI will receive a hint with the tab id and must adopt it first.
      DESC
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: %w[snapshot act open navigate tabs focus close screenshot status adopt]
          },
          kind: {
            type: "string",
            enum: %w[click dblclick type fill press hover drag select scroll wait evaluate click_at],
            description: "act: interaction kind"
          },
          ref:         { type: "string",  description: "element ref from snapshot (e.g. 'e1'); screenshot: single element" },
          text:        { type: "string",  description: "act type/fill text" },
          key:         { type: "string",  description: "act press key (e.g. 'Enter')" },
          direction:   { type: "string",  enum: %w[up down left right], description: "act scroll" },
          amount:      { type: "integer", description: "act scroll pixels" },
          ms:          { type: "integer", description: "act wait ms" },
          selector:    { type: "string",  description: "act wait CSS selector" },
          js:          { type: "string",  description: "act evaluate JS" },
          target_ref:  { type: "string",  description: "act drag destination ref" },
          values:      { type: "array",   items: { type: "string" }, description: "act select options" },
          x:           { type: "number",  description: "click_at x px" },
          y:           { type: "number",  description: "click_at y px" },
          url:         { type: "string",  description: "open/navigate URL" },
          target_id:   { type: "string",  description: "focus/close/adopt tab id" },
          interactive: { type: "boolean", description: "snapshot: interactive only" },
          compact:     { type: "boolean", description: "snapshot: compact" },
          depth:       { type: "integer", description: "snapshot: max depth" },
          full_page:   { type: "boolean", description: "screenshot: full page" }
        },
        required: ["action"]
      }

      MIN_CHROME_MAJOR      = 146
      MCP_HANDSHAKE_TIMEOUT = 10
      MCP_CALL_TIMEOUT      = 60
      MIN_NODE_MAJOR        = 20
      MAX_SNAPSHOT_CHARS    = 4000
      MAX_LLM_OUTPUT_CHARS  = 6000

      def execute(action:, profile: nil, working_dir: nil, **opts)
        bypass = action.to_s == "status" ||
                 (action.to_s == "act" && (opts[:kind] || opts["kind"]).to_s == "evaluate")
        unless bypass
          return browser_not_setup_error unless File.exist?(BROWSER_CONFIG_PATH)
          return browser_disabled_error  unless browser_enabled?
        end
        execute_user_browser(action, opts)
      rescue StandardError => e
        { error: classify_browser_error(e) }
      end

      def format_call(args)
        action = args[:action] || args["action"] || "browser"
        "browser(#{action})"
      end

      def format_result(result)
        return "[Error] #{result[:error].to_s[0..80]}" if result[:error]
        return "[OK] #{result[:output].to_s.lines.size} lines" if result[:output]
        "[OK] Done"
      end

      def format_result_for_llm(result)
        return result if result[:error]

        action = result[:action].to_s

        if action == "screenshot" && result[:image_data]
          mime_type       = result[:mime_type] || "image/png"
          image_data      = result[:image_data]
          data_url        = "data:#{mime_type};base64,#{image_data}"
          original_path   = result[:original_path]
          compressed_path = result[:compressed_path]

          text = "Screenshot captured."
          if original_path || compressed_path
            text += "\n- Original (full resolution): #{original_path || 'unavailable'}" \
                    "\n- Compressed (800px, sent to AI): #{compressed_path || 'unavailable'}"
          end

          return [
            { type: "text",      text:      text },
            { type: "image_url", image_url: { url: data_url } }
          ]
        end

        output = result[:output].to_s
        output = compress_snapshot(output) if action == "snapshot"
        max_chars = action == "snapshot" ? MAX_SNAPSHOT_CHARS : MAX_LLM_OUTPUT_CHARS

        {
          action:  action,
          success: result[:success],
          stdout:  truncate_output(output, max_chars),
          profile: result[:profile]
        }.compact
      end


      BROWSER_CONFIG_PATH = File.expand_path("~/.clacky/browser.yml").freeze

      BROWSER_DIAGNOSIS_HINT = <<~HINT.strip.freeze
        Inform the user and ask if they'd like to run a diagnosis.
        If yes, invoke the browser-setup skill with subcommand "doctor".
      HINT

      # Cause 1+2: Chrome not running, or Remote Debugging disabled (MCP can't distinguish them)
      BROWSER_NOT_CONNECTED_HINT = <<~HINT.strip.freeze
        Chrome is not reachable. Possible causes:
        1. Chrome is not running — ask the user to open Chrome.
        2. Remote Debugging is disabled — enable via chrome://inspect/#remote-debugging.
      HINT

      # Cause 3: MCP daemon crashed or failed to start
      BROWSER_DAEMON_HINT = <<~HINT.strip.freeze
        The browser MCP daemon crashed or failed to start. It may recover automatically on the next action.
        If it keeps failing, ask the user to restart Clacky.
      HINT

      # Cause 4: Chrome long-session unresponsiveness
      BROWSER_RESTART_HINT = <<~HINT.strip.freeze
        Chrome has become unresponsive. This often happens after Chrome has been running for a long time.
        Ask the user to restart Chrome, then retry the action.
      HINT

      # Classify a browser error and return an appropriate message for the AI.
      # Only Chrome connectivity errors (causes 1-4) get a specific hint + diagnosis offer.
      # MCP business errors (wrong params, stale element, page closed, etc.) pass through as-is.
      private def classify_browser_error(e)
        msg = e.message.to_s

        # Cause 4: Chrome unresponsive after long session (timed out waiting for MCP response)
        if msg.include?("timed out after")
          return "Browser error: #{msg}\n\n#{BROWSER_RESTART_HINT}\n\n#{BROWSER_DIAGNOSIS_HINT}"
        end

        # Cause 1+2: Chrome not running or Remote Debugging disabled
        if msg.include?("Could not connect to Chrome")
          return "Browser error: #{msg}\n\n#{BROWSER_NOT_CONNECTED_HINT}\n\n#{BROWSER_DIAGNOSIS_HINT}"
        end

        # Cause 3: MCP daemon crashed or handshake failed
        if msg.include?("handshake timed out") || msg.include?("Chrome MCP tool") || msg.include?("Chrome MCP initialize")
          return "Browser error: #{msg}\n\n#{BROWSER_DAEMON_HINT}\n\n#{BROWSER_DIAGNOSIS_HINT}"
        end

        # All other errors: MCP business errors, element/page errors — AI can self-correct.
        "Browser error: #{msg}"
      end

      private def browser_enabled?
        config = YAMLCompat.safe_load(File.read(BROWSER_CONFIG_PATH), permitted_classes: [Date, Time, Symbol])
        config.is_a?(Hash) && config["enabled"] == true
      end

      private def browser_not_setup_error
        {
          error: <<~MSG
            The browser tool is not configured. This tool call has been rejected to protect user experience.

            Ask the user if they'd like to set up the browser, then invoke the browser-setup skill to guide them through the setup. Retry this tool call after setup is complete.
          MSG
        }
      end

      private def browser_disabled_error
        {
          error: <<~MSG
            The browser tool is disabled by the user. This tool call has been rejected.

            Inform the user that they have disabled the browser tool. They can re-enable it from settings or by running "/browser-setup".
          MSG
        }
      end

      # -----------------------------------------------------------------------
      # Action dispatch
      # -----------------------------------------------------------------------

      private def execute_user_browser(action, opts)

        case action.to_s
        when "tabs"
          all_pages = extract_pages(mcp_call("list_pages"))
          reconcile_owned_pages!(all_pages)
          mine = all_pages.select { |p| @owned_pages.include?(p[:id]) }
          { action: "tabs", success: true, profile: "user", output: format_tabs(mine), tabs: mine }

        when "snapshot"
          raw  = mcp_call("take_snapshot")
          text = build_ai_snapshot(extract_snapshot(raw),
                                   interactive: opts[:interactive] || opts["interactive"],
                                   compact:     opts[:compact]     || opts["compact"],
                                   max_depth:   opts[:depth]       || opts["depth"])
          { action: "snapshot", success: true, profile: "user", output: text }

        when "open"
          url = require_url(opts)
          return url if url.is_a?(Hash)
          result = mcp_call("new_page", { url: url, background: background_mode? })
          new_id = extract_new_page_id(result)
          @owned_pages << new_id unless @owned_pages.include?(new_id)
          @last_page_id = new_id
          { action: "open", success: true, profile: "user", url: url, output: "Opened: #{url}" }

        when "navigate"
          url = require_url(opts)
          return url if url.is_a?(Hash)
          mcp_call("navigate_page", { type: "url", url: url })
          { action: "navigate", success: true, profile: "user", url: url, output: "Navigated to: #{url}" }

        when "focus"
          target = require_owned_target_id(opts, "focus")
          return target if target.is_a?(Hash)
          mcp_call("select_page", { pageId: target, bringToFront: true })
          @last_page_id = target
          { action: "focus", success: true, profile: "user", output: "Focused tab #{target}" }

        when "adopt"
          target_id = opts[:target_id] || opts["target_id"]
          return { error: "target_id is required for adopt." } if target_id.nil? || target_id.to_s.empty?
          target = target_id.to_i
          # Verify the page actually exists in Chrome.
          all_pages = extract_pages(mcp_call("list_pages"))
          unless all_pages.any? { |p| p[:id] == target }
            return { error: "Tab #{target} does not exist (was it closed?)." }
          end
          @owned_pages << target unless @owned_pages.include?(target)
          mcp_call("select_page", { pageId: target, bringToFront: true })
          @last_page_id = target
          { action: "adopt", success: true, profile: "user", output: "Adopted tab #{target}" }

        when "close"
          target = require_owned_target_id(opts, "close")
          return target if target.is_a?(Hash)
          mcp_call("close_page", { pageId: target })
          @owned_pages.delete(target)
          @last_page_id = nil if @last_page_id == target
          # Auto-focus the most-recently opened remaining owned tab, if any.
          if @last_page_id.nil? && !@owned_pages.empty?
            @last_page_id = @owned_pages.last
            mcp_call("select_page", { pageId: @last_page_id, bringToFront: true }) rescue nil
          end
          { action: "close", success: true, profile: "user", output: "Closed tab #{target}" }

        when "act"
          do_user_act(opts)

        when "screenshot"
          do_user_screenshot(opts)

        when "status"
          all_pages = extract_pages(mcp_call("list_pages"))
          reconcile_owned_pages!(all_pages)
          mine = all_pages.select { |p| @owned_pages.include?(p[:id]) }
          { action: "status", success: true, profile: "user",
            output: "Browser running. #{mine.size} owned tab(s) (of #{all_pages.size} total).",
            tabs: mine }

        else
          { error: "Action '#{action}' is not supported." }
        end
      end

      private def do_user_act(opts)
        kind = (opts[:kind] || opts["kind"] || "click").to_s
        ref  = opts[:ref]   || opts["ref"]

        # Capture all live page ids BEFORE acting, so we can detect new tabs
        # spawned by the action (target=_blank, window.open, ctrl-click, etc.).
        # Skip cheap actions that can't spawn tabs (wait, scroll, evaluate via JS-only).
        if %w[click dblclick press hover drag select click_at evaluate].include?(kind)
          pages = extract_pages(Clacky::BrowserManager.instance.mcp_call("list_pages")) rescue []
          @known_page_ids = pages.map { |p| p[:id] }
        else
          @known_page_ids = nil
        end

        case kind
        when "click", "dblclick"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          args = { uid: uid }
          args[:dblClick] = true if kind == "dblclick"
          mcp_call("click", args)

        when "fill", "type"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          mcp_call("fill", { uid: uid, value: opts[:text] || opts["text"] || "" })

        when "press"
          mcp_call("press_key", { key: opts[:key] || opts["key"] || "Enter" })

        when "hover"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          mcp_call("hover", { uid: uid })

        when "drag"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          mcp_call("drag", { from_uid: uid, to_uid: opts[:target_ref] || opts["target_ref"] || "" })

        when "select"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          values = Array(opts[:values] || opts["values"] || [])
          mcp_call("fill", { uid: uid, value: values.first.to_s })

        when "scroll"
          direction = opts[:direction] || opts["direction"] || "down"
          amount    = (opts[:amount]   || opts["amount"]   || 300).to_i
          dx = case direction; when "right" then amount; when "left" then -amount; else 0; end
          dy = case direction; when "down"  then amount; when "up"   then -amount; else 0; end
          mcp_call("evaluate_script", { function: "() => { window.scrollBy(#{dx}, #{dy}) }" })

        when "wait"
          ms  = opts[:ms]       || opts["ms"]
          sel = opts[:selector] || opts["selector"]
          if ms
            sleep(ms.to_i / 1000.0)
            return { action: "act", success: true, profile: "user", output: "Waited #{ms}ms" }
          elsif sel
            mcp_call("wait_for", { text: [sel] })
          else
            sleep(1)
          end

        when "evaluate"
          js = opts[:js] || opts["js"] || ""
          # evaluate_script is a PAGE_CONTEXT_TOOL, so ensure_page_selected!
          # has already validated @last_page_id is owned and selected.
          result = mcp_call("evaluate_script", { function: "() => { return (#{js}) }" })
          return { action: "act", success: true, profile: "user", output: extract_message(result).to_s }

        when "click_at"
          x = opts[:x] || opts["x"]
          y = opts[:y] || opts["y"]
          return { error: "click_at requires x and y coordinates" } unless x && y
          result = mcp_call("click_at", { x: x.to_f, y: y.to_f })
          return { action: "act", success: true, profile: "user", output: extract_message(result).to_s }

        else
          return { error: "Unknown act kind: #{kind}" }
        end

        # After any act that might have opened a new tab (click, dblclick, evaluate, etc.),
        # detect new tabs and surface them to the AI so they can adopt them if needed.
        hint = detect_new_tab_hint
        output = "#{kind} completed."
        output += "\n\n#{hint}" if hint

        { action: "act", success: true, profile: "user", output: output }
      end

      SCREENSHOT_MAX_WIDTH        = 800
      SCREENSHOT_MAX_BASE64_BYTES = 150_000

      private def do_user_screenshot(opts)
        full_page = opts[:full_page] || opts["full_page"] || false
        uid       = opts[:ref]       || opts["ref"]

        call_args = { format: "png", fullPage: full_page }
        call_args[:uid] = uid if uid
        result = mcp_call("take_screenshot", call_args)

        image_block = Array(result["content"]).find { |b| b.is_a?(Hash) && b["type"] == "image" }

        unless image_block
          text = extract_text_content(result)
          return { action: "screenshot", success: true, profile: "user",
                   output: text.empty? ? "Screenshot captured." : text }
        end

        # Save original (full-resolution) PNG to disk before any downscaling
        original_path = save_screenshot_to_disk(image_block["data"], suffix: "original")

        image_data = png_downscale_base64(image_block["data"], SCREENSHOT_MAX_WIDTH)

        if image_data.bytesize > SCREENSHOT_MAX_BASE64_BYTES
          size_kb = image_data.bytesize / 1024
          return { action: "screenshot", success: false, profile: "user",
                   output: "Screenshot too large after resize (#{size_kb}KB). Use action=snapshot instead." }
        end

        # Save compressed (800px) PNG for AI reference
        compressed_path = save_screenshot_to_disk(image_data, suffix: "compressed")

        { action: "screenshot", success: true, profile: "user",
          image_data: image_data, mime_type: "image/png",
          original_path: original_path, compressed_path: compressed_path,
          output: "Screenshot captured." }
      end

      private def png_downscale_base64(b64, max_width)
        Clacky::Utils::FileProcessor.downscale_image_base64(
          b64, "image/png", max_width: max_width
        )
      end

      # Save a base64-encoded PNG screenshot to disk and return the file path.
      # suffix: "original" or "compressed" — embedded in filename for clarity.
      # Uses the same upload directory as other image files so the agent can
      # reference, read, or pass the path to other tools.
      private def save_screenshot_to_disk(base64_data, suffix: nil)
        upload_dir = File.join(Dir.tmpdir, "clacky-uploads")
        FileUtils.mkdir_p(upload_dir)
        ts       = Time.now.strftime("%Y%m%d_%H%M%S")
        hex      = SecureRandom.hex(4)
        label    = suffix ? "_#{suffix}" : ""
        filename = "screenshot_#{ts}_#{hex}#{label}.png"
        path     = File.join(upload_dir, filename)
        File.binwrite(path, Base64.strict_decode64(base64_data))
        path
      rescue => e
        Clacky::Logger.error("screenshot_save_failed", error: e.message)
        nil
      end

      # -----------------------------------------------------------------------
      # Chrome MCP
      # -----------------------------------------------------------------------

      # Tools that operate on the "currently selected page" and therefore
      # need a preceding select_page if this process has a remembered page.
      PAGE_CONTEXT_TOOLS = %w[
        take_snapshot take_screenshot navigate_page
        click click_at hover drag fill press_key evaluate_script wait_for
      ].freeze

      # Whether the agent should operate the browser silently in the background
      # (i.e. never steal focus from the user's current tab / terminal).
      # Default: true. Controlled by ~/.clacky/browser.yml `background_mode`.
      private def background_mode?
        Clacky::BrowserManager.instance.background_mode?
      end

      private def mcp_call(tool_name, arguments = {})
        ensure_page_selected!(tool_name)
        Clacky::BrowserManager.instance.mcp_call(tool_name, arguments)
      rescue RuntimeError => e
        msg = e.message.to_s.downcase
        page_closed = msg.include?("selected page has been closed") ||
                      msg.include?("page has been closed") ||
                      msg.include?("tab was closed")
        raise unless page_closed

        # The daemon's `selectedPage` reference points at a closed pptr Page.
        # chrome-devtools-mcp throws this error at the tool entry (before the
        # handler runs), so even `list_pages`/`select_page` cannot heal it
        # — every mcp call has to go through `getSelectedMcpPage()` first.
        #
        # The only reliable recovery is to restart the daemon: a fresh
        # chrome-devtools-mcp process reconnects to the same Chrome via the
        # existing wsEndpoint and rebuilds its page map from scratch, with
        # `selectedPage` defaulting to whatever Chrome currently has open.
        Clacky::Logger.warn(
          "[Browser] Daemon's selected page is dead — restarting daemon to recover"
        )
        Clacky::BrowserManager.instance.force_stop
        # ensure_daemon! runs lazily inside the next mcp_call.
        Clacky::BrowserManager.instance.mcp_call(tool_name, arguments)
      end

      # Before every tool call that needs a page context, verify that:
      #   1) We have a remembered page
      #   2) That page is still in our ownership list
      #   3) Re-issue select_page so Chrome MCP routes the call correctly.
      #
      # If the page was closed externally we remove it from @owned_pages and
      # raise — the AI must open/adopt a new one.
      private def ensure_page_selected!(tool_name)
        return unless PAGE_CONTEXT_TOOLS.include?(tool_name)

        unless @last_page_id
          raise "No active tab. Use action=open to create a new tab first."
        end

        unless @owned_pages.include?(@last_page_id)
          @last_page_id = nil
          raise "The active tab was closed or is no longer owned. " \
                "Use action=open to create a new tab, or action=adopt to claim one."
        end

        Clacky::BrowserManager.instance.mcp_call(
          "select_page",
          { pageId: @last_page_id.to_i, bringToFront: !background_mode? }
        )
      rescue RuntimeError => e
        msg = e.message.to_s.downcase
        if msg.include?("selected page has been closed") || msg.include?("page has been closed") || msg.include?("tab was closed")
          @owned_pages.delete(@last_page_id)
          @last_page_id = nil
          raise "The browser tab was closed. Use action=open to open a new tab, then retry."
        end
        raise
      end

      # -----------------------------------------------------------------------
      # MCP response extractors
      # -----------------------------------------------------------------------

      private def extract_new_page_id(result)
        return nil unless result.is_a?(Hash)

        structured = result["structuredContent"]
        if structured.is_a?(Hash)
          return structured["pageId"] if structured["pageId"]
          pages = structured["pages"]
          if pages.is_a?(Array)
            new_page = pages.find { |p| p["selected"] == true }
            return new_page["id"] if new_page
          end
        end

        text = extract_text_content(result)
        m = text.match(/page\s*id[:\s]+(\d+)/i)
        m[1].to_i if m
      end

      private def extract_pages(result)
        return [] unless result.is_a?(Hash)

        structured = result["structuredContent"]
        if structured.is_a?(Hash) && structured["pages"].is_a?(Array)
          return structured["pages"].map do |p|
            { id: p["id"], url: p["url"], selected: p["selected"] == true }
          end
        end

        parse_pages_from_text(extract_text_content(result))
      end

      private def extract_snapshot(result)
        return {} unless result.is_a?(Hash)

        structured = result["structuredContent"]
        return structured["snapshot"] if structured.is_a?(Hash) && structured["snapshot"].is_a?(Hash)

        begin
          JSON.parse(extract_text_content(result))
        rescue StandardError
          {}
        end
      end

      private def extract_message(result)
        return "" unless result.is_a?(Hash)

        structured = result["structuredContent"]
        return structured["message"].to_s if structured.is_a?(Hash) && structured["message"]

        extract_text_content(result)
      end

      private def extract_text_content(result)
        return "" unless result.is_a?(Hash)
        Array(result["content"]).filter_map do |entry|
          entry["text"] if entry.is_a?(Hash) && entry["text"].is_a?(String)
        end.join("\n")
      end

      private def parse_pages_from_text(text)
        text.each_line.filter_map do |line|
          m = line.match(/^\s*(\d+):\s+(.+?)(?:\s+\[(selected)\])?\s*$/i)
          next unless m
          { id: m[1].to_i, url: m[2].strip, selected: !m[3].nil? }
        end
      end

      private def format_tabs(pages)
        return "No open tabs." if pages.empty?
        pages.map { |p| "#{p[:id]}: #{p[:url]}#{p[:selected] ? ' [selected]' : ''}" }.join("\n")
      end

      # -----------------------------------------------------------------------
      # Snapshot rendering
      # -----------------------------------------------------------------------

      INTERACTIVE_ROLES = %w[
        button link textbox checkbox radio select combobox
        menuitem option tab switch searchbox spinbutton
        slider menuitemcheckbox menuitemradio
      ].freeze

      STRUCTURAL_ROLES = %w[
        generic none presentation group region section
      ].freeze

      CONTENT_ROLES = %w[
        heading paragraph text statictext image img
        listitem term definition
      ].freeze

      private def build_ai_snapshot(node, interactive: false, compact: false, max_depth: nil)
        return "" unless node.is_a?(Hash) && !node.empty?

        lines = []
        refs  = {}
        visit_node(node, 0, lines, refs, interactive: interactive, compact: compact, max_depth: max_depth)
        lines.join("\n")
      end

      private def visit_node(node, depth, lines, refs, interactive:, compact:, max_depth:)
        return if max_depth && depth > max_depth

        role = node["role"].to_s.downcase.strip
        role = "generic" if role.empty?
        name = node["name"].to_s.strip
        uid  = node["id"].to_s.strip
        val  = node["value"]
        desc = node["description"].to_s.strip

        render = true
        render = false if interactive && !INTERACTIVE_ROLES.include?(role)
        render = false if compact && STRUCTURAL_ROLES.include?(role) && name.empty?

        if render
          line = "#{" " * (depth * 2)}- #{role}"
          line += " \"#{escape_quoted(name)}\"" unless name.empty?

          if uid && !uid.empty? && (INTERACTIVE_ROLES.include?(role) ||
                                    (CONTENT_ROLES.include?(role) && !name.empty?))
            refs[uid] = { role: role, name: name }
            line += " [ref=#{uid}]"
          end

          line += " value=\"#{escape_quoted(val.to_s)}\"" unless val.nil? || val.to_s.empty?
          line += " description=\"#{escape_quoted(desc)}\"" unless desc.empty?
          lines << line
        end

        child_depth = render ? depth + 1 : depth
        Array(node["children"]).each do |child|
          visit_node(child, child_depth, lines, refs, interactive: interactive, compact: compact, max_depth: max_depth)
        end
      end

      private def escape_quoted(str)
        str.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
      end

      # -----------------------------------------------------------------------
      # Parameter helpers
      # -----------------------------------------------------------------------

      private def require_url(opts)
        url = opts[:url] || opts["url"] || ""
        return { error: "url is required for this action" } if url.empty?
        url
      end

      private def require_ref(ref)
        return { error: "ref is required for this act kind (snapshot first to get refs)" } if ref.nil? || ref.to_s.empty?
        ref.to_s
      end

      # -----------------------------------------------------------------------
      # Output helpers
      # -----------------------------------------------------------------------

      # After an act, compare current live page ids with the snapshot taken
      # before the act. Any new ids that are not yet owned belong to tabs
      # spawned by the act (target=_blank, window.open, etc.). Surface a
      # hint so the AI can adopt them.
      private def detect_new_tab_hint
        return nil unless @known_page_ids

        current = extract_pages(mcp_call("list_pages")) rescue []
        current_ids = current.map { |p| p[:id] }
        new_ids = current_ids - @known_page_ids - @owned_pages
        @known_page_ids = nil

        return nil if new_ids.empty?

        lines = new_ids.map do |id|
          page = current.find { |p| p[:id] == id }
          url  = page ? page[:url] : "unknown"
          "  • tab #{id}: #{url}"
        end
        "New tab(s) detected:\n#{lines.join("\n")}\nUse action=adopt with target_id to claim one."
      end

      # -----------------------------------------------------------------------
      # Page ownership helpers
      # -----------------------------------------------------------------------

      # Remove from @owned_pages any ids that are no longer alive in Chrome.
      # Also clear @last_page_id if it was among the dead.
      private def reconcile_owned_pages!(all_pages)
        alive_ids = all_pages.map { |p| p[:id] }
        dead = @owned_pages.reject { |id| alive_ids.include?(id) }
        dead.each do |id|
          @owned_pages.delete(id)
          @last_page_id = nil if @last_page_id == id
        end
      end

      # -----------------------------------------------------------------------
      # Ownership-aware parameter helpers
      # -----------------------------------------------------------------------

      private def require_owned_target_id(opts, action_name)
        target_id = opts[:target_id] || opts["target_id"]
        if target_id.nil? || target_id.to_s.empty?
          return { error: "target_id is required for #{action_name}. Use action=tabs to list your tabs." }
        end
        target = target_id.to_i
        unless @owned_pages.include?(target)
          return { error: "Tab #{target} is not owned by this session. " \
                          "Owned tabs: #{@owned_pages.inspect}. " \
                          "Use action=open to create a new tab, or action=adopt to claim one." }
        end
        target
      end

      private def compress_snapshot(output)
        return output if output.empty?

        lines    = output.lines
        orig     = lines.size
        filtered = lines.reject do |line|
          s = line.strip
          s.start_with?("- /url:", "/url:", "- /placeholder:", "/placeholder:") ||
            s == "- img" || s.match?(/\A-\s+img\s*\z/)
        end

        removed = orig - filtered.size
        filtered << "\n[snapshot compressed: #{removed} lines removed]\n" if removed > 0
        filtered.join
      end

      private def truncate_output(output, max_chars)
        return output if output.length <= max_chars

        lines      = output.lines
        available  = max_chars - 150
        first_part = []
        acc        = 0
        lines.each do |line|
          break if acc + line.length > available
          first_part << line
          acc += line.length
        end
        first_part.join + "\n... [truncated: #{first_part.size}/#{lines.size} lines shown] ..."
      end
    end
  end
end
