# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "tmpdir"
require "shellwords"
require_relative "base"

module Clacky
  module Tools
    # Browser tool — controls the user's real Chromium-based browser (Chrome 146+)
    # via the Chrome DevTools MCP server (chrome-devtools-mcp).
    #
    # Architecture: profile="user" uses the existing-session driver (Chrome MCP).
    #   npx -y chrome-devtools-mcp@latest --autoConnect --experimentalStructuredContent
    #       --experimental-page-id-routing [--userDataDir <path>]
    #
    # Communication: MCP stdio JSON-RPC 2.0 over a *persistent* (daemon) process.
    # The MCP server process is started once, kept alive across all tool calls,
    # and only restarted when the process dies unexpectedly.  This means Chrome
    # shows the "Allow remote debugging" dialog exactly once per daemon lifetime.
    #
    # No agent-browser, no DevToolsActivePort, no CDP port management.
    class Browser < Base
      self.tool_name = "browser"
      self.tool_description = <<~DESC
        Control the browser for automation tasks (login, form submission, UI interaction, scraping).
        For simple page fetch or search, prefer web_fetch or web_search instead.

        Uses your real Chrome browser (profile="user") with existing logins & cookies. Requires Chrome 146+.

        ACTIONS OVERVIEW:
        - snapshot   → get accessibility tree with element refs. ALWAYS run before interacting.
        - act        → interact with page: click, type, fill, press, hover, scroll, drag, select, wait, evaluate
        - open       → open URL in a new tab
        - navigate   → navigate current tab to URL
        - tabs       → list open tabs
        - focus      → switch to a tab by targetId
        - close      → close current tab
        - screenshot → capture screenshot. Ask user first (high token cost).
        - status     → check if browser is running

        SNAPSHOT WORKFLOW — always snapshot first:
        - action="snapshot"                            → full accessibility tree
        - action="snapshot", interactive=true          → interactive elements only (recommended)
        - action="snapshot", interactive=true, compact=true → compact interactive

        ACT KINDS: click, dblclick, type, fill, press, hover, drag, select, scroll, wait, evaluate, click_at
        - click:    ref="e1"
        - click_at: x=100, y=200  → coordinate click, use when ref-based click fails (React/virtual lists)
        - fill:     ref="e1", text="value"
        - press:    key="Enter"
        - scroll:   direction="down", amount=300
        - wait:     ms=2000 OR selector=".spinner"
        - evaluate: js="document.title"

        TARGETING TABS — pass target_id from snapshot/tabs to subsequent acts.
      DESC
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: %w[snapshot act open navigate tabs focus close screenshot status],
            description: "Action to perform."
          },
          profile: {
            type: "string",
            enum: %w[user],
            description: "Browser profile. Only 'user' is supported — uses your real Chrome browser with existing logins & cookies."
          },
          interactive: {
            type: "boolean",
            description: "snapshot: only include interactive elements."
          },
          compact: {
            type: "boolean",
            description: "snapshot: remove empty structural elements."
          },
          depth: {
            type: "integer",
            description: "snapshot: max tree depth."
          },
          selector: {
            type: "string",
            description: "snapshot scope / act CSS selector."
          },
          kind: {
            type: "string",
            enum: %w[click dblclick type fill press hover drag select scroll wait evaluate click_at],
            description: "act: interaction kind."
          },
          ref: {
            type: "string",
            description: "act: element ref from snapshot (e.g. 'e1')."
          },
          text: { type: "string", description: "act type/fill: text to enter." },
          key:  { type: "string", description: "act press: key (e.g. 'Enter')." },
          direction: {
            type: "string",
            enum: %w[up down left right],
            description: "act scroll: direction."
          },
          amount:     { type: "integer", description: "act scroll: pixels." },
          ms:         { type: "integer", description: "act wait: milliseconds." },
          load_state: {
            type: "string",
            enum: %w[load domcontentloaded networkidle],
            description: "act wait: page load state."
          },
          js:         { type: "string", description: "act evaluate: JS expression." },
          target_ref: { type: "string", description: "act drag: destination ref." },
          values: {
            type: "array",
            items: { type: "string" },
            description: "act select: option values."
          },
          double_click: { type: "boolean", description: "act click: double-click." },
          x: { type: "number", description: "act click_at: x coordinate in pixels." },
          y: { type: "number", description: "act click_at: y coordinate in pixels." },
          url:       { type: "string",  description: "open/navigate: URL." },
          target_id: { type: "string",  description: "tab targetId from open/tabs." },
          format: {
            type: "string",
            enum: %w[png jpeg],
            description: "screenshot: format (default jpeg)."
          },
          quality:   { type: "integer", description: "screenshot: JPEG quality 0-100." },
          full_page: { type: "boolean", description: "screenshot: full scrollable page." }
        },
        required: ["action"]
      }

      # Chrome MCP npm package
      CHROME_MCP_PACKAGE = "chrome-devtools-mcp@latest"
      CHROME_MCP_BASE_ARGS = %w[
        -y
        chrome-devtools-mcp@latest
        --autoConnect
        --experimentalStructuredContent
        --experimental-page-id-routing
        --experimentalVision
      ].freeze

      # Minimum Chrome major version for Chrome MCP support
      MIN_CHROME_MAJOR = 146

      # MCP handshake/call timeout (seconds)
      MCP_HANDSHAKE_TIMEOUT = 12
      MCP_CALL_TIMEOUT      = 30

      # Minimum Node.js major version required by chrome-devtools-mcp
      MIN_NODE_MAJOR = 20

      MAX_SNAPSHOT_CHARS   = 4000
      MAX_LLM_OUTPUT_CHARS = 6000

      # ---------------------------------------------------------------------------
      # Class-level persistent MCP daemon state
      # ---------------------------------------------------------------------------
      # @@mcp_process holds the running daemon's IO handles and PID:
      #   { stdin: IO, stdout: IO, pid: Integer, wait_thr: Thread }
      # @@mcp_mutex guards all access to avoid race conditions in multi-thread envs.
      # @@mcp_call_id is an ever-increasing JSON-RPC id counter.
      @@mcp_process = nil
      @@mcp_mutex   = Mutex.new
      @@mcp_call_id = 2  # 1 is reserved for the initialize handshake

      def execute(action:, profile: nil, working_dir: nil, **opts)
        execute_user_browser(action, opts)
      rescue StandardError => e
        if chrome_not_running_error?(e.message)
          { error: CHROME_SETUP_GUIDE }
        else
          { error: "Browser error: #{e.message}" }
        end
      end

      def format_call(args)
        action  = args[:action]  || args["action"]  || "browser"
        profile = args[:profile] || args["profile"]
        suffix  = profile ? "(#{action}, profile=#{profile})" : "(#{action})"
        "browser#{suffix}"
      end

      def format_result(result)
        return "[Error] #{result[:error].to_s[0..80]}" if result[:error]
        return "[OK] #{result[:output].to_s.lines.size} lines" if result[:output]
        "[OK] Done"
      end

      def format_result_for_llm(result)
        return result if result[:error]

        action = result[:action].to_s
        output = result[:output].to_s

        output = compress_snapshot(output) if action == "snapshot"
        max_chars = action == "snapshot" ? MAX_SNAPSHOT_CHARS : MAX_LLM_OUTPUT_CHARS

        truncated = truncate_output(output, max_chars)

        {
          action:  action,
          success: result[:success],
          stdout:  truncated,
          profile: result[:profile]
        }.compact
      end

      private

      # -----------------------------------------------------------------------
      # User browser (Chrome MCP / existing-session driver)
      # -----------------------------------------------------------------------

      # Friendly setup guide returned when Chrome is not installed or not running.
      # Shown to the user (and Agent) when Chrome remote debugging is not enabled.
      # The strong wording ("STOP", "DO NOT") is intentional — it prevents the
      # Agent from silently falling back to web_search or other workarounds.
      CHROME_SETUP_GUIDE = <<~GUIDE.freeze
        ⚠️  IMPORTANT — STOP and read this before doing anything else.

        Chrome remote debugging is not enabled. You MUST ask the user to enable it
        before retrying. Do NOT fall back to web_search or any other workaround.

        Please tell the user:

        ──────────────────────────────────────────────────
        Chrome 还没有开启远程调试，需要你做一个操作：

        1. 打开 Chrome，在地址栏输入：
              chrome://inspect/#remote-debugging
           按回车

        2. 勾选 "Discover network targets"（如果没有勾选的话）

        3. 下次 Clacky 控制浏览器时，Chrome 会弹出一个授权对话框，
           点击「允许」即可。

        完成后告诉我，我来重试。
        ──────────────────────────────────────────────────

        After the user confirms, retry the original browser action.
      GUIDE

      # Returns true if Google Chrome appears to be installed on this machine.
      private def chrome_installed?
        case RbConfig::CONFIG["host_os"]
        when /darwin/
          File.exist?("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") ||
            File.exist?(File.expand_path("~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
        when /mswin|mingw|windows/i
          local = ENV.fetch("LOCALAPPDATA", "")
          prog  = ENV.fetch("ProgramFiles", "C:\Program Files")
          prog86 = ENV.fetch("ProgramFiles(x86)", "C:\Program Files (x86)")
          File.exist?(File.join(local, "Google", "Chrome", "Application", "chrome.exe")) ||
            File.exist?(File.join(prog, "Google", "Chrome", "Application", "chrome.exe")) ||
            File.exist?(File.join(prog86, "Google", "Chrome", "Application", "chrome.exe"))
        else # linux
          system("which google-chrome > /dev/null 2>&1") ||
            system("which google-chrome-stable > /dev/null 2>&1") ||
            File.exist?("/usr/bin/google-chrome") ||
            File.exist?("/usr/bin/google-chrome-stable")
        end
      end

      # Returns true if the error message from chrome-devtools-mcp indicates
      # that Chrome is not running or remote debugging is not enabled.
      private def chrome_not_running_error?(message)
        msg = message.to_s.downcase
        msg.include?("could not connect to chrome") ||
          msg.include?("devtoolsactiveport") ||
          msg.include?("remote debugging") ||
          msg.include?("chrome is running")
      end

      private def execute_user_browser(action, opts)
        unless chrome_mcp_available?
          return {
            error: "chrome-devtools-mcp requires Node.js and npx. " \
                   "Install Node.js 18+ and ensure 'npx' is in PATH."
          }
        end

        unless chrome_installed?
          return {
            error: <<~MSG
              ⚠️  IMPORTANT — STOP and tell the user:

              ──────────────────────────────────────────────────
              浏览器自动化需要安装 Google Chrome。

              请先安装 Chrome：https://www.google.com/chrome/
              安装完成后告诉我，我来重试。
              ──────────────────────────────────────────────────

              Do NOT fall back to web_search or any other workaround.
            MSG
          }
        end

        case action.to_s
        when "tabs"
          result = mcp_call("list_pages")
          pages  = extract_pages(result)
          { action: "tabs", success: true, profile: "user", output: format_tabs(pages), tabs: pages }
        when "snapshot"
          do_user_snapshot(opts)
        when "open"
          url = require_url(opts)
          return url if url.is_a?(Hash)
          result = mcp_call("new_page", { url: url })
          pages  = extract_pages(result)
          page   = pages.last || {}
          { action: "open", success: true, profile: "user",
            targetId: page[:id]&.to_s, url: url, output: "Opened: #{url}" }
        when "navigate"
          url       = require_url(opts)
          return url if url.is_a?(Hash)
          target_id = resolve_target_id(opts)
          return target_id if target_id.is_a?(Hash)
          mcp_call("navigate_page", { pageId: target_id.to_i, type: "url", url: url })
          { action: "navigate", success: true, profile: "user",
            targetId: target_id.to_s, url: url, output: "Navigated to: #{url}" }
        when "focus"
          target_id = resolve_target_id(opts)
          return target_id if target_id.is_a?(Hash)
          mcp_call("select_page", { pageId: target_id.to_i, bringToFront: true })
          { action: "focus", success: true, profile: "user", output: "Focused tab #{target_id}" }
        when "close"
          target_id = resolve_target_id(opts)
          return target_id if target_id.is_a?(Hash)
          mcp_call("close_page", { pageId: target_id.to_i })
          { action: "close", success: true, profile: "user", output: "Closed tab #{target_id}" }
        when "act"
          do_user_act(opts)
        when "screenshot"
          do_user_screenshot(opts)
        when "status"
          result = mcp_call("list_pages")
          pages  = extract_pages(result)
          { action: "status", success: true, profile: "user",
            output: "Browser running. #{pages.size} tab(s) open.", tabs: pages }
        else
          { error: "Action '#{action}' is not supported for profile=user." }
        end
      end

      private def do_user_snapshot(opts)
        target_id = resolve_target_id(opts)
        return target_id if target_id.is_a?(Hash)

        raw = mcp_call("take_snapshot", { pageId: target_id.to_i })
        snapshot_node = extract_snapshot(raw)

        interactive = opts[:interactive] || opts["interactive"]
        compact_opt = opts[:compact]     || opts["compact"]
        max_depth   = opts[:depth]       || opts["depth"]

        text = build_ai_snapshot(snapshot_node,
                                 interactive: interactive,
                                 compact: compact_opt,
                                 max_depth: max_depth)

        { action: "snapshot", success: true, profile: "user",
          targetId: target_id.to_s, output: text }
      end

      private def do_user_act(opts)
        kind      = (opts[:kind] || opts["kind"] || "click").to_s
        target_id = resolve_target_id(opts)
        return target_id if target_id.is_a?(Hash)

        page_id = target_id.to_i
        ref     = opts[:ref] || opts["ref"]

        case kind
        when "click", "dblclick"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          args = { pageId: page_id, uid: uid }
          args[:dblClick] = true if kind == "dblclick" || opts[:double_click] || opts["double_click"]
          mcp_call("click", args)
        when "fill"
          uid   = require_ref(ref)
          return uid if uid.is_a?(Hash)
          value = opts[:text] || opts["text"] || ""
          mcp_call("fill", { pageId: page_id, uid: uid, value: value })
        when "type"
          uid   = require_ref(ref)
          return uid if uid.is_a?(Hash)
          value = opts[:text] || opts["text"] || ""
          mcp_call("fill", { pageId: page_id, uid: uid, value: value })
        when "press"
          key = opts[:key] || opts["key"] || "Enter"
          mcp_call("press_key", { pageId: page_id, key: key })
        when "hover"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          mcp_call("hover", { pageId: page_id, uid: uid })
        when "drag"
          uid        = require_ref(ref)
          return uid if uid.is_a?(Hash)
          target_uid = opts[:target_ref] || opts["target_ref"] || ""
          mcp_call("drag", { pageId: page_id, from_uid: uid, to_uid: target_uid })
        when "select"
          uid    = require_ref(ref)
          return uid if uid.is_a?(Hash)
          values = Array(opts[:values] || opts["values"] || [])
          mcp_call("fill", { pageId: page_id, uid: uid, value: values.first.to_s })
        when "scroll"
          direction = opts[:direction] || opts["direction"] || "down"
          amount    = opts[:amount]    || opts["amount"]    || 300
          js = "window.scrollBy(#{direction == 'right' || direction == 'left' ?
                                   (direction == 'left' ? -amount.to_i : amount.to_i) : 0
                                 }, #{direction == 'up' ? -amount.to_i :
                                      direction == 'down' ? amount.to_i : 0})"
          mcp_call("evaluate_script", { pageId: page_id, function: "() => { #{js} }" })
        when "wait"
          ms         = opts[:ms]         || opts["ms"]
          load_state = opts[:load_state] || opts["load_state"]
          sel        = opts[:selector]   || opts["selector"]
          if ms
            sleep(ms.to_i / 1000.0)
            { action: "act", success: true, profile: "user", output: "Waited #{ms}ms" }
            return { action: "act", success: true, profile: "user", output: "Waited #{ms}ms" }
          elsif sel
            mcp_call("wait_for", { pageId: page_id, text: [sel] })
          else
            sleep(1)
          end
        when "evaluate"
          js     = opts[:js] || opts["js"] || ""
          result = mcp_call("evaluate_script", {
            pageId: page_id,
            function: "() => { return (#{js}) }"
          })
          value = extract_message(result)
          return { action: "act", success: true, profile: "user",
                   output: value.to_s }
        when "click_at"
          x = opts[:x] || opts["x"]
          y = opts[:y] || opts["y"]
          return { error: "click_at requires x and y coordinates" } unless x && y

          click_args = { pageId: page_id, x: x.to_f, y: y.to_f }
          click_args[:dblClick] = true if opts[:double_click] || opts["double_click"]
          result = mcp_call("click_at", click_args)
          return { action: "act", success: true, profile: "user",
                   output: extract_message(result).to_s }
        else
          return { error: "Unknown act kind: #{kind}" }
        end

        { action: "act", success: true, profile: "user", output: "#{kind} completed." }
      end

      private def do_user_screenshot(opts)
        target_id = resolve_target_id(opts)
        return target_id if target_id.is_a?(Hash)

        format    = opts[:format]    || opts["format"]    || "jpeg"
        full_page = opts[:full_page] || opts["full_page"] || false

        tmp_file = File.join(Dir.tmpdir, "clacky_screenshot_#{Time.now.to_i}.#{format}")
        mcp_call("take_screenshot", {
          pageId:   target_id.to_i,
          filePath: tmp_file,
          format:   format,
          fullPage: full_page
        })

        { action: "screenshot", success: true, profile: "user",
          path: tmp_file, output: "Screenshot saved: #{tmp_file}" }
      end

      # -----------------------------------------------------------------------
      # Sandbox browser (agent-browser fallback — not Chrome MCP)
      # -----------------------------------------------------------------------

      # -----------------------------------------------------------------------
      # Chrome MCP — process management & JSON-RPC over stdio
      # -----------------------------------------------------------------------

      # Returns the path to a Node.js binary that meets MIN_NODE_MAJOR.
      # Searches nvm-managed versions first (newest first), then falls back
      # to the system `node`.  Returns nil if no suitable node is found.
      private def find_node_binary
        # Check nvm-managed versions (newest LTS first)
        nvm_base = File.expand_path("~/.nvm/versions/node")
        if Dir.exist?(nvm_base)
          candidates = Dir.glob(File.join(nvm_base, "v*/bin/node")).sort.reverse
          candidates.each do |path|
            version_str = path.split("/").reverse[2] # e.g. "v22.22.0"
            major = version_str.gsub(/^v/, "").split(".").first.to_i
            return path if major >= MIN_NODE_MAJOR
          end
        end

        # Fall back to system node
        sys_node = `which node 2>/dev/null`.strip
        return nil if sys_node.empty? || !File.executable?(sys_node)

        version_line = `#{sys_node} --version 2>/dev/null`.strip # "v22.1.0"
        major = version_line.gsub(/^v/, "").split(".").first.to_i
        major >= MIN_NODE_MAJOR ? sys_node : nil
      end

      # Returns true if a suitable Node.js + npx are available for Chrome MCP.
      private def chrome_mcp_available?
        !!find_node_binary
      end

      # Build the [env, npx_path, *args] command array for chrome-devtools-mcp.
      # If user_data_dir is provided, appends --userDataDir.
      private def build_mcp_command(user_data_dir: nil)
        node_bin  = find_node_binary
        node_dir  = File.dirname(node_bin)
        npx_path  = File.join(node_dir, "npx")
        npx_path  = "npx" unless File.executable?(npx_path)

        # Prepend the node bin dir so npx resolves the correct node executable
        env = {
          "PATH"  => "#{node_dir}:#{ENV.fetch('PATH', '')}",
          "NODE"  => node_bin
        }

        args = CHROME_MCP_BASE_ARGS.dup
        if user_data_dir && !user_data_dir.to_s.empty?
          args += ["--userDataDir", user_data_dir.to_s]
        end

        [env, npx_path, *args]
      end

      # Calls a Chrome MCP tool over the persistent daemon process.
      #
      # On the first call (or after the daemon dies), `ensure_mcp_process!` starts
      # a new npx process and completes the MCP initialize handshake.  Subsequent
      # calls reuse the same process — Chrome's "Allow remote debugging" dialog is
      # shown exactly once per daemon lifetime.
      #
      # Protocol sequence (per MCP spec):
      #   Handshake (once on daemon start):
      #     1. client → initialize
      #     2. server → initialize result
      #     3. client → notifications/initialized
      #   Per call (reusing the same process):
      #     4. client → tools/call  (with unique id)
      #     5. server → tools/call result
      #
      # Thread safety: all state mutations are protected by @@mcp_mutex.
      private def mcp_call(tool_name, arguments = {}, user_data_dir: nil)
        call_resp = nil

        @@mcp_mutex.synchronize do
          # Ensure the daemon is alive (start + handshake if needed)
          ensure_mcp_process!(user_data_dir: user_data_dir)

          proc_state = @@mcp_process
          call_id    = @@mcp_call_id
          @@mcp_call_id += 1

          call_msg = mcp_json_rpc("tools/call", {
            name:      tool_name,
            arguments: arguments
          }, id: call_id)

          proc_state[:stdin].write(call_msg + "\n")
          proc_state[:stdin].flush

          call_resp = mcp_read_response(proc_state[:stdout], target_id: call_id,
                                        timeout: MCP_CALL_TIMEOUT)

          unless call_resp
            # Daemon may have died — clean up so next call restarts it
            kill_mcp_process!
            raise "Chrome MCP tools/call '#{tool_name}' timed out after #{MCP_CALL_TIMEOUT}s"
          end

          # Propagate JSON-RPC protocol errors as Ruby exceptions
          if call_resp["error"]
            err = call_resp["error"]
            raise "Chrome MCP error: #{err.is_a?(Hash) ? err['message'] : err}"
          end

          result = call_resp["result"] || {}

          # Propagate tool-level errors (isError: true means the MCP tool itself failed,
          # e.g. Chrome not running, page not found, etc.)
          if result["isError"]
            text = extract_text_content(result)
            raise text.empty? ? "Chrome MCP tool '#{tool_name}' failed" : text
          end

          result
        end
      end

      # ---------------------------------------------------------------------------
      # Daemon process management (called from within @@mcp_mutex)
      # ---------------------------------------------------------------------------

      # Ensures the persistent MCP daemon process is running and the MCP handshake
      # has been completed.  If the process is dead or was never started, a new one
      # is spawned and the initialize/initialized sequence is executed.
      #
      # Must be called while holding @@mcp_mutex.
      private def ensure_mcp_process!(user_data_dir: nil)
        return if mcp_process_alive?

        cmd = build_mcp_command(user_data_dir: user_data_dir)

        stdin, stdout, stderr_io, wait_thr = Open3.popen3(*cmd)
        # Discard stderr asynchronously to avoid pipe buffer deadlocks
        Thread.new { stderr_io.read rescue nil }

        # MCP handshake: initialize → result → notifications/initialized
        init_msg = mcp_json_rpc("initialize", {
          protocolVersion: "2024-11-05",
          capabilities:    {},
          clientInfo:      { name: "clacky", version: "1.0" }
        }, id: 1)

        notify_msg = JSON.generate({
          jsonrpc: "2.0",
          method:  "notifications/initialized",
          params:  {}
        })

        stdin.write(init_msg + "\n")
        stdin.flush

        init_resp = mcp_read_response(stdout, target_id: 1, timeout: MCP_HANDSHAKE_TIMEOUT)
        unless init_resp
          Process.kill("TERM", wait_thr.pid) rescue nil
          raise "Chrome MCP initialize handshake timed out"
        end

        stdin.write(notify_msg + "\n")
        stdin.flush

        # Handshake complete — store daemon state at class level
        @@mcp_process = { stdin: stdin, stdout: stdout, pid: wait_thr.pid, wait_thr: wait_thr }
        # Reset call id counter (id=1 already used for initialize)
        @@mcp_call_id = 2
      end

      # Returns true if the daemon process is running and its stdin/stdout are open.
      # Must be called while holding @@mcp_mutex.
      private def mcp_process_alive?
        return false if @@mcp_process.nil?

        ps = @@mcp_process
        # Check whether the process is still alive via kill(0)
        Process.kill(0, ps[:pid])
        !ps[:stdin].closed? && !ps[:stdout].closed?
      rescue Errno::ESRCH, Errno::EPERM
        # Process gone — clean up stale state
        kill_mcp_process!
        false
      end

      # Forcibly terminates the daemon process and clears class-level state.
      # Safe to call even when @@mcp_process is nil.
      # Must be called while holding @@mcp_mutex (or during teardown).
      private def kill_mcp_process!
        ps = @@mcp_process
        return unless ps

        Process.kill("TERM", ps[:pid]) rescue nil
        ps[:stdin].close  rescue nil
        ps[:stdout].close rescue nil
        @@mcp_process = nil
      end

      # Public class-level method to shut down the daemon (e.g. at exit or in tests).
      def self.stop_mcp_process!
        @@mcp_mutex.synchronize do
          ps = @@mcp_process
          return unless ps

          Process.kill("TERM", ps[:pid]) rescue nil
          ps[:stdin].close  rescue nil
          ps[:stdout].close rescue nil
          @@mcp_process = nil
        end
      end

      # Build a JSON-RPC 2.0 request message string (with id)
      private def mcp_json_rpc(method, params, id:)
        JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params })
      end

      # Read newline-delimited JSON from stdout until a message with the given
      # id is found, or timeout expires.  Returns the parsed Hash or nil.
      private def mcp_read_response(io, target_id:, timeout: 10)
        Timeout.timeout(timeout) do
          loop do
            line = io.gets
            break if line.nil?
            line = line.strip
            next if line.empty?
            begin
              msg = JSON.parse(line)
              return msg if msg.is_a?(Hash) && msg["id"] == target_id
            rescue JSON::ParserError
              next
            end
          end
          nil
        end
      rescue Timeout::Error
        nil
      end

      # -----------------------------------------------------------------------
      # MCP response extractors
      # -----------------------------------------------------------------------

      private def extract_pages(result)
        return [] unless result.is_a?(Hash)

        # Try structuredContent.pages first
        structured = result["structuredContent"]
        if structured.is_a?(Hash) && structured["pages"].is_a?(Array)
          return structured["pages"].map do |p|
            { id: p["id"], url: p["url"], selected: p["selected"] == true }
          end
        end

        # Fall back to text content parsing
        text = extract_text_content(result)
        parse_pages_from_text(text)
      end

      private def extract_snapshot(result)
        return {} unless result.is_a?(Hash)

        structured = result["structuredContent"]
        if structured.is_a?(Hash) && structured["snapshot"].is_a?(Hash)
          return structured["snapshot"]
        end

        # Try content array
        text = extract_text_content(result)
        begin
          JSON.parse(text)
        rescue StandardError
          {}
        end
      end

      private def extract_message(result)
        return "" unless result.is_a?(Hash)

        structured = result["structuredContent"]
        if structured.is_a?(Hash)
          return structured["message"].to_s if structured["message"]
        end

        extract_text_content(result)
      end

      private def extract_text_content(result)
        return "" unless result.is_a?(Hash)

        content = result["content"]
        return "" unless content.is_a?(Array)

        content.filter_map do |entry|
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
      # Snapshot rendering (ChromeMcpSnapshotNode → AI text format)
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
        visit_node(node, 0, lines, refs,
                   interactive: interactive,
                   compact: compact,
                   max_depth: max_depth)
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

        # Decide whether to render this node (but always recurse into children)
        render = true
        render = false if interactive && !INTERACTIVE_ROLES.include?(role)
        render = false if compact && STRUCTURAL_ROLES.include?(role) && name.empty?

        if render
          line = "#{" " * (depth * 2)}- #{role}"
          line += " \"#{escape_quoted(name)}\"" unless name.empty?

          # Assign ref if interactive or named content role
          if uid && !uid.empty? && (INTERACTIVE_ROLES.include?(role) ||
                                     (CONTENT_ROLES.include?(role) && !name.empty?))
            refs[uid] = { role: role, name: name }
            line += " [ref=#{uid}]"
          end

          line += " value=\"#{escape_quoted(val.to_s)}\"" unless val.nil? || val.to_s.empty?
          line += " description=\"#{escape_quoted(desc)}\"" unless desc.empty?

          lines << line
        end

        # Always recurse into children regardless of whether this node was rendered
        child_depth = render ? depth + 1 : depth
        Array(node["children"]).each do |child|
          visit_node(child, child_depth, lines, refs,
                     interactive: interactive,
                     compact: compact,
                     max_depth: max_depth)
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

      private def resolve_target_id(opts)
        tid = opts[:target_id] || opts["target_id"]
        if tid && !tid.to_s.empty?
          return tid.to_s
        end
        # Auto-select the first available page
        result = mcp_call("list_pages")
        pages  = extract_pages(result)
        page   = pages.find { |p| p[:selected] } || pages.first
        return { error: "No open tabs found. Use action=open first." } unless page
        page[:id].to_s
      end

      # -----------------------------------------------------------------------
      # Output helpers
      # -----------------------------------------------------------------------

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
        if removed > 0
          filtered << "\n[snapshot compressed: #{removed} lines removed]\n"
        end
        filtered.join
      end

      private def truncate_output(output, max_chars)
        return output if output.length <= max_chars

        lines     = output.lines
        available = max_chars - 150
        first_part = []
        acc = 0
        lines.each do |line|
          break if acc + line.length > available
          first_part << line
          acc += line.length
        end
        notice = "\n... [truncated: #{first_part.size}/#{lines.size} lines shown] ..."
        first_part.join + notice
      end
    end
  end
end
