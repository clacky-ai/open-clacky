# frozen_string_literal: true

require "webrick"
require "websocket"
require "json"
require "thread"
require "fileutils"
require "tmpdir"
require "uri"
require "securerandom"
require "timeout"
require "yaml"
require "date"
require_relative "session_registry"
require_relative "web_ui_controller"
require_relative "scheduler"
require_relative "../brand_config"
require_relative "channel"
require_relative "../banner"
require_relative "../utils/file_processor"

module Clacky
  module Server
    # Lightweight UI collector used by api_session_messages to capture events
    # emitted by Agent#replay_history without broadcasting over WebSocket.
    # Implements the same show_* interface as WebUIController.
    class HistoryCollector
      def initialize(session_id, events)
        @session_id = session_id
        @events     = events
      end

      def show_user_message(content, created_at: nil, files: [])
        ev = { type: "history_user_message", session_id: @session_id, content: content }
        ev[:created_at] = created_at if created_at
        rendered = Array(files).filter_map do |f|
          url  = f[:data_url] || f["data_url"]
          name = f[:name]     || f["name"]
          path = f[:path]     || f["path"]

          if url
            url
          elsif path && File.exist?(path.to_s)
            # Reconstruct data_url from the tmp file (still present on disk)
            Utils::FileProcessor.image_path_to_data_url(path) rescue "expired:#{name}"
          elsif name
            # File badge for non-image disk files, or image whose tmp file is gone
            type = f[:type] || f["type"] || ""
            type.to_s == "image" ? "expired:#{name}" : "pdf:#{name}"
          end
        end
        ev[:images] = rendered unless rendered.empty?
        @events << ev
      end

      def show_assistant_message(content, files:)
        return if content.nil? || content.to_s.strip.empty?

        @events << { type: "assistant_message", session_id: @session_id, content: content }
      end

      def show_tool_call(name, args)
        args_data = args.is_a?(String) ? (JSON.parse(args) rescue args) : args
        summary   = tool_call_summary(name, args_data)
        @events << { type: "tool_call", session_id: @session_id, name: name, args: args_data, summary: summary }
      end

      private def tool_call_summary(name, args)
        class_name = name.to_s.split("_").map(&:capitalize).join
        return nil unless Clacky::Tools.const_defined?(class_name)

        tool = Clacky::Tools.const_get(class_name).new
        args_sym = args.is_a?(Hash) ? args.transform_keys(&:to_sym) : {}
        tool.format_call(args_sym)
      rescue StandardError
        nil
      end

      def show_tool_result(result)
        @events << { type: "tool_result", session_id: @session_id, result: result }
      end

      def show_token_usage(token_data)
        return unless token_data.is_a?(Hash)

        @events << { type: "token_usage", session_id: @session_id }.merge(token_data)
      end

      # Ignore all other UI methods (progress, errors, etc.) during history replay
      def method_missing(name, *args, **kwargs); end
      def respond_to_missing?(name, include_private = false); true; end
    end

    # HttpServer runs an embedded WEBrick HTTP server with WebSocket support.
    #
    # Routes:
    #   GET  /ws                     → WebSocket upgrade (all real-time communication)
    #   *    /api/*                  → JSON REST API (sessions, tasks, schedules)
    #   GET  /**                     → static files served from lib/clacky/web/ directory
    class HttpServer
      WEB_ROOT = File.expand_path("../web", __dir__)

      # Default SOUL.md written when the user skips the onboard conversation.
      # A richer version is created by the Agent during the soul_setup phase.
      DEFAULT_SOUL_MD = <<~MD.freeze
        # Clacky — Agent Soul

        You are Clacky, a friendly and capable AI coding assistant and technical
        co-founder. You are sharp, concise, and proactive. You speak plainly and
        avoid unnecessary formality. You love helping people ship great software.

        ## Personality
        - Warm and encouraging, but direct and honest
        - Think step-by-step before acting; explain your reasoning briefly
        - Prefer doing over talking — use tools, write code, ship results
        - Adapt your language and tone to match the user's style

        ## Strengths
        - Full-stack software development (Ruby, Python, JS, and more)
        - Architectural thinking and code review
        - Debugging tricky problems with patience and creativity
        - Breaking big goals into small, executable steps
      MD

      # Default SOUL.md for Chinese-language users.
      DEFAULT_SOUL_MD_ZH = <<~MD.freeze
        # Clacky — 助手灵魂

        你是 Clacky，一位友好、能干的 AI 编程助手和技术联合创始人。
        你思维敏锐、言简意赅、主动积极。你说话直接，不喜欢过度客套。
        你热爱帮助用户打造优秀的软件产品。

        **重要：始终用中文回复用户。**

        ## 性格特点
        - 热情鼓励，但直接诚实
        - 行动前先思考；简要说明你的推理过程
        - 重行动而非空谈 —— 善用工具，写代码，交付结果
        - 根据用户的风格调整语气和表达方式

        ## 核心能力
        - 全栈软件开发（Ruby、Python、JS 等）
        - 架构设计与代码审查
        - 耐心细致地调试复杂问题
        - 将大目标拆解为可执行的小步骤
      MD

      def initialize(host: "127.0.0.1", port: 7070, agent_config:, client_factory:, brand_test: false, sessions_dir: nil, socket: nil, master_pid: nil)
        @host           = host
        @port           = port
        @agent_config   = agent_config
        @client_factory = client_factory  # callable: -> { Clacky::Client.new(...) }
        @brand_test     = brand_test      # when true, skip remote API calls for license activation
        @inherited_socket = socket        # TCPServer socket passed from Master (nil = standalone mode)
        @master_pid       = master_pid    # Master PID so we can send USR1 on upgrade/restart
        # Capture the absolute path of the entry script and original ARGV at startup,
        # so api_restart can re-exec the correct binary even if cwd changes later.
        @restart_script = File.expand_path($0)
        @restart_argv   = ARGV.dup
        @session_manager = Clacky::SessionManager.new(sessions_dir: sessions_dir)
        @registry        = SessionRegistry.new(
          session_manager:  @session_manager,
          session_restorer: method(:build_session_from_data)
        )
        @ws_clients      = {}   # session_id => [WebSocketConnection, ...]
        @all_ws_conns    = []   # every connected WS client, regardless of session subscription
        @ws_mutex        = Mutex.new
        # Version cache: { latest: "x.y.z", checked_at: Time }
        @version_cache   = nil
        @version_mutex   = Mutex.new
        @scheduler       = Scheduler.new(
          session_registry: @registry,
          session_builder:  method(:build_session),
          task_runner:      method(:run_agent_task)
        )
        @channel_manager = Clacky::Channel::ChannelManager.new(
          session_registry:  @registry,
          session_builder:   method(:build_session),
          run_agent_task:    method(:run_agent_task),
          interrupt_session: method(:interrupt_session),
          channel_config:    Clacky::ChannelConfig.load
        )
        @browser_manager = Clacky::BrowserManager.instance
        @skill_loader    = Clacky::SkillLoader.new(working_dir: nil, brand_config: Clacky::BrandConfig.load)
        # Access key authentication:
        # - localhost (127.0.0.1 / ::1) is always trusted; auth is skipped entirely.
        # - Any other bind address requires CLACKY_ACCESS_KEY env var.
        @localhost_only      = local_host?(@host)
        @access_key          = @localhost_only ? nil : resolve_access_key
        @auth_failures       = {}
        @auth_failures_mutex = Mutex.new
        if @localhost_only
          Clacky::Logger.info("[HttpServer] Localhost mode — authentication disabled")
        else
          Clacky::Logger.info("[HttpServer] Public mode — access key authentication ENABLED")
        end
      end

      def start
        # Enable console logging for the server process so log lines are visible in the terminal.
        Clacky::Logger.console = true

        Clacky::Logger.info("[HttpServer PID=#{Process.pid}] start() mode=#{@inherited_socket ? 'worker' : 'standalone'} inherited_socket=#{@inherited_socket.inspect} master_pid=#{@master_pid.inspect}")

        # In standalone mode (no master), kill any stale server and manage our own PID file.
        # In worker mode the master owns the PID file; we just skip this block.
        if @inherited_socket.nil?
          kill_existing_server(@port)
          pid_file = File.join(Dir.tmpdir, "clacky-server-#{@port}.pid")
          File.write(pid_file, Process.pid.to_s)
          at_exit { File.delete(pid_file) if File.exist?(pid_file) }
        end

        # Expose server address and brand name to all child processes (skill scripts, shell commands, etc.)
        # so they can call back into the server without hardcoding the port,
        # and use the correct product name without re-reading brand.yml.
        ENV["CLACKY_SERVER_PORT"]  = @port.to_s
        ENV["CLACKY_SERVER_HOST"]  = (@host == "0.0.0.0" ? "127.0.0.1" : @host)
        product_name = Clacky::BrandConfig.load.product_name
        ENV["CLACKY_PRODUCT_NAME"] = (product_name.nil? || product_name.strip.empty?) ? "OpenClacky" : product_name

        # Override WEBrick's built-in signal traps via StartCallback,
        # which fires after WEBrick sets its own INT/TERM handlers.
        # This ensures Ctrl-C always exits immediately.
        #
        # When running as a worker under Master, DoNotListen: true prevents WEBrick
        # from calling bind() on its own — we inject the inherited socket instead.
        webrick_opts = {
          BindAddress:   @host,
          Port:          @port,
          Logger:        WEBrick::Log.new(File::NULL),
          AccessLog:     [],
          StartCallback: proc { }  # signal traps set below, after `server` is created
        }
        webrick_opts[:DoNotListen] = true if @inherited_socket
        Clacky::Logger.info("[HttpServer PID=#{Process.pid}] WEBrick DoNotListen=#{webrick_opts[:DoNotListen].inspect}")

        server = WEBrick::HTTPServer.new(**webrick_opts)

        # Override WEBrick's signal traps now that `server` is available.
        # On INT/TERM: call server.shutdown (graceful), with a 1s hard-kill fallback.
        # Also stop BrowserManager so the chrome-devtools-mcp node process is killed
        # before this worker exits — otherwise it becomes an orphan and holds port 7070.
        shutdown_once = false
        shutdown_proc = proc do
          next if shutdown_once
          shutdown_once = true
          Thread.new do
            sleep 2
            Clacky::Logger.warn("[HttpServer] Forced exit after graceful shutdown timeout.")
            exit!(0)
          end
          # Stop channel and browser managers in parallel to minimize shutdown time.
          t1 = Thread.new { @channel_manager.stop rescue nil }
          t2 = Thread.new { Clacky::BrowserManager.instance.stop rescue nil }
          t1.join(1.5)
          t2.join(1.5)
          server.shutdown rescue nil
        end
        trap("INT")  { shutdown_proc.call }
        trap("TERM") { shutdown_proc.call }

        if @inherited_socket
          server.listeners << @inherited_socket
          Clacky::Logger.info("[HttpServer PID=#{Process.pid}] injected inherited fd=#{@inherited_socket.fileno} listeners=#{server.listeners.map(&:fileno).inspect}")
        else
          Clacky::Logger.info("[HttpServer PID=#{Process.pid}] standalone, WEBrick listeners=#{server.listeners.map(&:fileno).inspect}")
        end

        # Mount API + WebSocket handler (takes priority).
        # Use a custom Servlet so that DELETE/PUT/PATCH requests are not rejected
        # by WEBrick's default method whitelist before reaching our dispatcher.
        dispatcher = self
        servlet_class = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
          define_method(:do_GET)     { |req, res| dispatcher.send(:dispatch, req, res) }
          define_method(:do_POST)    { |req, res| dispatcher.send(:dispatch, req, res) }
          define_method(:do_PUT)     { |req, res| dispatcher.send(:dispatch, req, res) }
          define_method(:do_DELETE)  { |req, res| dispatcher.send(:dispatch, req, res) }
          define_method(:do_PATCH)   { |req, res| dispatcher.send(:dispatch, req, res) }
          define_method(:do_OPTIONS) { |req, res| dispatcher.send(:dispatch, req, res) }
        end
        server.mount("/api", servlet_class)
        server.mount("/ws",  servlet_class)

        # Mount static file handler for the entire web directory.
        # Use mount_proc so we can inject no-cache headers on every response,
        # preventing stale JS/CSS from being served after a gem update.
        #
        # Special case: GET / and GET /index.html are served with server-side
        # rendering — the {{BRAND_NAME}} placeholder is replaced before delivery
        # so the correct brand name appears on first paint with no JS flash.
        file_handler = WEBrick::HTTPServlet::FileHandler.new(server, WEB_ROOT,
                                                             FancyIndexing: false)
        index_html_path = File.join(WEB_ROOT, "index.html")

        server.mount_proc("/") do |req, res|
          if req.path == "/" || req.path == "/index.html"
            product_name = Clacky::BrandConfig.load.product_name || "OpenClacky"
            html = File.read(index_html_path).gsub("{{BRAND_NAME}}", product_name)
            res.status                = 200
            res["Content-Type"]       = "text/html; charset=utf-8"
            res["Cache-Control"]      = "no-store"
            res["Pragma"]             = "no-cache"
            res.body                  = html
          else
            file_handler.service(req, res)
            res["Cache-Control"] = "no-store"
            res["Pragma"]        = "no-cache"
          end
        end

        # Auto-create a default session on startup
        create_default_session

        # Start the background scheduler
        @scheduler.start
        puts "   Scheduler: #{@scheduler.schedules.size} task(s) loaded"

        # Start IM channel adapters (non-blocking — each platform runs in its own thread)
        @channel_manager.start

        # Start browser MCP daemon if browser.yml is configured (non-blocking)
        @browser_manager.start

        server.start
      end


      # ── Router ────────────────────────────────────────────────────────────────

      def dispatch(req, res)
        path   = req.path
        method = req.request_method

        # Access key guard (skip for WebSocket upgrades)
        return unless check_access_key(req, res)

        # WebSocket upgrade — no timeout applied (long-lived connection)
        if websocket_upgrade?(req)
          handle_websocket(req, res)
          return
        end

        # Wrap all REST handlers in a timeout so a hung handler (e.g. infinite
        # recursion in chunk parsing) returns a proper 503 instead of an empty 200.
        #
        # Brand/license endpoints call PlatformHttpClient which retries across two
        # hosts with OPEN_TIMEOUT=8s per attempt × 2 attempts = up to ~16s on the
        # primary alone, before failing over to the fallback domain.  Give them a
        # generous 90s so retry + failover can complete without being cut short.
        timeout_sec = if path.start_with?("/api/brand")
          90
        elsif path == "/api/tool/browser"
          30
        else
          10
        end
        Timeout.timeout(timeout_sec) do
          _dispatch_rest(req, res)
        end
      rescue Timeout::Error
        Clacky::Logger.warn("[HTTP 503] #{method} #{path} timed out after #{timeout_sec}s")
        json_response(res, 503, { error: "Request timed out" })
      rescue => e
        Clacky::Logger.warn("[HTTP 500] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        json_response(res, 500, { error: e.message })
      end

      def _dispatch_rest(req, res)
        path   = req.path
        method = req.request_method

        case [method, path]
        when ["GET",    "/api/sessions"]      then api_list_sessions(req, res)
        when ["POST",   "/api/sessions"]      then api_create_session(req, res)
        when ["GET",    "/api/cron-tasks"]    then api_list_cron_tasks(res)
        when ["POST",   "/api/cron-tasks"]    then api_create_cron_task(req, res)
        when ["GET",    "/api/skills"]         then api_list_skills(res)
        when ["GET",    "/api/config"]        then api_get_config(res)
        when ["POST",   "/api/config/models"] then api_add_model(req, res)
        when ["POST",   "/api/config/test"]   then api_test_config(req, res)
        when ["GET",    "/api/providers"]     then api_list_providers(res)
        when ["GET",    "/api/onboard/status"]    then api_onboard_status(res)
        when ["GET",    "/api/browser/status"]    then api_browser_status(res)
        when ["POST",   "/api/browser/configure"]  then api_browser_configure(req, res)
        when ["POST",   "/api/browser/reload"]    then api_browser_reload(res)
        when ["POST",   "/api/browser/toggle"]    then api_browser_toggle(res)
        when ["POST",   "/api/onboard/complete"]  then api_onboard_complete(req, res)
        when ["POST",   "/api/onboard/skip-soul"] then api_onboard_skip_soul(req, res)
        when ["GET",    "/api/store/skills"]          then api_store_skills(res)
        when ["GET",    "/api/brand/status"]      then api_brand_status(res)
        when ["POST",   "/api/brand/activate"]    then api_brand_activate(req, res)
        when ["DELETE", "/api/brand/license"]     then api_brand_deactivate(res)
        when ["GET",    "/api/brand/skills"]      then api_brand_skills(res)
        when ["GET",    "/api/brand"]             then api_brand_info(res)
        when ["GET",    "/api/creator/skills"]    then api_creator_skills(res)
        when ["GET",    "/api/trash"]     then api_trash(req, res)
        when ["POST",   "/api/trash/restore"] then api_trash_restore(req, res)
        when ["DELETE", "/api/trash"]     then api_trash_delete(req, res)
        when ["GET",    "/api/profile"]   then api_profile_get(res)
        when ["PUT",    "/api/profile"]   then api_profile_put(req, res)
        when ["GET",    "/api/memories"]  then api_memories_list(res)
        when ["POST",   "/api/memories"]  then api_memories_create(req, res)
        when ["GET",    "/api/channels"]          then api_list_channels(res)
        when ["POST",   "/api/tool/browser"]      then api_tool_browser(req, res)
        when ["POST",   "/api/upload"]            then api_upload_file(req, res)
        when ["POST",   "/api/open-file"]         then api_open_file(req, res)
        when ["GET",    "/api/version"]           then api_get_version(res)
        when ["POST",   "/api/version/upgrade"]   then api_upgrade_version(req, res)
        when ["POST",   "/api/restart"]           then api_restart(req, res)
        when ["PATCH",  "/api/sessions/:id/model"] then api_switch_session_model(req, res)
        when ["PATCH",  "/api/sessions/:id/working_dir"] then api_change_session_working_dir(req, res)
        else
          if method == "POST" && path.match?(%r{^/api/channels/[^/]+/test$})
            platform = path.sub("/api/channels/", "").sub("/test", "")
            api_test_channel(platform, req, res)
          elsif method == "POST" && path.start_with?("/api/channels/")
            platform = path.sub("/api/channels/", "")
            api_save_channel(platform, req, res)
          elsif method == "DELETE" && path.start_with?("/api/channels/")
            platform = path.sub("/api/channels/", "")
            api_delete_channel(platform, res)
          elsif method == "GET" && path.match?(%r{^/api/sessions/[^/]+/skills$})
            session_id = path.sub("/api/sessions/", "").sub("/skills", "")
            api_session_skills(session_id, res)
          elsif method == "GET" && path.match?(%r{^/api/sessions/[^/]+/export$})
            session_id = path.sub("/api/sessions/", "").sub("/export", "")
            api_export_session(session_id, res)
          elsif method == "GET" && path.match?(%r{^/api/sessions/[^/]+/messages$})
            session_id = path.sub("/api/sessions/", "").sub("/messages", "")
            api_session_messages(session_id, req, res)
          elsif method == "PATCH" && path.match?(%r{^/api/sessions/[^/]+$})
            session_id = path.sub("/api/sessions/", "")
            api_rename_session(session_id, req, res)
          elsif method == "PATCH" && path.match?(%r{^/api/sessions/[^/]+/model$})
            session_id = path.sub("/api/sessions/", "").sub("/model", "")
            api_switch_session_model(session_id, req, res)
          elsif method == "POST" && path.match?(%r{^/api/sessions/[^/]+/benchmark$})
            session_id = path.sub("/api/sessions/", "").sub("/benchmark", "")
            api_benchmark_session_models(session_id, req, res)
          elsif method == "PATCH" && path.match?(%r{^/api/sessions/[^/]+/working_dir$})
            session_id = path.sub("/api/sessions/", "").sub("/working_dir", "")
            api_change_session_working_dir(session_id, req, res)
          elsif method == "DELETE" && path.start_with?("/api/sessions/")
            session_id = path.sub("/api/sessions/", "")
            api_delete_session(session_id, res)
          elsif method == "POST" && path.match?(%r{^/api/config/models/[^/]+/default$})
            id = path.sub("/api/config/models/", "").sub("/default", "")
            api_set_default_model(id, res)
          elsif method == "PATCH" && path.match?(%r{^/api/config/models/[^/]+$})
            id = path.sub("/api/config/models/", "")
            api_update_model(id, req, res)
          elsif method == "DELETE" && path.match?(%r{^/api/config/models/[^/]+$})
            id = path.sub("/api/config/models/", "")
            api_delete_model(id, res)
          elsif method == "POST" && path.match?(%r{^/api/cron-tasks/[^/]+/run$})
            name = URI.decode_www_form_component(path.sub("/api/cron-tasks/", "").sub("/run", ""))
            api_run_cron_task(name, res)
          elsif method == "PATCH" && path.match?(%r{^/api/cron-tasks/[^/]+$})
            name = URI.decode_www_form_component(path.sub("/api/cron-tasks/", ""))
            api_update_cron_task(name, req, res)
          elsif method == "DELETE" && path.match?(%r{^/api/cron-tasks/[^/]+$})
            name = URI.decode_www_form_component(path.sub("/api/cron-tasks/", ""))
            api_delete_cron_task(name, res)
          elsif method == "PATCH" && path.match?(%r{^/api/skills/[^/]+/toggle$})
            name = URI.decode_www_form_component(path.sub("/api/skills/", "").sub("/toggle", ""))
            api_toggle_skill(name, req, res)
          elsif method == "POST" && path.match?(%r{^/api/brand/skills/[^/]+/install$})
            slug = URI.decode_www_form_component(path.sub("/api/brand/skills/", "").sub("/install", ""))
            api_brand_skill_install(slug, req, res)
          elsif method == "POST" && path.match?(%r{^/api/my-skills/[^/]+/publish$})
            name = URI.decode_www_form_component(path.sub("/api/my-skills/", "").sub("/publish", ""))
            api_publish_my_skill(name, req, res)
          elsif method == "GET" && path.match?(%r{^/api/memories/[^/]+$})
            filename = URI.decode_www_form_component(path.sub("/api/memories/", ""))
            api_memories_get(filename, res)
          elsif method == "PUT" && path.match?(%r{^/api/memories/[^/]+$})
            filename = URI.decode_www_form_component(path.sub("/api/memories/", ""))
            api_memories_update(filename, req, res)
          elsif method == "DELETE" && path.match?(%r{^/api/memories/[^/]+$})
            filename = URI.decode_www_form_component(path.sub("/api/memories/", ""))
            api_memories_delete(filename, res)
          else
            not_found(res)
          end
        end
      end

      # ── REST API ──────────────────────────────────────────────────────────────

      def api_list_sessions(req, res)
        query   = URI.decode_www_form(req.query_string.to_s).to_h
        limit   = [query["limit"].to_i.then { |n| n > 0 ? n : 20 }, 50].min
        before  = query["before"].to_s.strip.then  { |v| v.empty? ? nil : v }
        q       = query["q"].to_s.strip.then       { |v| v.empty? ? nil : v }
        date    = query["date"].to_s.strip.then    { |v| v.empty? ? nil : v }
        type    = query["type"].to_s.strip.then    { |v| v.empty? ? nil : v }
        # Backward-compat: ?source=<x> and ?profile=coding → type
        type ||= query["profile"].to_s.strip.then { |v| v.empty? ? nil : v }
        type ||= query["source"].to_s.strip.then  { |v| v.empty? ? nil : v }

        # Fetch one extra NON-PINNED row to detect has_more without a separate count query.
        # `registry.list` always returns ALL matching pinned rows first (on the
        # first page; `before` == nil), followed by non-pinned rows up to `limit+1`.
        # So has_more is determined by whether the non-pinned section overflowed.
        sessions = @registry.list(limit: limit + 1, before: before, q: q, date: date, type: type)

        # Split pinned vs non-pinned to apply has_more only to the non-pinned tail.
        pinned_part, non_pinned_part = sessions.partition { |s| s[:pinned] }
        has_more = non_pinned_part.size > limit
        non_pinned_part = non_pinned_part.first(limit)
        sessions = pinned_part + non_pinned_part

        json_response(res, 200, { sessions: sessions, has_more: has_more })
      end

      def api_create_session(req, res)
        body = parse_json_body(req)
        name = body["name"]
        return json_response(res, 400, { error: "name is required" }) if name.nil? || name.strip.empty?

        # Optional agent_profile; defaults to "general" if omitted or invalid
        profile = body["agent_profile"].to_s.strip
        profile = "general" if profile.empty?

        # Optional source; defaults to :manual. Accept "system" for skill-launched sessions
        # (e.g. /onboard, /browser-setup, /channel-setup).
        raw_source = body["source"].to_s.strip
        source = %w[manual cron channel setup].include?(raw_source) ? raw_source.to_sym : :manual

        raw_dir = body["working_dir"].to_s.strip
        working_dir = raw_dir.empty? ? default_working_dir : File.expand_path(raw_dir)

        # Optional model override — passed as a stable model id (matches the
        # id returned by GET /api/config). Name-based override was removed:
        # a bare model name can't disambiguate between entries from different
        # providers (e.g. "deepseek-v4-pro" on DeepSeek direct vs its dsk-*
        # alias on OpenClacky/Bedrock), and mutating current_model["model"]
        # kept the wrong api_key / base_url / api format, producing
        # "unknown model" errors at the provider.
        model_id_override = body["model_id"].to_s.strip
        model_id_override = nil if model_id_override.empty?

        if model_id_override && !@agent_config.models.any? { |m| m["id"] == model_id_override }
          return json_response(res, 400, { error: "Model not found in configuration" })
        end

        # Create working directory if it doesn't exist
        # Allow multiple sessions in the same directory
        FileUtils.mkdir_p(working_dir)

        session_id = build_session(name: name, working_dir: working_dir, profile: profile, source: source, model_id: model_id_override)
        broadcast_session_update(session_id)
        json_response(res, 201, { session: @registry.session_summary(session_id) })
      end

      # Auto-restore persisted sessions (or create a fresh default) when the server starts.
      # Skipped when no API key is configured (onboard flow will handle it).
      #
      # Strategy: load the most recent sessions from ~/.clacky/sessions/ for the
      # current working directory and restore them into @registry so their IDs are
      # stable across restarts (frontend hash stays valid). If no persisted sessions
      # exist, fall back to creating a brand-new default session.
      def create_default_session
        return unless @agent_config.models_configured?

        # Restore up to 5 sessions per source type from disk into the registry.
        @registry.restore_from_disk(n: 5)

        # If nothing was restored (no persisted sessions), create a fresh default.
        unless @registry.list(limit: 1).any?
          working_dir = default_working_dir
          FileUtils.mkdir_p(working_dir) unless Dir.exist?(working_dir)
          build_session(name: "Session 1", working_dir: working_dir)
        end
      end

      # ── Onboard API ───────────────────────────────────────────────────────────

      # GET /api/onboard/status
      # Phase "key_setup"  → no API key configured yet
      # Phase "soul_setup" → key configured, but ~/.clacky/agents/SOUL.md missing
      # needs_onboard: false → fully set up
      def api_onboard_status(res)
        if !@agent_config.models_configured?
          json_response(res, 200, { needs_onboard: true, phase: "key_setup" })
        else
          json_response(res, 200, { needs_onboard: false })
        end
      end

      # GET /api/browser/status
      # Returns real daemon liveness from BrowserManager (not just yml read).
      def api_browser_status(res)
        json_response(res, 200, @browser_manager.status)
      end

      # POST /api/browser/configure
      # Called by browser-setup skill to write browser.yml and hot-reload the daemon.
      # Body: { chrome_version: "146" }
      def api_browser_configure(req, res)
        body          = JSON.parse(req.body.to_s) rescue {}
        chrome_version = body["chrome_version"].to_s.strip
        return json_response(res, 422, { ok: false, error: "chrome_version is required" }) if chrome_version.empty?

        @browser_manager.configure(chrome_version: chrome_version)
        json_response(res, 200, { ok: true })
      rescue StandardError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # POST /api/browser/reload
      # Called by browser-setup skill after writing browser.yml.
      # Hot-reloads the MCP daemon with the new configuration.
      def api_browser_reload(res)
        @browser_manager.reload
        json_response(res, 200, { ok: true })
      rescue StandardError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # POST /api/browser/toggle
      def api_browser_toggle(res)
        enabled = @browser_manager.toggle
        json_response(res, 200, { ok: true, enabled: enabled })
      rescue StandardError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # POST /api/onboard/complete
      # Called after key setup is done (soul_setup is optional/skipped).
      # Creates the default session if none exists yet, returns it.
      def api_onboard_complete(req, res)
        create_default_session if @registry.list(limit: 1).empty?
        first_session = @registry.list(limit: 1).first
        json_response(res, 200, { ok: true, session: first_session })
      end

      # POST /api/onboard/skip-soul
      # Writes a minimal SOUL.md so the soul_setup phase is not re-triggered
      # on the next server start when the user chooses to skip the conversation.
      def api_onboard_skip_soul(req, res)
        body = parse_json_body(req)
        lang = body["lang"].to_s.strip
        soul_content = lang == "zh" ? DEFAULT_SOUL_MD_ZH : DEFAULT_SOUL_MD

        agents_dir = File.expand_path("~/.clacky/agents")
        FileUtils.mkdir_p(agents_dir)
        soul_path = File.join(agents_dir, "SOUL.md")
        unless File.exist?(soul_path)
          File.write(soul_path, soul_content)
        end
        json_response(res, 200, { ok: true })
      end

      # ── Brand API ─────────────────────────────────────────────────────────────

      # Process-wide mutex guarding heartbeat trigger state.
      # Used by #trigger_async_heartbeat! to ensure only one heartbeat Thread is
      # in flight at a time, no matter how many concurrent /api/brand/status
      # requests arrive from the Web UI poller.
      BRAND_HEARTBEAT_MUTEX   = Mutex.new
      # Tracks whether a heartbeat Thread is currently running.
      @@brand_heartbeat_inflight = false

      # Mutex + inflight flag for async distribution refresh. Mirrors the
      # heartbeat pattern above so the same guarantees hold: at most one
      # refresh thread per process regardless of how many concurrent
      # /api/brand/status polls arrive from the Web UI.
      BRAND_DIST_REFRESH_MUTEX   = Mutex.new
      @@brand_dist_refresh_inflight = false

      # Fire a heartbeat in a background Thread without blocking the caller.
      #
      # Contract:
      #   * Only one heartbeat Thread may be running at any moment across the
      #     whole process. If one is already in flight, this call is a no-op.
      #   * The caller never waits: it returns immediately after (at most)
      #     spawning the Thread.
      #   * The Thread rescues everything so a network failure cannot kill the
      #     server or leak an exception through the web stack.
      def trigger_async_heartbeat!
        BRAND_HEARTBEAT_MUTEX.synchronize do
          if @@brand_heartbeat_inflight
            Clacky::Logger.debug("[Brand] heartbeat already in flight, skipping")
            return
          end
          @@brand_heartbeat_inflight = true
        end

        Thread.new do
          Clacky::Logger.info("[Brand] async heartbeat starting...")
          begin
            brand  = Clacky::BrandConfig.load
            result = brand.heartbeat!
            if result[:success]
              Clacky::Logger.info("[Brand] async heartbeat OK")
            else
              Clacky::Logger.warn("[Brand] async heartbeat failed — #{result[:message]}")
            end
          rescue StandardError => e
            Clacky::Logger.warn("[Brand] async heartbeat raised: #{e.class}: #{e.message}")
          ensure
            BRAND_HEARTBEAT_MUTEX.synchronize do
              @@brand_heartbeat_inflight = false
            end
          end
        end
      end

      # Fire a public-distribution refresh in a background Thread.
      #
      # Used for installs that have a package_name configured via install.sh
      # but haven't activated a license yet — they would otherwise never see
      # the brand logo / theme / homepage_url until activation. See
      # BrandConfig#refresh_distribution! for the end-to-end flow.
      #
      # Contract mirrors #trigger_async_heartbeat!:
      #   * At most one refresh Thread in flight process-wide.
      #   * Caller never waits — Web UI first paint is not blocked on network.
      #   * All exceptions are swallowed; a refresh failure must not crash the
      #     server or leak through the web stack.
      def trigger_async_distribution_refresh!
        BRAND_DIST_REFRESH_MUTEX.synchronize do
          if @@brand_dist_refresh_inflight
            Clacky::Logger.debug("[Brand] distribution refresh already in flight, skipping")
            return
          end
          @@brand_dist_refresh_inflight = true
        end

        Thread.new do
          Clacky::Logger.info("[Brand] async distribution refresh starting...")
          begin
            brand  = Clacky::BrandConfig.load
            result = brand.refresh_distribution!
            if result[:success]
              Clacky::Logger.info("[Brand] async distribution refresh OK")
            else
              Clacky::Logger.debug("[Brand] async distribution refresh skipped/failed — #{result[:message]}")
            end
          rescue StandardError => e
            Clacky::Logger.warn("[Brand] async distribution refresh raised: #{e.class}: #{e.message}")
          ensure
            BRAND_DIST_REFRESH_MUTEX.synchronize do
              @@brand_dist_refresh_inflight = false
            end
          end
        end
      end

      # GET /api/brand/status
      # Returns whether brand activation is needed.
      # Mirrors the onboard/status pattern so the frontend can gate on it.
      #
      # Response:
      #   { branded: false }                              → no brand, nothing to do
      #   { branded: true, needs_activation: true,
      #     product_name: "JohnAI" }                     → license key required
      #   { branded: true, needs_activation: false,
      #     product_name: "JohnAI", warning: "..." }     → activated, possible warning
      def api_brand_status(res)
        brand = Clacky::BrandConfig.load

        unless brand.branded?
          json_response(res, 200, { branded: false })
          return
        end

        unless brand.activated?
          # Refresh public brand assets (logo, theme, homepage_url, support_*)
          # if due. This catches the common case of `install.sh --brand-name=X`
          # which writes only product_name + package_name — without this poll
          # the user would never see the brand's logo/theme until activation.
          # Completely asynchronous: we do NOT wait for the network round-trip.
          #
          # `distribution_refresh_pending` lets the Web UI know a refresh is
          # in flight, so it can re-poll /api/brand shortly and apply the
          # logo/theme without requiring the user to activate or refresh the
          # page first.
          refresh_pending = false
          if brand.distribution_refresh_due?
            trigger_async_distribution_refresh!
            refresh_pending = true
          end

          json_response(res, 200, {
            branded:                       true,
            needs_activation:              true,
            product_name:                  brand.product_name,
            test_mode:                     @brand_test,
            distribution_refresh_pending:  refresh_pending
          })
          return
        end

        # Send heartbeat asynchronously if interval has elapsed (once per day).
        #
        # We must NOT block this HTTP response on the heartbeat call: a slow or
        # unreachable license server would otherwise stall the Web UI's first
        # paint for up to ~92s (2 hosts × 2 attempts × 23s timeout). The fresh
        # expires_at / last_heartbeat will be picked up on the next /api/brand/status
        # poll, which is sufficient for a once-per-day check.
        if brand.heartbeat_due?
          trigger_async_heartbeat!
        else
          Clacky::Logger.debug("[Brand] api_brand_status: heartbeat not due yet")
        end

        Clacky::Logger.debug("[Brand] api_brand_status: expired=#{brand.expired?} grace_exceeded=#{brand.grace_period_exceeded?} expires_at=#{brand.license_expires_at&.iso8601 || "nil"}")

        warning = nil
        if brand.expired?
          warning = "Your #{brand.product_name} license has expired. Please renew to continue."
        elsif brand.grace_period_exceeded?
          warning = "License server unreachable for more than 3 days. Please check your connection."
        elsif brand.license_expires_at && !brand.expired?
          days_remaining = ((brand.license_expires_at - Time.now.utc) / 86_400).ceil
          if days_remaining <= 7
            warning = "Your #{brand.product_name} license expires in #{days_remaining} day#{"s" if days_remaining != 1}. Please renew soon."
          end
        end

        Clacky::Logger.debug("[Brand] api_brand_status: warning=#{warning.inspect}")

        json_response(res, 200, {
          branded:          true,
          needs_activation: false,
          product_name:     brand.product_name,
          warning:          warning,
          test_mode:        @brand_test,
          user_licensed:    brand.user_licensed?,
          license_user_id:  brand.license_user_id
        })
      end

      # POST /api/brand/activate
      # Body: { license_key: "XXXX-XXXX-XXXX-XXXX-XXXX" }
      # Activates the license and persists the result to brand.yml.
      def api_brand_activate(req, res)
        body = parse_json_body(req)
        key  = body["license_key"].to_s.strip

        if key.empty?
          json_response(res, 422, { ok: false, error: "license_key is required" })
          return
        end

        brand  = Clacky::BrandConfig.load
        result = @brand_test ? brand.activate_mock!(key) : brand.activate!(key)

        if result[:success]
          # Refresh skill_loader with the now-activated brand config so brand
          # skills are loadable from this point forward (e.g. after sync).
          @skill_loader = Clacky::SkillLoader.new(working_dir: nil, brand_config: brand)
          json_response(res, 200, {
            ok:            true,
            product_name:  result[:product_name] || brand.product_name,
            user_id:       result[:user_id] || brand.license_user_id,
            user_licensed: brand.user_licensed?
          })
        else
          json_response(res, 422, { ok: false, error: result[:message] })
        end
      end

      # DELETE /api/brand/license
      # Deactivates (unbinds) the current brand license and clears all brand state.
      # Brand skills are removed from disk. Returns 200 on success.
      private def api_brand_deactivate(res)
        brand  = Clacky::BrandConfig.load
        result = brand.deactivate!
        # Reload skill_loader without brand config so brand skills are no longer visible.
        @skill_loader = Clacky::SkillLoader.new(working_dir: nil, brand_config: Clacky::BrandConfig.new({}))
        json_response(res, 200, { ok: true })
      end

      # GET /api/brand/skills
      # Fetches the brand skills list from the cloud, enriched with local installed version.
      # Returns 200 with skill list, or 403 when license is not activated.
      # If the remote API call fails, falls back to locally installed skills with a warning.
      # GET /api/store/skills
      # Returns the public skill store catalog from the OpenClacky Cloud API.
      # Requires an activated license — uses HMAC auth with scope: "store" to fetch
      # platform-wide published public skills (not filtered by the user's own skills).
      # Falls back to the hardcoded catalog when license is not activated or API is unavailable.
      def api_store_skills(res)
        brand  = Clacky::BrandConfig.load
        result = brand.fetch_store_skills!

        if result[:success]
          json_response(res, 200, { ok: true, skills: result[:skills] })
        else
          # License not activated or remote API unavailable — return empty list
          json_response(res, 200, {
            ok:      true,
            skills:  [],
            warning: result[:error] || "Could not reach the skill store."
          })
        end
      end

      # POST /api/store/skills/:slug/install
      def api_brand_skills(res)
        brand = Clacky::BrandConfig.load

        unless brand.activated?
          json_response(res, 403, { ok: false, error: "License not activated" })
          return
        end

        if @brand_test
          # Return mock skills in brand-test mode instead of calling the remote API
          result = mock_brand_skills(brand)
        else
          result = brand.fetch_brand_skills!
        end

        if result[:success]
          json_response(res, 200, { ok: true, skills: result[:skills], expires_at: result[:expires_at] })
        else
          # Remote API failed — fall back to locally installed skills so the user
          # can still see and use what they already have. Surface a soft warning.
          local_skills = brand.installed_brand_skills.map do |name, meta|
            {
              "name"              => meta["name"] || name,
              "name_zh"           => meta["name_zh"].to_s,
              # Use locally cached description so it renders correctly offline
              "description"       => meta["description"].to_s,
              "description_zh"    => meta["description_zh"].to_s,
              "installed_version" => meta["version"],
              "needs_update"      => false
            }
          end
          json_response(res, 200, {
            ok:           true,
            skills:       local_skills,
            # warning_code lets the frontend render a localized message.
            # `warning` is kept for back-compat and as an English fallback.
            warning_code: "remote_unavailable",
            warning:      "Could not reach the license server. Showing locally installed skills only."
          })
        end
      end

      # POST /api/brand/skills/:name/install
      # Downloads and installs (or updates) the given brand skill.
      # Body may optionally contain { skill_info: {...} } from the frontend cache;
      # otherwise we re-fetch to get the download_url.
      def api_brand_skill_install(slug, req, res)
        brand = Clacky::BrandConfig.load

        unless brand.activated?
          json_response(res, 403, { ok: false, error: "License not activated" })
          return
        end

        # Re-fetch the skills list to get the authoritative download_url
        if @brand_test
          all_skills = mock_brand_skills(brand)[:skills]
        else
          fetch_result = brand.fetch_brand_skills!
          unless fetch_result[:success]
            json_response(res, 422, { ok: false, error: fetch_result[:error] })
            return
          end
          all_skills = fetch_result[:skills]
        end

        skill_info = all_skills.find { |s| s["name"] == slug }
        unless skill_info
          json_response(res, 404, { ok: false, error: "Skill '#{slug}' not found in license" })
          return
        end

        # In brand-test mode use the mock installer which writes a real .enc file
        # so the full decrypt → load → invoke code-path is exercised end-to-end.
        result = @brand_test ? brand.install_mock_brand_skill!(skill_info) : brand.install_brand_skill!(skill_info)

        if result[:success]
          # Reload skills so the Agent can pick up the new skill immediately.
          # Re-create the loader with the current brand_config so brand skills are decryptable.
          @skill_loader = Clacky::SkillLoader.new(working_dir: nil, brand_config: brand)
          json_response(res, 200, { ok: true, name: result[:name], version: result[:version] })
        else
          json_response(res, 422, { ok: false, error: result[:error] })
        end
      rescue StandardError, ScriptError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # GET /api/brand
      # Returns brand metadata consumed by the WebUI on boot
      # to dynamically replace branding strings.
      def api_brand_info(res)
        brand = Clacky::BrandConfig.load
        json_response(res, 200, brand.to_h)
      end

      # ── Version API ───────────────────────────────────────────────────────────

      # GET /api/version
      # Returns current version and latest version from RubyGems (cached for 1 hour).
      def api_get_version(res)
        current = Clacky::VERSION
        latest  = fetch_latest_version_cached
        json_response(res, 200, {
          current:      current,
          latest:       latest,
          needs_update: latest ? version_older?(current, latest) : false
        })
      end

      # POST /api/version/upgrade
      # Upgrades openclacky in a background thread, streaming output via WebSocket broadcast.
      # If the user's gem source is the official RubyGems, use `gem update`.
      # Otherwise (e.g. Aliyun mirror) download the .gem from OSS CDN to bypass mirror lag.
      def api_upgrade_version(req, res)
        json_response(res, 202, { ok: true, message: "Upgrade started" })

        Thread.new do
          begin
            if official_gem_source?
              upgrade_via_gem_update
            else
              upgrade_via_oss_cdn
            end
          rescue StandardError => e
            Clacky::Logger.error("[Upgrade] Exception: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
            broadcast_all(type: "upgrade_log", line: "\n✗ Error during upgrade: #{e.message}\n")
            broadcast_all(type: "upgrade_complete", success: false)
          end
        end
      end

      # Returns true when the bind host is loopback-only.
      private def local_host?(host)
        ["127.0.0.1", "::1", "localhost"].include?(host.to_s.strip)
      end

      # Resolve access key from CLACKY_ACCESS_KEY env var only.
      private def resolve_access_key
        key = ENV.fetch("CLACKY_ACCESS_KEY", "").strip
        key.empty? ? nil : key
      end

      # Extract bearer token or query param from a WEBrick request.
      # Priority: Authorization: Bearer > ?access_key=
      # The query string form is only used by WebSocket connections, which
      # cannot set custom headers from the browser. All HTTP clients —
      # including the web UI (via a fetch interceptor in auth.js) — use the
      # Authorization header.
      private def extract_key(req)
        auth = req["Authorization"].to_s.strip
        if auth.start_with?("Bearer ")
          token = auth.sub(/\ABearer\s+/i, "").strip
          return token unless token.empty?
        end

        query = URI.decode_www_form(req.query_string.to_s).to_h
        token = query["access_key"].to_s.strip
        return token unless token.empty?

        req.cookies.each do |c|
          return c.value if c.name == "clacky_access_key" && !c.value.to_s.empty?
        end

        nil
      end

      # Constant-time string comparison to prevent timing attacks.
      private def secure_compare(a, b)
        return false unless a.bytesize == b.bytesize

        result = 0
        a.unpack("C*").zip(b.unpack("C*")) { |x, y| result |= x ^ y }
        result.zero?
      end

      # Returns true if the request is authenticated or auth is disabled.
      # Writes 401/429 to res and returns false on failure.
      private def check_access_key(req, res)
        # Localhost binding — always trusted, no auth needed.
        return true if @localhost_only
        return true unless @access_key   # public but no key configured (cli already blocked this)

        ip        = req.peeraddr.last rescue "unknown"
        candidate = extract_key(req)

        # Lazily evict expired lockout entries to prevent unbounded memory growth.
        @auth_failures_mutex.synchronize do
          @auth_failures.delete_if { |_, e| Time.now >= e[:reset_at] }
        end

        # No key provided — reject immediately without counting as a failure.
        if candidate.nil? || candidate.empty?
          json_response(res, 401, {
            error: "Unauthorized: access key required",
            hint:  "Pass key via 'Authorization: Bearer <key>' header or '?access_key=<key>'"
          })
          return false
        end

        # Check if IP is currently locked out.
        blocked, wait_secs = @auth_failures_mutex.synchronize do
          entry = @auth_failures[ip]
          if entry && entry[:count] >= 10 && Time.now < entry[:reset_at]
            [true, (entry[:reset_at] - Time.now).ceil]
          else
            [false, 0]
          end
        end

        if blocked
          json_response(res, 429, { error: "Too many failed attempts", retry_after: wait_secs })
          return false
        end

        if secure_compare(@access_key, candidate)
          @auth_failures_mutex.synchronize { @auth_failures.delete(ip) }
          return true
        end

        @auth_failures_mutex.synchronize do
          entry = @auth_failures[ip] ||= { count: 0, reset_at: Time.now + 300 }
          entry[:count] += 1
          Clacky::Logger.warn("[Auth] Failed attempt #{entry[:count]}/10 from #{ip}")
        end

        json_response(res, 401, {
          error: "Unauthorized: invalid access key",
          hint:  "Pass key via 'Authorization: Bearer <key>' header or '?access_key=<key>'"
        })
        false
      end

      # Returns true when the configured gem source is the official RubyGems.org.
      # Raises on error — caller's rescue will handle it.
      private def official_gem_source?
        output, exit_code = run_shell("gem sources -l")
        raise "gem sources -l failed (exit #{exit_code}): #{output}" unless exit_code&.zero?

        Clacky::Logger.info("[Upgrade] gem sources: #{output.strip}")
        output.include?("https://rubygems.org") &&
          !output.match?(%r{mirrors\.|aliyun|tuna|ustc|ruby-china})
      end

      # Upgrade via `gem update openclacky --no-document` (official RubyGems source).
      private def upgrade_via_gem_update
        cmd = "gem update openclacky --no-document"
        Clacky::Logger.info("[Upgrade] Official source — running: #{cmd}")
        broadcast_all(type: "upgrade_log", line: "Starting upgrade: #{cmd}\n")

        output, exit_code = run_shell(cmd, timeout: 600)

        Clacky::Logger.info("[Upgrade] exit_code=#{exit_code}")
        Clacky::Logger.info("[Upgrade] output=#{output.slice(0, 1000)}")

        success = exit_code&.zero? || false

        broadcast_all(type: "upgrade_log", line: output)
        finish_upgrade(success, fallback_hint: "gem update openclacky")
      end

      # Upgrade via OSS CDN: fetch latest.txt → download .gem → gem install (bypasses mirror lag).
      private def upgrade_via_oss_cdn
        require "net/http"
        require "uri"

        oss_base   = "https://oss.1024code.com/openclacky"
        latest_url = "#{oss_base}/latest.txt"

        Clacky::Logger.info("[Upgrade] Non-official source — fetching latest version from OSS CDN")
        broadcast_all(type: "upgrade_log", line: "Non-official gem source detected — fetching latest version from OSS CDN...\n")

        # Step 1: fetch latest version from OSS
        latest_version = fetch_oss_latest_version(latest_url)
        unless latest_version
          broadcast_all(type: "upgrade_log", line: "✗ Failed to fetch latest version from OSS CDN\n")
          broadcast_all(type: "upgrade_complete", success: false)
          return
        end

        broadcast_all(type: "upgrade_log", line: "Latest version: #{latest_version}\n")

        # Already up to date?
        unless version_older?(Clacky::VERSION, latest_version)
          broadcast_all(type: "upgrade_log", line: "✓ Already at latest version (#{Clacky::VERSION})\n")
          broadcast_all(type: "upgrade_complete", success: true)
          return
        end

        # Step 2: download .gem file from OSS
        gem_url  = "#{oss_base}/openclacky-#{latest_version}.gem"
        gem_file = "/tmp/openclacky-#{latest_version}.gem"
        broadcast_all(type: "upgrade_log", line: "Downloading openclacky-#{latest_version}.gem from OSS...\n")
        Clacky::Logger.info("[Upgrade] Downloading #{gem_url}")

        shell_cmd = "curl -fsSL '#{gem_url}' -o '#{gem_file}'"
        dl_out, dl_exit = run_shell(shell_cmd, timeout: 300)
        unless dl_exit&.zero?
          broadcast_all(type: "upgrade_log", line: "✗ Download failed: #{dl_out}\n")
          broadcast_all(type: "upgrade_complete", success: false)
          return
        end

        # Step 3: install the downloaded .gem (dependencies resolved via configured gem source)
        cmd    = "gem install '#{gem_file}' --no-document"
        broadcast_all(type: "upgrade_log", line: "Installing...\n")
        Clacky::Logger.info("[Upgrade] Running: #{cmd}")

        output, exit_code = run_shell(cmd, timeout: 600)
        success = exit_code&.zero? || false

        broadcast_all(type: "upgrade_log", line: output)
        finish_upgrade(success, fallback_hint: "gem install #{gem_url}")
      ensure
        File.delete(gem_file) if gem_file && File.exist?(gem_file) rescue nil
      end

      # Fetch the latest version string from OSS latest.txt.
      private def fetch_oss_latest_version(url)
        require "net/http"
        uri  = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 10
        res = http.get(uri.request_uri)
        return nil unless res.is_a?(Net::HTTPSuccess)

        version = res.body.to_s.strip
        version.empty? ? nil : version
      rescue StandardError => e
        Clacky::Logger.warn("[Upgrade] fetch_oss_latest_version error: #{e.message}")
        nil
      end

      # Broadcast final upgrade result with appropriate log message.
      #
      # Defensive post-check: if `run_shell` reported failure but the gem
      # is in fact now installed at the latest version, reverse the verdict.
      # This guards against false negatives from the Terminal idle-poll
      # mechanism (see: 0.9.36 upgrade failure bug).
      private def finish_upgrade(success, fallback_hint: "gem update openclacky")
        if !success && gem_actually_upgraded?
          Clacky::Logger.warn("[Upgrade] run_shell reported failure, but installed version matches latest — treating as success.")
          broadcast_all(type: "upgrade_log", line: "\n(Verified: the new version is installed — reclassifying as success.)\n")
          success = true
        end

        if success
          Clacky::Logger.info("[Upgrade] Success!")
          broadcast_all(type: "upgrade_log", line: "\n✓ Upgrade successful! Please restart the server to apply the new version.\n")
          broadcast_all(type: "upgrade_complete", success: true)
        else
          Clacky::Logger.warn("[Upgrade] Failed.")
          broadcast_all(type: "upgrade_log", line: "\n✗ Upgrade failed. Please try manually: #{fallback_hint}\n")
          broadcast_all(type: "upgrade_complete", success: false)
        end
      end

      # Check whether the latest published version of openclacky is already
      # installed locally. Used as a post-upgrade sanity check so a flaky
      # run_shell result doesn't mask a successful install.
      # Returns false on any error (conservative — don't fabricate success).
      private def gem_actually_upgraded?
        latest = fetch_latest_version_from_rubygems_api
        return false unless latest

        out, exit_code = run_shell("gem list openclacky -i -v #{latest}", timeout: 30)
        return false unless exit_code&.zero?
        out.to_s.strip.downcase == "true"
      rescue StandardError => e
        Clacky::Logger.warn("[Upgrade] gem_actually_upgraded? error: #{e.message}")
        false
      end

      # POST /api/restart
      # Re-execs the current process so the newly installed gem version is loaded.
      # Uses the absolute script path captured at startup to avoid relative-path issues.
      # Responds 200 first, then waits briefly for WEBrick to flush the response before exec.
      def api_restart(req, res)
        json_response(res, 200, { ok: true, message: "Restarting…" })

        Thread.new do
          sleep 0.5  # Let WEBrick flush the HTTP response

          if @master_pid
            # Worker mode: tell master to hot-restart, then exit cleanly.
            Clacky::Logger.info("[Restart] Sending USR1 to master (PID=#{@master_pid})")
            begin
              Process.kill("USR1", @master_pid)
            rescue Errno::ESRCH
              Clacky::Logger.warn("[Restart] Master PID=#{@master_pid} not found, falling back to exec.")
              standalone_exec_restart
            end
            exit(0)
          else
            # Standalone mode (no master): fall back to the original exec approach.
            standalone_exec_restart
          end
        end
      end

      # Re-exec the current process via a login shell (rbenv/mise shim compatible).
      private def standalone_exec_restart
        script     = @restart_script
        argv       = @restart_argv
        shell      = ENV["SHELL"].to_s
        shell      = "/bin/bash" if shell.empty?
        cmd_parts  = [Shellwords.escape(script), *argv.map { |a| Shellwords.escape(a) }]
        cmd_string = cmd_parts.join(" ")
        Clacky::Logger.info("[Restart] exec: #{shell} -l -c #{cmd_string}")
        exec(shell, "-l", "-c", cmd_string)
      end

      # Fetch the latest gem version using `gem list -r`, with a 1-hour in-memory cache.
      # Uses Terminal (PTY + login shell) so rbenv/mise shims and gem mirrors work correctly.
      private def fetch_latest_version_cached
        @version_mutex.synchronize do
          now = Time.now
          if @version_cache && (now - @version_cache[:checked_at]) < 3600
            return @version_cache[:latest]
          end
        end

        # Fetch outside the mutex to avoid blocking other requests
        latest = fetch_latest_version_from_gem

        @version_mutex.synchronize do
          @version_cache = { latest: latest, checked_at: Time.now }
        end

        latest
      end

      # Query the latest openclacky version.
      # Strategy: try RubyGems official REST API first (most accurate, not affected by mirror lag),
      # then fall back to `gem list -r` (respects user's configured gem source).
      # Uses Terminal (PTY + login shell) so rbenv/mise shims and gem mirrors work correctly.
      private def fetch_latest_version_from_gem
        fetch_latest_version_from_rubygems_api || fetch_latest_version_from_gem_command
      end

      # Try RubyGems official REST API — fast and always up-to-date.
      # Returns nil if the request fails or times out.
      private def fetch_latest_version_from_rubygems_api
        require "net/http"
        require "json"

        uri      = URI("https://rubygems.org/api/v1/gems/openclacky.json")
        http     = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl     = true
        http.open_timeout = 5
        http.read_timeout = 8

        res = http.get(uri.request_uri)
        return nil unless res.is_a?(Net::HTTPSuccess)

        data = JSON.parse(res.body)
        data["version"].to_s.strip.then { |v| v.empty? ? nil : v }
      rescue StandardError
        nil
      end

      # Fall back to `gem list -r openclacky` via login shell.
      # Respects the user's configured gem source (rbenv/mise mirrors, etc.).
      # Output format: "openclacky (0.9.0)"
      private def fetch_latest_version_from_gem_command
        out, exit_code = run_shell("gem list -r openclacky", timeout: 30)
        return nil unless exit_code&.zero?

        match = out.match(/^openclacky\s+\(([^)]+)\)/)
        match ? match[1].strip : nil
      rescue StandardError
        nil
      end

      # Returns true if version string `a` is strictly older than `b`.
      private def version_older?(a, b)
        Gem::Version.new(a) < Gem::Version.new(b)
      rescue ArgumentError
        false
      end

      # Run a shell command via the unified Terminal tool and return
      # [output, exit_code] — drop-in replacement for Open3.capture2e.
      #
      # Delegates to Terminal.run_sync which handles the idle-poll loop
      # internally (see its docs for why that's needed — this wrapper used
      # to re-implement it wrong and caused the 0.9.36 upgrade bug).
      private def run_shell(command, timeout: 120)
        Clacky::Tools::Terminal.run_sync(command, timeout: timeout)
      end

      # ── Channel API ───────────────────────────────────────────────────────────

      # GET /api/channels
      # Returns current config and running status for all supported platforms.
      # POST /api/tool/browser
      # Executes a browser tool action via the shared BrowserManager daemon.
      # Used by skill scripts (e.g. feishu_setup.rb) to reuse the server's
      # existing Chrome connection without spawning a second MCP daemon.
      #
      # Request body: JSON with same params as the browser tool
      #   { "action": "snapshot", "interactive": true, ... }
      #
      # Response: JSON result from the browser tool
      def api_tool_browser(req, res)
        params = parse_json_body(req)
        action = params["action"]
        return json_response(res, 400, { error: "action is required" }) if action.nil? || action.empty?

        tool   = Clacky::Tools::Browser.new
        result = tool.execute(**params.transform_keys(&:to_sym))

        json_response(res, 200, result)
      rescue StandardError => e
        json_response(res, 500, { error: e.message })
      end

      def api_list_channels(res)
        config   = Clacky::ChannelConfig.load
        running  = @channel_manager.running_platforms

        platforms = Clacky::Channel::Adapters.all.map do |klass|
          platform = klass.platform_id
          raw      = config.instance_variable_get(:@channels)[platform.to_s] || {}
          {
            platform:  platform,
            enabled:   !!raw["enabled"],
            running:   running.include?(platform),
            has_config: !config.platform_config(platform).nil?
          }.merge(platform_safe_fields(platform, config))
        end

        json_response(res, 200, { channels: platforms })
      end

      # POST /api/upload
      # Accepts a multipart/form-data file upload (field name: "file").
      # Runs the file through FileProcessor: saves original + generates structured
      # preview (Markdown) for Office/ZIP files so the agent can read them directly.
      def api_upload_file(req, res)
        upload = parse_multipart_upload(req, "file")
        unless upload
          json_response(res, 400, { ok: false, error: "No file field found in multipart body" })
          return
        end

        saved = Clacky::Utils::FileProcessor.save(
          body:     upload[:data],
          filename: upload[:filename].to_s
        )

        json_response(res, 200, { ok: true, name: saved[:name], path: saved[:path] })
      rescue => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # POST /api/open-file
      # Opens a local file or directory using the OS default handler.
      # Used by the Web UI to handle file:// links — browsers block direct
      # file:// navigation from http:// pages for security reasons.
      def api_open_file(req, res)
        path = parse_json_body(req)["path"]
        return json_response(res, 400, { error: "path is required" }) unless path && !path.empty?

        # On WSL the file may be specified as a Windows path (e.g. "C:/Users/…").
        # Convert it to the Linux-side path so File.exist? works.
        linux_path = Utils::EnvironmentDetector.win_to_linux_path(path)

        return json_response(res, 404, { error: "file not found" }) unless File.exist?(linux_path)

        result = Utils::EnvironmentDetector.open_file(linux_path)
        return json_response(res, 501, { error: "unsupported OS" }) if result.nil?
        json_response(res, 200, { ok: true })
      rescue => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # POST /api/channels/:platform
      # Body: { fields... }  (platform-specific credential fields)
      # Saves credentials and optionally (re)starts the adapter.
      def api_save_channel(platform, req, res)
        platform = platform.to_sym
        body     = parse_json_body(req)
        config   = Clacky::ChannelConfig.load

        fields = body.transform_keys(&:to_sym).reject { |k, _| k == :platform }
        fields = fields.transform_values { |v| v.is_a?(String) ? v.strip : v }

        # Record when the token was last updated so clients can detect re-login
        fields[:token_updated_at] = Time.now.to_i if platform == :weixin && fields.key?(:token)

        # Validate credentials against live API before persisting.
        # Merge with existing config so partial updates (e.g. allowed_users only) still validate correctly.
        klass = Clacky::Channel::Adapters.find(platform)
        if klass && klass.respond_to?(:test_connection)
          existing = config.platform_config(platform) || {}
          merged   = existing.merge(fields)
          result   = klass.test_connection(merged)
          unless result[:ok]
            json_response(res, 422, { ok: false, error: result[:error] || "Credential validation failed" })
            return
          end
        end

        config.set_platform(platform, **fields)
        config.save

        # Hot-reload: stop existing adapter for this platform (if running) and restart
        @channel_manager.reload_platform(platform, config)

        json_response(res, 200, { ok: true })
      rescue StandardError => e
        json_response(res, 422, { ok: false, error: e.message })
      end

      # DELETE /api/channels/:platform
      # Disables the platform (keeps credentials, sets enabled: false).
      def api_delete_channel(platform, res)
        platform = platform.to_sym
        config   = Clacky::ChannelConfig.load
        config.disable_platform(platform)
        config.save

        @channel_manager.reload_platform(platform, config)

        json_response(res, 200, { ok: true })
      rescue StandardError => e
        json_response(res, 422, { ok: false, error: e.message })
      end

      # POST /api/channels/:platform/test
      # Body: { fields... }  (credentials to test — NOT saved)
      # Tests connectivity using the provided credentials without persisting.
      def api_test_channel(platform, req, res)
        platform = platform.to_sym
        body     = parse_json_body(req)
        fields   = body.transform_keys(&:to_sym).reject { |k, _| k == :platform }

        klass = Clacky::Channel::Adapters.find(platform)
        unless klass
          json_response(res, 404, { ok: false, error: "Unknown platform: #{platform}" })
          return
        end

        result = klass.test_connection(fields)
        json_response(res, 200, result)
      rescue StandardError => e
        json_response(res, 200, { ok: false, error: e.message })
      end

      # Returns non-secret fields for a platform (masked secrets).
      private def platform_safe_fields(platform, config)
        raw = config.instance_variable_get(:@channels)[platform.to_s] || {}
        case platform.to_sym
        when :feishu
          {
            app_id:        raw["app_id"] || "",
            domain:        raw["domain"] || Clacky::Channel::Adapters::Feishu::DEFAULT_DOMAIN,
            allowed_users: raw["allowed_users"] || []
          }
        when :wecom
          {
            bot_id: raw["bot_id"] || ""
          }
        when :weixin
          {
            base_url:          raw["base_url"] || Clacky::Channel::Adapters::Weixin::ApiClient::DEFAULT_BASE_URL,
            allowed_users:     raw["allowed_users"] || [],
            has_token:         !raw["token"].to_s.strip.empty?,
            token_updated_at:  raw["token_updated_at"]  # Unix timestamp, nil if never set
          }
        else
          {}
        end
      end

      # Returns a mock brand skills list for use in brand-test mode.
      # Simulates two skills — one installed, one pending update, one not installed.
      private def mock_brand_skills(brand)
        installed = brand.installed_brand_skills
        mock_skills = [
          {
            "id"          => 1,
            "name"        => "code-review-bot",
            "description" => "Automated AI code review with inline suggestions.",
            "visibility"  => "private",
            "version"     => "1.2.0",
            "emoji"       => "🔍",
            "latest_version" => {
              "version"      => "1.2.0",
              "checksum"     => "deadbeef" * 8,
              "release_notes" => "Improved Python and Ruby support.",
              "published_at" => "2026-02-15T00:00:00Z",
              "download_url" => nil  # nil = no actual download in mock mode
            }
          },
          {
            "id"          => 2,
            "name"        => "deploy-assistant",
            "description" => "One-command deployment for Rails / Node / Docker projects.",
            "visibility"  => "private",
            "version"     => "2.0.1",
            "emoji"       => "🚀",
            "latest_version" => {
              "version"      => "2.0.1",
              "checksum"     => "cafebabe" * 8,
              "release_notes" => "Added Railway and Fly.io support.",
              "published_at" => "2026-03-01T00:00:00Z",
              "download_url" => nil
            }
          },
          {
            "id"          => 3,
            "name"        => "test-runner",
            "description" => "Run your test suite and summarize failures with AI insights.",
            "visibility"  => "private",
            "version"     => "1.0.0",
            "emoji"       => "🧪",
            "latest_version" => {
              "version"      => "1.1.0",
              "checksum"     => "0badf00d" * 8,
              "release_notes" => "RSpec and Minitest support, parallel runs.",
              "published_at" => "2026-03-05T00:00:00Z",
              "download_url" => nil
            }
          }
        ].map do |skill|
          name     = skill["name"]
          local    = installed[name]
          latest_v = (skill["latest_version"] || {})["version"]
          skill.merge(
            "installed_version" => local ? local["version"] : nil,
            "needs_update"      => local ? Clacky::BrandConfig.version_older?(local["version"], latest_v) : false
          )
        end

        {
          success:    true,
          skills:     mock_skills,
          expires_at: (Time.now.utc + 365 * 86_400).iso8601
        }
      end


      # ── Cron-Tasks API ───────────────────────────────────────────────────────
      # Unified API that manages task file + schedule as a single resource.

      # GET /api/cron-tasks
      def api_list_cron_tasks(res)
        json_response(res, 200, { cron_tasks: @scheduler.list_cron_tasks })
      end

      # POST /api/cron-tasks — create task file + schedule in one step
      # Body: { name, content, cron, enabled? }
      def api_create_cron_task(req, res)
        body    = parse_json_body(req)
        name    = body["name"].to_s.strip
        content = body["content"].to_s
        cron    = body["cron"].to_s.strip
        enabled = body.key?("enabled") ? body["enabled"] : true

        return json_response(res, 422, { error: "name is required" })    if name.empty?
        return json_response(res, 422, { error: "content is required" }) if content.empty?
        return json_response(res, 422, { error: "cron is required" })    if cron.empty?

        fields = cron.strip.split(/\s+/)
        unless fields.size == 5
          return json_response(res, 422, { error: "cron must have 5 fields (min hour dom month dow)" })
        end

        @scheduler.create_cron_task(name: name, content: content, cron: cron, enabled: enabled)
        json_response(res, 201, { ok: true, name: name })
      end

      # PATCH /api/cron-tasks/:name — update content and/or cron/enabled
      # Body: { content?, cron?, enabled? }
      def api_update_cron_task(name, req, res)
        body    = parse_json_body(req)
        content = body["content"]
        cron    = body["cron"]&.to_s&.strip
        enabled = body["enabled"]

        if cron && cron.split(/\s+/).size != 5
          return json_response(res, 422, { error: "cron must have 5 fields (min hour dom month dow)" })
        end

        @scheduler.update_cron_task(name, content: content, cron: cron, enabled: enabled)
        json_response(res, 200, { ok: true, name: name })
      rescue => e
        json_response(res, 404, { error: e.message })
      end

      # DELETE /api/cron-tasks/:name — remove task file + schedule
      def api_delete_cron_task(name, res)
        if @scheduler.delete_cron_task(name)
          json_response(res, 200, { ok: true })
        else
          json_response(res, 404, { error: "Cron task not found: #{name}" })
        end
      end

      # POST /api/cron-tasks/:name/run — execute immediately
      def api_run_cron_task(name, res)
        unless @scheduler.list_tasks.include?(name)
          return json_response(res, 404, { error: "Cron task not found: #{name}" })
        end

        prompt       = @scheduler.read_task(name)
        session_name = "▶ #{name} #{Time.now.strftime("%H:%M")}"
        working_dir  = File.expand_path("~/clacky_workspace")
        FileUtils.mkdir_p(working_dir)

        session_id = build_session(name: session_name, working_dir: working_dir, permission_mode: :auto_approve)
        @registry.update(session_id, pending_task: prompt, pending_working_dir: working_dir)

        json_response(res, 202, { ok: true, session: @registry.session_summary(session_id) })
      rescue => e
        json_response(res, 422, { error: e.message })
      end

      # ── Skills API ────────────────────────────────────────────────────────────

      # GET /api/skills — list all loaded skills with metadata
      def api_list_skills(res)
        @skill_loader.load_all  # refresh from disk on each request
        upload_meta = Clacky::BrandConfig.load_upload_meta
        shadowed    = @skill_loader.shadowed_by_local

        skills = @skill_loader.all_skills.reject(&:brand_skill).map do |skill|
          source = @skill_loader.loaded_from[skill.identifier]
          meta   = upload_meta[skill.identifier] || {}

          # Compute local modification time of SKILL.md for "has local changes" indicator
          skill_md_path = File.join(skill.directory.to_s, "SKILL.md")
          local_modified_at = File.exist?(skill_md_path) ? File.mtime(skill_md_path).utc.iso8601 : nil

          entry = {
            name:              skill.identifier,
            name_zh:           skill.name_zh,
            description:       skill.context_description,
            description_zh:    skill.description_zh,
            source:            source,
            enabled:           !skill.disabled?,
            invalid:           skill.invalid?,
            warnings:          skill.warnings,
            platform_version:  meta["platform_version"],
            uploaded_at:       meta["uploaded_at"],
            local_modified_at: local_modified_at,
            # true when this local skill is shadowing a same-named brand skill
            shadowing_brand:   shadowed.key?(skill.identifier)
          }
          entry[:invalid_reason] = skill.invalid_reason if skill.invalid?
          entry
        end
        json_response(res, 200, { skills: skills })
      end

      # GET /api/sessions/:id/skills — list user-invocable skills for a session,
      # filtered by the session's agent profile. Used by the frontend slash-command
      # autocomplete so only skills valid for the current profile are suggested.
      def api_session_skills(session_id, res)
        unless @registry.ensure(session_id)
          json_response(res, 404, { error: "Session not found" })
          return
        end
        session = @registry.get(session_id)
        unless session
          json_response(res, 404, { error: "Session not found" })
          return
        end

        agent = session[:agent]
        unless agent
          json_response(res, 404, { error: "Agent not found" })
          return
        end

        agent.skill_loader.load_all
        profile = agent.agent_profile

        skills = agent.skill_loader.user_invocable_skills
        skills = skills.select { |s| s.allowed_for_agent?(profile.name) } if profile

        loader      = agent.skill_loader
        loaded_from = loader.loaded_from

                  skill_data = skills.map do |skill|
          source_type = loaded_from[skill.identifier]
          {
            name:           skill.identifier,
            name_zh:        skill.name_zh,
            description:    skill.description || skill.context_description,
            description_zh: skill.description_zh,
            encrypted:      skill.encrypted?,
            source_type:    source_type
          }
        end

        json_response(res, 200, { skills: skill_data })
      end

      # PATCH /api/skills/:name/toggle — enable or disable a skill
      # Body: { enabled: true/false }
      def api_toggle_skill(name, req, res)
        body    = parse_json_body(req)
        enabled = body["enabled"]

        if enabled.nil?
          json_response(res, 422, { error: "enabled field required" })
          return
        end

        skill = @skill_loader.toggle_skill(name, enabled: enabled)
        json_response(res, 200, { ok: true, name: skill.identifier, enabled: !skill.disabled? })
      rescue Clacky::AgentError => e
        json_response(res, 422, { error: e.message })
      end

      # POST /api/my-skills/:name/publish
      # GET /api/creator/skills
      # Returns two separate groups:
      #   cloud_skills — published to the platform (with download_count)
      #   local_skills — local user skills not yet published, or published but with local changes
      # Requires user_licensed? — returns 403 otherwise.
      private def api_creator_skills(res)
        brand = Clacky::BrandConfig.load

        unless brand.user_licensed?
          json_response(res, 403, { ok: false, error: "User license required" })
          return
        end

        @skill_loader.load_all
        upload_meta  = Clacky::BrandConfig.load_upload_meta
        shadowed     = @skill_loader.shadowed_by_local

        # Local user skills (exclude default/brand sources)
        local_skill_objects = @skill_loader.all_skills.reject(&:brand_skill).select do |skill|
          src = @skill_loader.loaded_from[skill.identifier]
          %i[global_clacky project_clacky global_claude project_claude].include?(src)
        end

        # Build local map: name → entry
        local_map = local_skill_objects.each_with_object({}) do |skill, h|
          meta = upload_meta[skill.identifier] || {}
          skill_md_path = File.join(skill.directory.to_s, "SKILL.md")
          local_modified_at = File.exist?(skill_md_path) ? File.mtime(skill_md_path).utc.iso8601 : nil
          h[skill.identifier] = {
            name:              skill.identifier,
            description:       skill.context_description,
            source:            @skill_loader.loaded_from[skill.identifier],
            enabled:           !skill.disabled?,
            platform_version:  meta["platform_version"],
            uploaded_at:       meta["uploaded_at"],
            local_modified_at: local_modified_at,
            shadowing_brand:   shadowed.key?(skill.identifier)
          }
        end

        # Fetch platform skills (may fail — we still return local skills)
        platform_result = brand.fetch_my_skills!
        platform_skills = platform_result[:success] ? platform_result[:skills] : []

        # cloud_skills: everything that has been published to the platform
        # (annotated with local presence and change indicator)
        cloud_skills = platform_skills.map do |ps|
          name  = ps["name"].to_s
          local = local_map[name]
          # Has local changes if local SKILL.md mtime is newer than uploaded_at
          has_local_changes = if local && local[:local_modified_at] && local[:uploaded_at]
            Time.parse(local[:local_modified_at]) > Time.parse(local[:uploaded_at]) rescue false
          else
            false
          end
          {
            name:              name,
            description:       ps["description"],
            version:           ps["version"],
            download_count:    ps["download_count"] || 0,
            status:            ps["status"],
            local_present:     local_map.key?(name),
            has_local_changes: has_local_changes,
            uploaded_at:       ps["updated_at"],
            local_modified_at: local&.dig(:local_modified_at)
          }
        end.sort_by { |s| s[:name] }

        # local_skills: local user skills that have NOT been published yet
        # (uploaded_at nil means never published; skip if already in cloud)
        published_names = platform_skills.map { |ps| ps["name"].to_s }.to_set
        local_skills = local_map.values
          .reject { |e| published_names.include?(e[:name]) }
          .sort_by { |e| e[:name] }

        json_response(res, 200, {
          ok:                   true,
          cloud_skills:         cloud_skills,
          local_skills:         local_skills,
          platform_fetch_error: platform_result[:success] ? nil : platform_result[:error]
        })
      end

      # GET /api/trash[?project=<path>]
      # Lists recently deleted files in the AI trash.
      #
      # The trash is organized by project_root; each project gets its own
      # hashed subdirectory under ~/.clacky/trash/ (see TrashDirectory).
      # Returns ALL projects' deletions by default, with a per-file
      # project_root field so the UI can group or filter.
      #
      # Optional ?project=<absolute-path> restricts to a single project.
      # Response:
      #   { ok: true,
      #     files: [ { original_path, deleted_at, file_size, file_type,
      #                project_root, project_name, trash_file } ],
      #     projects: [ { project_root, project_name, file_count, total_size } ],
      #     total_count, total_size }
      private def api_trash(req, res)
        query = URI.decode_www_form(req.query_string.to_s).to_h
        filter_project = query["project"].to_s.strip
        filter_project = nil if filter_project.empty?

        projects =
          if filter_project
            [{ project_root: File.expand_path(filter_project),
               project_name: File.basename(File.expand_path(filter_project)),
               trash_dir:    Clacky::TrashDirectory.new(filter_project).trash_dir }]
          else
            Clacky::TrashDirectory.all_projects
          end

        all_files    = []
        project_rows = []

        projects.each do |p|
          files = _trash_files_in(p[:trash_dir], p[:project_root])
          next if files.empty? && filter_project.nil?

          total_size = files.sum { |f| f[:file_size].to_i }
          project_rows << {
            project_root: p[:project_root],
            project_name: p[:project_name],
            file_count:   files.size,
            total_size:   total_size
          }

          files.each do |f|
            all_files << f.merge(
              project_root: p[:project_root],
              project_name: p[:project_name]
            )
          end
        end

        all_files.sort_by! { |f| f[:deleted_at].to_s }.reverse!

        json_response(res, 200, {
          ok:           true,
          files:        all_files,
          projects:     project_rows,
          total_count:  all_files.size,
          total_size:   all_files.sum { |f| f[:file_size].to_i }
        })
      end

      # POST /api/trash/restore
      # Body: { project_root: "...", original_path: "..." }
      # Restores a single file from trash back to its original location.
      # Refuses if the target already exists on disk.
      private def api_trash_restore(req, res)
        data           = parse_json_body(req)
        project_root   = data["project_root"].to_s.strip
        original_path  = data["original_path"].to_s.strip

        if project_root.empty? || original_path.empty?
          json_response(res, 400, { ok: false, error: "project_root and original_path are required" })
          return
        end

        tool   = Clacky::Tools::TrashManager.new
        result = tool.execute(action: "restore",
                              file_path: original_path,
                              working_dir: project_root)

        if result[:success]
          json_response(res, 200, { ok: true, restored_file: result[:restored_file], message: result[:message] })
        else
          json_response(res, 422, { ok: false, error: result[:message] })
        end
      end

      # DELETE /api/trash[?project=<path>][&days_old=<n>][&file=<original_path>]
      # Three modes:
      #   ?file=<original_path>&project=<root>  → permanently delete one file
      #   ?project=<root>[&days_old=0]          → empty that project's trash
      #   (no project, days_old required)       → empty ALL projects older than N days
      private def api_trash_delete(req, res)
        query         = URI.decode_www_form(req.query_string.to_s).to_h
        project_root  = query["project"].to_s.strip
        days_old      = query["days_old"].to_s.strip
        file_path     = query["file"].to_s.strip

        project_root = nil if project_root.empty?
        file_path    = nil if file_path.empty?

        # Mode 1: single-file permanent delete
        if file_path
          unless project_root
            json_response(res, 400, { ok: false, error: "project is required when file is given" })
            return
          end
          deleted = _trash_delete_single(project_root, file_path)
          if deleted
            json_response(res, 200, { ok: true, deleted_count: 1, freed_size: deleted[:file_size].to_i })
          else
            json_response(res, 404, { ok: false, error: "File not found in trash: #{file_path}" })
          end
          return
        end

        # Mode 2 & 3: bulk empty (optionally scoped to one project, optionally by age)
        days_i = days_old.empty? ? 0 : days_old.to_i
        tool   = Clacky::Tools::TrashManager.new

        targets =
          if project_root
            [project_root]
          else
            Clacky::TrashDirectory.all_projects.map { |p| p[:project_root] }
          end

        total_deleted = 0
        total_freed   = 0
        targets.each do |root|
          result = tool.execute(action: "empty", days_old: days_i, working_dir: root)
          next unless result[:success]
          total_deleted += result[:deleted_count].to_i
          total_freed   += result[:freed_size].to_i
        end

        json_response(res, 200, {
          ok:            true,
          deleted_count: total_deleted,
          freed_size:    total_freed,
          days_old:      days_i
        })
      end

      # ── Trash helpers (private) ─────────────────────────────────────
      # Reads all metadata sidecars in `trash_dir` and returns enriched
      # file records. Silently skips sidecars whose payload file has
      # already been purged from disk.
      private def _trash_files_in(trash_dir, project_root)
        return [] unless trash_dir && Dir.exist?(trash_dir)

        files = []
        Dir.glob(File.join(trash_dir, "*.metadata.json")).each do |meta_path|
          begin
            meta  = JSON.parse(File.read(meta_path))
            trash = meta_path.sub(/\.metadata\.json\z/, "")
            next unless File.exist?(trash)
            files << {
              original_path: meta["original_path"],
              deleted_at:    meta["deleted_at"],
              deleted_by:    meta["deleted_by"],
              file_size:     meta["file_size"].to_i,
              file_type:     meta["file_type"],
              file_mode:     meta["file_mode"],
              trash_file:    trash
            }
          rescue StandardError
            # Corrupt or partial metadata — skip.
          end
        end
        files
      end

      # Permanently deletes the single trash entry whose original_path
      # matches inside `project_root`'s trash. Returns the removed
      # metadata hash, or nil if not found.
      private def _trash_delete_single(project_root, original_path)
        trash_dir = Clacky::TrashDirectory.new(project_root).trash_dir
        expanded  = File.expand_path(original_path, project_root)
        entry     = _trash_files_in(trash_dir, project_root).find do |f|
          f[:original_path] == expanded
        end
        return nil unless entry

        File.delete(entry[:trash_file])                       if File.exist?(entry[:trash_file])
        File.delete("#{entry[:trash_file]}.metadata.json")    if File.exist?("#{entry[:trash_file]}.metadata.json")
        entry
      rescue StandardError
        nil
      end

      # ── Profile API (USER.md / SOUL.md) ──────────────────────────────
      #
      # User can override the built-in defaults by writing their own
      # ~/.clacky/agents/USER.md and ~/.clacky/agents/SOUL.md. These
      # endpoints let the Web UI read and edit those files.

      PROFILE_USER_AGENTS_DIR  = File.expand_path("~/.clacky/agents").freeze
      PROFILE_DEFAULT_AGENTS_DIR = File.expand_path("../../default_agents", __dir__).freeze
      PROFILE_MAX_BYTES = 50_000  # Hard limit; prevents runaway content.

      # GET /api/profile
      # Returns { ok:, user: { path, content, is_default }, soul: { ... } }
      private def api_profile_get(res)
        json_response(res, 200, {
          ok:   true,
          user: _profile_read_file("USER.md"),
          soul: _profile_read_file("SOUL.md")
        })
      end

      # PUT /api/profile
      # Body: { kind: "user"|"soul", content: "..." }
      # Writes the file to ~/.clacky/agents/<KIND>.md. Empty content
      # deletes the override so the built-in default is used again.
      private def api_profile_put(req, res)
        data    = parse_json_body(req)
        kind    = data["kind"].to_s.downcase
        content = data["content"].to_s

        filename = case kind
                   when "user" then "USER.md"
                   when "soul" then "SOUL.md"
                   else
                     json_response(res, 400, { ok: false, error: "kind must be 'user' or 'soul'" })
                     return
                   end

        if content.bytesize > PROFILE_MAX_BYTES
          json_response(res, 413, { ok: false, error: "Content too large (max #{PROFILE_MAX_BYTES} bytes)" })
          return
        end

        FileUtils.mkdir_p(PROFILE_USER_AGENTS_DIR)
        target = File.join(PROFILE_USER_AGENTS_DIR, filename)

        # Treat whitespace-only payload as "reset to built-in default":
        # delete the override file so AgentProfile falls back to default.
        if content.strip.empty?
          File.delete(target) if File.exist?(target)
          json_response(res, 200, { ok: true, reset: true, file: _profile_read_file(filename) })
          return
        end

        File.write(target, content)
        json_response(res, 200, { ok: true, file: _profile_read_file(filename) })
      rescue StandardError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # Read a profile file — user override if present, else built-in default.
      # Returns { path:, content:, is_default:, writable: }.
      private def _profile_read_file(filename)
        user_path    = File.join(PROFILE_USER_AGENTS_DIR, filename)
        default_path = File.join(PROFILE_DEFAULT_AGENTS_DIR, filename)

        if File.exist?(user_path) && !File.zero?(user_path)
          {
            path:       user_path,
            content:    File.read(user_path),
            is_default: false
          }
        elsif File.exist?(default_path)
          {
            path:       default_path,
            content:    File.read(default_path),
            is_default: true
          }
        else
          {
            path:       user_path,  # Where it WILL be written
            content:    "",
            is_default: true
          }
        end
      rescue StandardError => e
        { path: "", content: "", is_default: true, error: e.message }
      end

      # ── Memories API (~/.clacky/memories/*.md) ───────────────────────
      #
      # Long-term memories are plain Markdown files with YAML frontmatter
      # stored under ~/.clacky/memories/. These endpoints let the user
      # inspect, edit, create, and delete them from the Web UI.

      MEMORIES_DIR    = File.expand_path("~/.clacky/memories").freeze
      MEMORY_MAX_BYTES = 50_000

      # GET /api/memories
      # Returns { ok:, dir:, memories: [ { filename, topic, description, updated_at, size, preview } ] }
      # Sorted by updated_at (YAML frontmatter) descending, falling back to file mtime.
      private def api_memories_list(res)
        FileUtils.mkdir_p(MEMORIES_DIR)
        memories = Dir.glob(File.join(MEMORIES_DIR, "*.md")).map do |path|
          _memory_summary(path)
        end.compact

        # Sort key: prefer updated_at string (ISO-ish sorts correctly), fall back to mtime.
        # `mtime` is always present in the summary (ISO 8601), so we use it as the
        # ultimate tiebreaker. Negate by reversing after sort for descending order.
        memories.sort_by! do |m|
          key = m[:updated_at].to_s
          key = m[:mtime].to_s if key.empty?
          key
        end
        memories.reverse!

        json_response(res, 200, { ok: true, dir: MEMORIES_DIR, memories: memories })
      end

      # GET /api/memories/:filename
      # Returns { ok:, filename:, path:, content: }
      private def api_memories_get(filename, res)
        safe = _memory_safe_filename(filename)
        unless safe
          json_response(res, 400, { ok: false, error: "Invalid filename" })
          return
        end
        path = File.join(MEMORIES_DIR, safe)
        unless File.exist?(path)
          json_response(res, 404, { ok: false, error: "Memory not found" })
          return
        end
        json_response(res, 200, {
          ok:       true,
          filename: safe,
          path:     path,
          content:  File.read(path)
        })
      end

      # POST /api/memories
      # Body: { filename: "topic.md", content: "..." }
      # Create a new memory file. Refuses to overwrite existing.
      private def api_memories_create(req, res)
        data     = parse_json_body(req)
        filename = _memory_safe_filename(data["filename"].to_s)
        content  = data["content"].to_s

        unless filename
          json_response(res, 400, { ok: false, error: "Invalid filename (must end in .md, no path separators)" })
          return
        end
        if content.bytesize > MEMORY_MAX_BYTES
          json_response(res, 413, { ok: false, error: "Content too large (max #{MEMORY_MAX_BYTES} bytes)" })
          return
        end

        FileUtils.mkdir_p(MEMORIES_DIR)
        path = File.join(MEMORIES_DIR, filename)
        if File.exist?(path)
          json_response(res, 409, { ok: false, error: "Memory '#{filename}' already exists" })
          return
        end

        File.write(path, content)
        json_response(res, 201, { ok: true, memory: _memory_summary(path) })
      rescue StandardError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # PUT /api/memories/:filename
      # Body: { content: "..." }
      private def api_memories_update(filename, req, res)
        safe = _memory_safe_filename(filename)
        unless safe
          json_response(res, 400, { ok: false, error: "Invalid filename" })
          return
        end
        data    = parse_json_body(req)
        content = data["content"].to_s
        if content.bytesize > MEMORY_MAX_BYTES
          json_response(res, 413, { ok: false, error: "Content too large (max #{MEMORY_MAX_BYTES} bytes)" })
          return
        end

        path = File.join(MEMORIES_DIR, safe)
        unless File.exist?(path)
          json_response(res, 404, { ok: false, error: "Memory not found" })
          return
        end

        File.write(path, content)
        json_response(res, 200, { ok: true, memory: _memory_summary(path) })
      rescue StandardError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # DELETE /api/memories/:filename
      private def api_memories_delete(filename, res)
        safe = _memory_safe_filename(filename)
        unless safe
          json_response(res, 400, { ok: false, error: "Invalid filename" })
          return
        end
        path = File.join(MEMORIES_DIR, safe)
        unless File.exist?(path)
          json_response(res, 404, { ok: false, error: "Memory not found" })
          return
        end
        File.delete(path)
        json_response(res, 200, { ok: true, filename: safe })
      rescue StandardError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # Returns nil if the filename is unsafe. Must end in .md, contain
      # no path separators or shell metacharacters, and be non-empty.
      private def _memory_safe_filename(name)
        s = name.to_s.strip
        return nil if s.empty?
        return nil if s.include?("/") || s.include?("\\")
        return nil if s.start_with?(".")
        return nil unless s.end_with?(".md")
        return nil unless s.match?(/\A[A-Za-z0-9._\-]+\z/)
        s
      end

      # Build a summary record for a memory file. Parses YAML frontmatter
      # if present; otherwise falls back to filename-derived topic.
      # Returns nil if the file can't be read.
      private def _memory_summary(path)
        content = File.read(path)
        stat    = File.stat(path)

        topic       = File.basename(path, ".md")
        description = ""
        updated_at  = stat.mtime.strftime("%Y-%m-%d")

        # Parse YAML frontmatter: --- ... --- at the top of the file.
        if content.start_with?("---")
          if (m = content.match(/\A---\s*\n(.*?)\n---\s*\n/m))
            begin
              # permitted_classes: Date so YAML `updated_at: 2026-05-01`
              # parses to a Date instance instead of raising DisallowedClass.
              fm = YAML.safe_load(m[1], permitted_classes: [Date, Time]) || {}
              topic       = fm["topic"].to_s       unless fm["topic"].to_s.strip.empty?
              description = fm["description"].to_s
              updated_at  = fm["updated_at"].to_s  unless fm["updated_at"].to_s.strip.empty?
            rescue StandardError
              # Bad frontmatter — fall back to defaults above.
            end
          end
        end

        preview = content.sub(/\A---.*?---\s*\n/m, "").strip[0, 200]

        {
          filename:    File.basename(path),
          path:        path,
          topic:       topic,
          description: description,
          updated_at:  updated_at,
          size:        stat.size,
          mtime:       stat.mtime.iso8601,
          preview:     preview
        }
      rescue StandardError
        nil
      end

      # Auto-packages the named skill directory into a ZIP and uploads it to the
      # OpenClacky cloud. No file picker is required — the server finds the skill
      # directory, zips it, and streams the ZIP to the cloud API.
      #
      # Response: { ok: true, name: } on success, { ok: false, error: } on failure.
      private def api_publish_my_skill(name, req, res)
        brand = Clacky::BrandConfig.load

        unless brand.user_licensed?
          json_response(res, 403, { ok: false, error: "User license required to publish skills" })
          return
        end

        # Reload skills to ensure we have latest state
        @skill_loader.load_all
        skill = @skill_loader[name]

        unless skill
          json_response(res, 404, { ok: false, error: "Skill '#{name}' not found" })
          return
        end

        source = @skill_loader.loaded_from[name]
        # Only allow publishing user-owned custom skills.
        # :default  — built-in gem skills (lib/clacky/default_skills/)
        # :brand    — encrypted brand/system skills from ~/.clacky/brand_skills/ (cannot re-upload)
        if source == :default || source == :brand
          json_response(res, 422, { ok: false, error: "Built-in system skills cannot be published" })
          return
        end

        skill_dir = skill.directory.to_s

        unless Dir.exist?(skill_dir)
          json_response(res, 422, { ok: false, error: "Skill directory not found: #{skill_dir}" })
          return
        end

        # Parse ?force=true query parameter for overwrite (re-upload existing skill via PATCH)
        query = URI.decode_www_form(req.query_string.to_s).to_h
        force = query["force"] == "true"

        begin
          require "zip"
          require "tmpdir"

          # Build ZIP in memory / temp file
          tmp_dir  = Dir.mktmpdir("clacky_skill_publish_")
          zip_path = File.join(tmp_dir, "#{name}.zip")

          # Directories and file patterns to exclude from the published ZIP.
          # These are generated/binary files that would cause server-side errors
          # (e.g., Python .pyc files contain null bytes rejected by PostgreSQL).
          excluded_dirs     = %w[__pycache__ .git .svn node_modules .cache]
          excluded_patterns = /\.(pyc|rbc|class|o|so|dylib|dll|exe)$|\.DS_Store$|Thumbs\.db$/i

          Zip::OutputStream.open(zip_path) do |zos|
            Dir.glob("**/*", base: skill_dir).sort.each do |rel|
              full = File.join(skill_dir, rel)
              next if File.directory?(full)

              # Skip excluded directories anywhere in path
              path_parts = rel.split(File::SEPARATOR)
              next if path_parts.any? { |part| excluded_dirs.include?(part) }

              # Skip excluded file patterns (compiled bytecode, shared libs, OS files)
              next if rel.match?(excluded_patterns)

              entry_name = "#{name}/#{rel}"
              zos.put_next_entry(entry_name)
              zos.write(File.binread(full))
            end
          end

          zip_data = File.binread(zip_path)

          # Upload to cloud API as multipart (force=true uses PATCH for overwrite)
          result = brand.upload_skill!(name, zip_data, force: force)

          if result[:success]
            # Record the platform version returned by the server
            platform_version = result.dig(:skill, "version")
            Clacky::BrandConfig.record_upload!(name, platform_version) if platform_version
            json_response(res, 200, { ok: true, name: name, platform_version: platform_version })
          else
            # Pass already_exists flag so the frontend can offer an overwrite prompt
            json_response(res, 422, {
              ok:             false,
              error:          result[:error],
              already_exists: result[:already_exists] || false
            })
          end
        rescue StandardError, ScriptError => e
          json_response(res, 500, { ok: false, error: e.message })
        ensure
          FileUtils.rm_rf(tmp_dir) if tmp_dir && Dir.exist?(tmp_dir)
        end
      end

      # ── Config API ────────────────────────────────────────────────────────────

      # GET /api/config — return current model configurations
      def api_get_config(res)
        models = @agent_config.models.map.with_index do |m, i|
          {
            id:               m["id"],   # Stable runtime id — use this for switching
            index:            i,
            model:            m["model"],
            base_url:         m["base_url"],
            api_key_masked:   mask_api_key(m["api_key"]),
            anthropic_format: m["anthropic_format"] || false,
            type:             m["type"]
          }
        end
        # Filter out auto-injected models (like lite) from UI display
        models.reject! { |m| @agent_config.models[m[:index]]["auto_injected"] }
        json_response(res, 200, {
          models: models,
          current_index: @agent_config.current_model_index,
          current_id: @agent_config.current_model&.dig("id")
        })
      end

      # POST /api/config — save updated model list
      # DEPRECATED: this endpoint previously accepted the entire models array
      # and replaced @models in place. That design was fragile — any missing
      # or stale field on ANY row could wipe other rows' api_keys. It has
      # been removed in favour of single-item RESTful endpoints below:
      #   POST   /api/config/models              — add one model
      #   PATCH  /api/config/models/:id          — update one model
      #   DELETE /api/config/models/:id          — remove one model
      #   POST   /api/config/models/:id/default  — set one model as default
      #
      # Each handler only touches the single targeted entry, so a bug in any
      # one call can never corrupt unrelated models. Front-end code must
      # never send "the whole list" anymore.

      # POST /api/config/models
      # Body: { model, base_url, api_key, anthropic_format, type? }
      # Creates a new model entry, returns { ok:true, id, index } so the
      # frontend can record the new id without reloading the whole list.
      def api_add_model(req, res)
        body = parse_json_body(req)
        return json_response(res, 400, { error: "Invalid JSON" }) unless body

        model    = body["model"].to_s.strip
        base_url = body["base_url"].to_s.strip
        api_key  = body["api_key"].to_s
        # Masked placeholders are never a valid api_key on creation —
        # a brand-new model MUST come with a real key.
        if api_key.empty? || api_key.include?("****")
          return json_response(res, 422, { error: "api_key is required" })
        end

        entry = {
          "id"               => SecureRandom.uuid,
          "model"            => model,
          "base_url"         => base_url,
          "api_key"          => api_key,
          "anthropic_format" => body["anthropic_format"] || false
        }
        type = body["type"].to_s
        unless type.empty?
          # Preserve the single-slot "default" invariant.
          if type == "default"
            @agent_config.models.each { |m| m.delete("type") if m["type"] == "default" }
          end
          entry["type"] = type
        end

        @agent_config.models << entry
        # If this is the only model and no default marker exists yet,
        # adopt it as the default so downstream lookups resolve cleanly.
        if @agent_config.models.none? { |m| m["type"] == "default" }
          entry["type"] = "default"
          @agent_config.current_model_id    = entry["id"]
          @agent_config.current_model_index = @agent_config.models.length - 1
        elsif type == "default"
          # Re-anchor current_* to the newly-defaulted entry.
          @agent_config.current_model_id    = entry["id"]
          @agent_config.current_model_index = @agent_config.models.length - 1
        end

        @agent_config.save
        json_response(res, 200, {
          ok:    true,
          id:    entry["id"],
          index: @agent_config.models.length - 1
        })
      rescue => e
        json_response(res, 422, { error: e.message })
      end

      # PATCH /api/config/models/:id
      # Body: any subset of { model, base_url, api_key, anthropic_format, type }
      # Rules (the whole reason we moved off bulk save):
      #   - Missing key  → field untouched
      #   - api_key with "****" (masked display value) → IGNORED (never overwrites)
      #   - api_key empty string → IGNORED (defensive; treat as "not changed")
      #   - api_key real non-masked value → stored
      #   - type="default" transparently clears the marker on other models
      #   - Unknown id → 404
      def api_update_model(id, req, res)
        body = parse_json_body(req)
        return json_response(res, 400, { error: "Invalid JSON" }) unless body

        target = @agent_config.models.find { |m| m["id"] == id }
        return json_response(res, 404, { error: "model not found" }) unless target

        if body.key?("model")
          v = body["model"].to_s.strip
          target["model"] = v unless v.empty?
        end
        if body.key?("base_url")
          v = body["base_url"].to_s.strip
          target["base_url"] = v unless v.empty?
        end
        if body.key?("anthropic_format")
          target["anthropic_format"] = !!body["anthropic_format"]
        end
        if body.key?("api_key")
          new_key = body["api_key"].to_s
          # Only store a real, unmasked, non-empty value. This is the
          # single place the "api_key disappeared" bug can no longer
          # happen — there is no path that writes "" into api_key.
          if !new_key.empty? && !new_key.include?("****")
            target["api_key"] = new_key
          end
        end
        if body.key?("type")
          new_type = body["type"]
          new_type = nil if new_type.is_a?(String) && new_type.strip.empty?
          if new_type == "default"
            @agent_config.models.each do |m|
              next if m["id"] == id
              m.delete("type") if m["type"] == "default"
            end
            target["type"] = "default"
            @agent_config.current_model_id    = target["id"]
            @agent_config.current_model_index = @agent_config.models.find_index { |m| m["id"] == id } || 0
          elsif new_type.nil?
            target.delete("type")
          else
            target["type"] = new_type
          end
        end

        @agent_config.save
        json_response(res, 200, { ok: true })
      rescue => e
        json_response(res, 422, { error: e.message })
      end

      # DELETE /api/config/models/:id
      def api_delete_model(id, res)
        models = @agent_config.models
        return json_response(res, 404, { error: "model not found" }) unless models.any? { |m| m["id"] == id }
        return json_response(res, 422, { error: "cannot delete the last model" }) if models.length <= 1

        index = models.find_index { |m| m["id"] == id }
        removed = models.delete_at(index)

        # Re-anchor current_* if we just deleted the active model.
        if @agent_config.current_model_id == removed["id"]
          new_default = models.find { |m| m["type"] == "default" } || models.first
          # If the removed model was the default, promote the new current
          # model so the config always has exactly one default entry.
          if removed["type"] == "default" && new_default && new_default["type"] != "default"
            new_default["type"] = "default"
          end
          @agent_config.current_model_id    = new_default["id"]
          @agent_config.current_model_index = models.find_index { |m| m["id"] == new_default["id"] } || 0
        elsif @agent_config.current_model_index >= models.length
          @agent_config.current_model_index = models.length - 1
        end

        @agent_config.save
        json_response(res, 200, { ok: true })
      rescue => e
        json_response(res, 422, { error: e.message })
      end

      # POST /api/config/models/:id/default
      # Makes the identified model the new "default" (global initial model
      # for new sessions AND current model for this server instance).
      def api_set_default_model(id, res)
        ok = @agent_config.set_default_model_by_id(id)
        return json_response(res, 404, { error: "model not found" }) unless ok

        @agent_config.current_model_id    = id
        @agent_config.current_model_index = @agent_config.models.find_index { |m| m["id"] == id } || 0
        @agent_config.save
        json_response(res, 200, { ok: true })
      rescue => e
        json_response(res, 422, { error: e.message })
      end

      # POST /api/config/test — test connection for a single model config
      # Body: { model, base_url, api_key, anthropic_format }
      def api_test_config(req, res)
        body = parse_json_body(req)
        return json_response(res, 400, { error: "Invalid JSON" }) unless body

        api_key = body["api_key"].to_s
        # If masked, use the stored key from the matching model (by index or current)
        if api_key.include?("****")
          idx = body["index"]&.to_i || @agent_config.current_model_index
          api_key = @agent_config.models.dig(idx, "api_key").to_s
        end

        begin
          model = body["model"].to_s
          test_client = Clacky::Client.new(
            api_key,
            base_url:         body["base_url"].to_s,
            model:            model,
            anthropic_format: body["anthropic_format"] || false
          )
          result = test_client.test_connection(model: model)
          if result[:success]
            json_response(res, 200, { ok: true, message: "Connected successfully" })
          else
            json_response(res, 200, { ok: false, message: result[:error].to_s })
          end
        rescue => e
          json_response(res, 200, { ok: false, message: e.message })
        end
      end

      # GET /api/providers — return built-in provider presets for quick setup
      def api_list_providers(res)
        providers = Clacky::Providers::PRESETS.map do |id, preset|
          {
            id:            id,
            name:          preset["name"],
            base_url:      preset["base_url"],
            default_model: preset["default_model"],
            models:        preset["models"] || [],
            website_url:   preset["website_url"]
          }
        end
        json_response(res, 200, { providers: providers })
      end

      # GET /api/sessions/:id/messages?limit=20&before=1709123456.789
      # Replays conversation history for a session via the agent's replay_history method.
      # Returns a list of UI events (same format as WS events) for the frontend to render.
      def api_session_messages(session_id, req, res)
        unless @registry.ensure(session_id)
          Clacky::Logger.warn("[messages] registry.ensure failed", session_id: session_id)
          return json_response(res, 404, { error: "Session not found" })
        end

        # Parse query params
        query   = URI.decode_www_form(req.query_string.to_s).to_h
        limit   = [query["limit"].to_i.then { |n| n > 0 ? n : 20 }, 100].min
        before  = query["before"]&.to_f

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }

        unless agent
          Clacky::Logger.warn("[messages] agent is nil", session_id: session_id)
          return json_response(res, 200, { events: [], has_more: false })
        end

        # Collect events emitted by replay_history via a lightweight collector UI
        collected = []
        collector = HistoryCollector.new(session_id, collected)
        result    = agent.replay_history(collector, limit: limit, before: before)

        json_response(res, 200, { events: collected, has_more: result[:has_more] })
      end

      def api_rename_session(session_id, req, res)
        body = parse_json_body(req)
        new_name = body["name"]&.to_s&.strip
        pinned = body["pinned"]

        return json_response(res, 404, { error: "Session not found" }) unless @registry.ensure(session_id)

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }
        
        # Update name if provided
        if new_name && !new_name.empty?
          agent.rename(new_name)
        end
        
        # Update pinned status if provided
        if !pinned.nil?
          agent.pinned = pinned
        end
        
        # Save session data
        @session_manager.save(agent.to_session_data)
        
        # Broadcast update event
        update_data = { type: "session_updated", session_id: session_id }
        update_data[:name] = new_name if new_name && !new_name.empty?
        update_data[:pinned] = pinned unless pinned.nil?
        broadcast(session_id, update_data)
        
        response_data = { ok: true }
        response_data[:name] = new_name if new_name && !new_name.empty?
        response_data[:pinned] = pinned unless pinned.nil?
        json_response(res, 200, response_data)
      rescue => e
        json_response(res, 500, { error: e.message })
      end

      def api_switch_session_model(session_id, req, res)
        body = parse_json_body(req)
        model_id = body["model_id"].to_s.strip

        return json_response(res, 400, { error: "model_id is required" }) if model_id.empty?
        return json_response(res, 404, { error: "Session not found" }) unless @registry.ensure(session_id)

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }

        # With Plan B (shared @models reference), every session's AgentConfig
        # points at the same @models array as the global @agent_config. So
        # resolving the model by stable id here and in agent.switch_model_by_id
        # will always agree — no more index divergence after add/delete.
        target_model = @agent_config.models.find { |m| m["id"] == model_id }
        if target_model.nil?
          return json_response(res, 400, { error: "Model not found in configuration" })
        end

        # Switch to the model by id (unified interface with CLI)
        # Handles: config.switch_model_by_id + client rebuild + message_compressor rebuild
        success = agent.switch_model_by_id(model_id)

        unless success
          return json_response(res, 500, { error: "Failed to switch model" })
        end

        # Persist the change (saves to session file, NOT global config.yml)
        @session_manager.save(agent.to_session_data)

        # Broadcast update to all clients
        broadcast_session_update(session_id)

        json_response(res, 200, { ok: true, model_id: model_id, model: target_model["model"] })
      rescue => e
        json_response(res, 500, { error: e.message })
      end

      # POST /api/sessions/:id/benchmark
      #
      # Speed-test every configured model in one shot so the user can pick the
      # fastest available model for this session. We send a minimal one-token
      # request to each model *in parallel* (one thread per model) and measure
      # total HTTP duration — for non-streaming calls this equals the user's
      # perceived time-to-first-token, so the field is named `ttft_ms` for
      # forward-compatibility with a future streaming implementation.
      #
      # Cost note: each request is `max_tokens: 1` + a 2-byte prompt, so the
      # total cost across a dozen models is well under one cent.
      #
      # Response shape:
      #   {
      #     ok: true,
      #     results: [
      #       { model_id: "...", model: "...", ttft_ms: 812, ok: true },
      #       { model_id: "...", model: "...", ok: false, error: "timeout" },
      #       ...
      #     ]
      #   }
      def api_benchmark_session_models(session_id, _req, res)
        return json_response(res, 404, { error: "Session not found" }) unless @registry.ensure(session_id)

        # Snapshot the models list — @agent_config.models is a shared reference
        # that the user might mutate from the settings panel during the test;
        # a shallow dup is enough since we only read string fields below.
        models = Array(@agent_config.models).dup
        return json_response(res, 200, { ok: true, results: [] }) if models.empty?

        # Kick off one thread per model. We deliberately cap per-request wall
        # time inside each thread via a Faraday timeout so a single dead model
        # can't block the response. The outer join uses a generous ceiling
        # (timeout + small buffer) as a last-resort safety net.
        per_model_timeout = 15
        threads = models.map do |m|
          Thread.new do
            Thread.current.report_on_exception = false
            benchmark_single_model(m, per_model_timeout)
          end
        end

        results = threads.map do |t|
          t.join(per_model_timeout + 3)
          t.value rescue { ok: false, error: "thread failed" }
        end

        json_response(res, 200, { ok: true, results: results })
      rescue => e
        Clacky::Logger.error("[benchmark] #{e.class}: #{e.message}", error: e)
        json_response(res, 500, { error: e.message })
      end

      # Runs one speed-test request against a single model config hash and
      # returns a result row for api_benchmark_session_models. Pure function —
      # no shared state — so it's safe to call from worker threads.
      private def benchmark_single_model(model_cfg, timeout_sec)
        model_id   = model_cfg["id"].to_s
        model_name = model_cfg["model"].to_s
        base       = { model_id: model_id, model: model_name }

        client = Clacky::Client.new(
          model_cfg["api_key"].to_s,
          base_url:         model_cfg["base_url"].to_s,
          model:            model_name,
          anthropic_format: model_cfg["anthropic_format"] || false
        )

        # Override Faraday timeouts via a short-lived env var isn't ideal;
        # instead we rely on test_connection's own network path and wrap
        # the call in Timeout as a last line of defence. Most providers
        # respond within 2-3s for a 16-token reply.
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = nil
        begin
          Timeout.timeout(timeout_sec) { result = client.test_connection(model: model_name) }
        rescue Timeout::Error
          return base.merge(ok: false, error: "timeout after #{timeout_sec}s")
        end
        t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        if result && result[:success]
          base.merge(ok: true, ttft_ms: ((t1 - t0) * 1000).round)
        else
          base.merge(ok: false, error: (result && result[:error]).to_s[0, 200])
        end
      rescue => e
        base.merge(ok: false, error: "#{e.class}: #{e.message}"[0, 200])
      end


      def api_change_session_working_dir(session_id, req, res)
        body = parse_json_body(req)
        new_dir = body["working_dir"].to_s.strip

        return json_response(res, 400, { error: "working_dir is required" }) if new_dir.empty?
        return json_response(res, 404, { error: "Session not found" }) unless @registry.ensure(session_id)

        # Expand ~ to home directory
        expanded_dir = File.expand_path(new_dir)
        
        # Validate directory exists
        unless Dir.exist?(expanded_dir)
          return json_response(res, 400, { error: "Directory does not exist: #{expanded_dir}" })
        end

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }
        
        # Change the agent's working directory
        agent.change_working_dir(expanded_dir)
        
        # Persist the change
        @session_manager.save(agent.to_session_data)
        
        # Broadcast update to all clients
        broadcast_session_update(session_id)
        
        json_response(res, 200, { ok: true, working_dir: expanded_dir })
      rescue => e
        json_response(res, 500, { error: e.message })
      end

      def api_delete_session(session_id, res)
        # A session exists if it's either in the runtime registry OR on disk.
        # Old sessions that were never restored into memory this server run
        # (e.g. shown via "load more" in the WebUI list) are disk-only — we
        # must still be able to delete them. Previously this endpoint only
        # consulted @registry and returned 404 for disk-only sessions,
        # causing the "can't delete old sessions" bug.
        in_registry = @registry.exist?(session_id)
        on_disk     = !@session_manager.load(session_id).nil?

        unless in_registry || on_disk
          return json_response(res, 404, { error: "Session not found" })
        end

        # Registry delete is best-effort — only meaningful when the session
        # is actually live (cancels idle timer, interrupts the agent thread).
        # For disk-only sessions this is a no-op and returns false, which is
        # fine and no longer blocks the disk cleanup below.
        @registry.delete(session_id) if in_registry

        # Always physically remove the persisted session file (+ chunks).
        @session_manager.delete(session_id) if on_disk

        # Notify any still-connected clients (mainly matters when the
        # session was live, but harmless otherwise).
        broadcast(session_id, { type: "session_deleted", session_id: session_id })
        unsubscribe_all(session_id)

        json_response(res, 200, { ok: true })
      end

      # Export a session bundle as a .zip download containing:
      #   - session.json          (always)
      #   - chunk-*.md            (0..N archived conversation chunks)
      # Useful for debugging — user clicks "download" in the WebUI status bar
      # and we can ask them to attach the zip to a bug report.
      def api_export_session(session_id, res)
        bundle = @session_manager.files_for(session_id)
        unless bundle
          return json_response(res, 404, { error: "Session not found" })
        end

        require "zip"

        short_id = bundle[:session][:session_id].to_s[0..7]
        # Build the zip entirely in memory — session files are small (< few MB).
        buffer = Zip::OutputStream.write_buffer do |zos|
          zos.put_next_entry("session.json")
          zos.write(File.binread(bundle[:json_path]))

          bundle[:chunks].each do |chunk_path|
            # Preserve original chunk filename so the ordering (chunk-1.md, chunk-2.md, ...) is clear.
            zos.put_next_entry(File.basename(chunk_path))
            zos.write(File.binread(chunk_path))
          end
        end
        buffer.rewind
        data = buffer.read

        filename = "clacky-session-#{short_id}.zip"
        res.status = 200
        res.content_type = "application/zip"
        res["Content-Disposition"] = %(attachment; filename="#{filename}")
        res["Access-Control-Allow-Origin"] = "*"
        # Force a fresh copy each time — debugging sessions get new chunks over time.
        res["Cache-Control"] = "no-store"
        res.body = data
      rescue => e
        Clacky::Logger.error("Session export failed: #{e.message}") if defined?(Clacky::Logger)
        json_response(res, 500, { error: "Export failed: #{e.message}" })
      end

      # ── WebSocket ─────────────────────────────────────────────────────────────

      def websocket_upgrade?(req)
        req["Upgrade"]&.downcase == "websocket"
      end

      # Hijacks the TCP socket from WEBrick and upgrades it to WebSocket.
      def handle_websocket(req, res)
        socket = req.instance_variable_get(:@socket)

        # Server handshake — parse the upgrade request
        handshake = WebSocket::Handshake::Server.new
        handshake << build_handshake_request(req)
        unless handshake.finished? && handshake.valid?
          Clacky::Logger.warn("WebSocket handshake invalid")
          return
        end

        # Send the 101 Switching Protocols response
        socket.write(handshake.to_s)

        version  = handshake.version
        incoming = WebSocket::Frame::Incoming::Server.new(version: version)
        conn     = WebSocketConnection.new(socket, version)

        on_ws_open(conn)

        begin
          buf = String.new("", encoding: "BINARY")
          loop do
            chunk = socket.read_nonblock(4096, buf, exception: false)
            case chunk
            when :wait_readable
              IO.select([socket], nil, nil, 30)
            when nil
              break  # EOF
            else
              incoming << chunk.dup
              while (frame = incoming.next)
                case frame.type
                when :text
                  on_ws_message(conn, frame.data)
                when :binary
                  on_ws_message(conn, frame.data)
                when :ping
                  conn.send_raw(:pong, frame.data)
                when :close
                  conn.send_raw(:close, "")
                  break
                end
              end
            end
          end
        rescue IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::EBADF
          # Client disconnected or socket became invalid
        ensure
          on_ws_close(conn)
          socket.close rescue nil
        end

        # Tell WEBrick not to send any response (we handled everything)
        res.instance_variable_set(:@header, {})
        res.status = -1
      rescue => e
        Clacky::Logger.error("WebSocket handler error: #{e.class}: #{e.message}")
      end

      # Build a raw HTTP request string from WEBrick request for WebSocket::Handshake::Server
      private def build_handshake_request(req)
        lines = ["#{req.request_method} #{req.request_uri.request_uri} HTTP/1.1\r\n"]
        req.each { |k, v| lines << "#{k}: #{v}\r\n" }
        lines << "\r\n"
        lines.join
      end

      def on_ws_open(conn)
        @ws_mutex.synchronize { @all_ws_conns << conn }
        # Client will send a "subscribe" message to bind to a session
      end

      def on_ws_message(conn, raw)
        msg = JSON.parse(raw)
        type = msg["type"]

        case type
        when "subscribe"
          session_id = msg["session_id"]
          if @registry.ensure(session_id)
            conn.session_id = session_id
            subscribe(session_id, conn)
            conn.send_json(type: "subscribed", session_id: session_id)
            # If a shell command is still running, replay progress + buffered stdout
            # to the newly subscribed tab so it sees the live state it may have missed.
            @registry.with_session(session_id) { |s| s[:ui]&.replay_live_state }
          else
            conn.send_json(type: "error", message: "Session not found: #{session_id}")
          end

        when "message"
          session_id = msg["session_id"] || conn.session_id
          # Merge legacy images array into files as { data_url:, name:, mime_type: } entries
          raw_images = (msg["images"] || []).map do |data_url|
            { "data_url" => data_url, "name" => "image.jpg", "mime_type" => "image/jpeg" }
          end
          handle_user_message(session_id, msg["content"].to_s, (msg["files"] || []) + raw_images)

        when "confirmation"
          session_id = msg["session_id"] || conn.session_id
          deliver_confirmation(session_id, msg["id"], msg["result"])

        when "interrupt"
          session_id = msg["session_id"] || conn.session_id
          interrupt_session(session_id)

        when "list_sessions"
          # Initial load: newest 20 sessions regardless of source/profile.
          # Single unified query — frontend shows all in one time-sorted list.
          page = @registry.list(limit: 21)
          has_more = page.size > 20
          all_sessions = page.first(20)
          conn.send_json(type: "session_list", sessions: all_sessions, has_more: has_more)

        when "run_task"
          # Client sends this after subscribing to guarantee it's ready to receive
          # broadcasts before the agent starts executing.
          session_id = msg["session_id"] || conn.session_id
          start_pending_task(session_id)

        when "ping"
          conn.send_json(type: "pong")

        else
          conn.send_json(type: "error", message: "Unknown message type: #{type}")
        end
      rescue JSON::ParserError => e
        conn.send_json(type: "error", message: "Invalid JSON: #{e.message}")
      rescue => e
        Clacky::Logger.error("[on_ws_message] #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
        conn.send_json(type: "error", message: e.message)
      end

      def on_ws_close(conn)
        @ws_mutex.synchronize { @all_ws_conns.delete(conn) }
        unsubscribe(conn)
      end

      # ── Session actions ───────────────────────────────────────────────────────

      def handle_user_message(session_id, content, files = [])
        return unless @registry.exist?(session_id)

        session = @registry.get(session_id)
        
        # If session is running, interrupt it first (mimics CLI behavior)
        if session[:status] == :running
          interrupt_session(session_id)
          # Wait briefly for the thread to catch the interrupt and update status
          # This ensures the agent loop exits cleanly before starting the new task
          sleep 0.1
        end

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }
        return unless agent

        # Auto-name the session from the first user message (before agent starts running).
        # Check messages.empty? only — agent.name may already hold a default placeholder
        # like "Session 1" assigned at creation time, so it's not a reliable signal.
        if agent.history.empty?
          auto_name = content.gsub(/\s+/, " ").strip[0, 30]
          auto_name += "…" if content.strip.length > 30
          agent.rename(auto_name)
          broadcast(session_id, { type: "session_renamed", session_id: session_id, name: auto_name })
        end

        # Broadcast user message through web_ui so channel subscribers (飞书/企微) receive it.
        web_ui = nil
        @registry.with_session(session_id) { |s| web_ui = s[:ui] }
        web_ui&.show_user_message(content, source: :web)

        # File references are now handled inside agent.run — injected as a system_injected
        # message after the user message, so replay_history skips them automatically.
        run_agent_task(session_id, agent) { agent.run(content, files: files) }
      end

      def deliver_confirmation(session_id, conf_id, result)
        ui = nil
        @registry.with_session(session_id) { |s| ui = s[:ui] }
        ui&.deliver_confirmation(conf_id, result)
      end

      def interrupt_session(session_id)
        @registry.with_session(session_id) do |s|
          s[:idle_timer]&.cancel
          s[:thread]&.raise(Clacky::AgentInterrupted, "Interrupted by user")
        end
      end

      # Start the pending task for a session.
      # Called when the client sends "run_task" over WS — by that point the
      # client has already subscribed, so every broadcast will be delivered.
      def start_pending_task(session_id)
        return unless @registry.exist?(session_id)

        session = @registry.get(session_id)
        prompt      = session[:pending_task]
        working_dir = session[:pending_working_dir]
        return unless prompt  # nothing pending

        # Clear the pending fields so a re-connect doesn't re-run
        @registry.update(session_id, pending_task: nil, pending_working_dir: nil)

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }
        return unless agent

        run_agent_task(session_id, agent) { agent.run(prompt) }
      end

      # Run an agent task in a background thread, handling status updates,
      # session persistence, and idle compression timer lifecycle.
      # Yields to the caller to perform the actual agent.run call.
      private def run_agent_task(session_id, agent, &task)
        idle_timer = nil
        @registry.with_session(session_id) { |s| idle_timer = s[:idle_timer] }

        # Cancel any pending idle compression before starting a new task
        idle_timer&.cancel

        @registry.update(session_id, status: :running)
        broadcast_session_update(session_id)

        thread = Thread.new do
          task.call
          @registry.update(session_id, status: :idle, error: nil)
          broadcast_session_update(session_id)
          @session_manager.save(agent.to_session_data(status: :success))
          # Start idle compression timer now that the agent is idle
          idle_timer&.start
        rescue Clacky::AgentInterrupted
          @registry.update(session_id, status: :idle)
          broadcast_session_update(session_id)
          broadcast(session_id, { type: "interrupted", session_id: session_id })
          @session_manager.save(agent.to_session_data(status: :interrupted))
        rescue => e
          @registry.update(session_id, status: :error, error: e.message)
          broadcast_session_update(session_id)
          # Route error through web_ui so channel subscribers (飞书/企微) receive it too.
          web_ui = nil
          @registry.with_session(session_id) { |s| web_ui = s[:ui] }
          web_ui&.show_error(e.message)
          @session_manager.save(agent.to_session_data(status: :error, error_message: e.message))
        end
        @registry.with_session(session_id) { |s| s[:thread] = thread }
      end

      # ── WebSocket subscription management ─────────────────────────────────────

      def subscribe(session_id, conn)
        @ws_mutex.synchronize do
          # Remove conn from any previous session subscription first,
          # so switching sessions never results in duplicate delivery.
          @ws_clients.each_value { |list| list.delete(conn) }
          @ws_clients[session_id] ||= []
          @ws_clients[session_id] << conn unless @ws_clients[session_id].include?(conn)
        end
      end

      def unsubscribe(conn)
        @ws_mutex.synchronize do
          @ws_clients.each_value { |list| list.delete(conn) }
        end
      end

      def unsubscribe_all(session_id)
        @ws_mutex.synchronize { @ws_clients.delete(session_id) }
      end

      # Broadcast an event to all clients subscribed to a session.
      # Dead connections (broken pipe / closed socket) are removed automatically.
      def broadcast(session_id, event)
        clients = @ws_mutex.synchronize { (@ws_clients[session_id] || []).dup }
        dead = clients.reject { |conn| conn.send_json(event) }
        return if dead.empty?

        @ws_mutex.synchronize do
          (@ws_clients[session_id] || []).reject! { |conn| dead.include?(conn) }
        end
      end

      # Broadcast an event to every connected client (regardless of session subscription).
      # Dead connections are removed automatically.
      def broadcast_all(event)
        clients = @ws_mutex.synchronize { @all_ws_conns.dup }
        dead = clients.reject { |conn| conn.send_json(event) }
        return if dead.empty?

        @ws_mutex.synchronize do
          @all_ws_conns.reject! { |conn| dead.include?(conn) }
          @ws_clients.each_value { |list| list.reject! { |conn| dead.include?(conn) } }
        end
      end

      # Broadcast a session_update event to all clients so they can patch their
      # local session list without needing a full session_list refresh.
      def broadcast_session_update(session_id)
        session = @registry.list(limit: 200).find { |s| s[:id] == session_id }
        return unless session

        broadcast_all(type: "session_update", session: session)
      end

      # ── Helpers ───────────────────────────────────────────────────────────────

      def default_working_dir
        File.expand_path("~/clacky_workspace")
      end

      # Create a session in the registry and wire up Agent + WebUIController.
      # Returns the new session_id.
      # Build a new agent session.
      # @param name [String] display name for the session
      # @param working_dir [String] working directory for the agent
      # @param permission_mode [Symbol] :confirm_all (default, human present) or
      #   :auto_approve (unattended — suppresses request_user_feedback waits)
      def build_session(name:, working_dir:, permission_mode: :confirm_all, profile: "general", source: :manual, model_id: nil)
        session_id = Clacky::SessionManager.generate_id
        @registry.create(session_id: session_id)

        config = @agent_config.deep_copy
        config.permission_mode = permission_mode

        # Apply model override BEFORE creating the client — otherwise the
        # client is built from the default model entry and may route through
        # the wrong provider (e.g. sending a deepseek-v4-pro request to the
        # Bedrock-format OpenClacky endpoint, which replies "unknown model").
        #
        # We use switch_model_by_id (not a name-based rewrite of
        # current_model["model"]) because:
        #   1. Ids uniquely identify an entry across providers; names can
        #      collide between entries (deepseek vs dsk-deepseek aliases).
        #   2. switch_model_by_id only flips per-session @current_model_id
        #      in the dup'd config — it never mutates the shared @models
        #      array (see AgentConfig#deep_copy's shared-ref contract).
        #      A name rewrite would have leaked into every live session
        #      AND corrupted the on-disk config at next save.
        config.switch_model_by_id(model_id) if model_id

        # Build client from the (possibly overridden) config so api format
        # detection (Bedrock vs OpenAI vs Anthropic) uses the correct model.
        client = Clacky::Client.new(
          config.api_key,
          base_url: config.base_url,
          model: config.model_name,
          anthropic_format: config.anthropic_format?
        )

        broadcaster = method(:broadcast)
        ui = WebUIController.new(session_id, broadcaster)
        agent = Clacky::Agent.new(client, config, working_dir: working_dir, ui: ui, profile: profile,
                                  session_id: session_id, source: source)
        agent.rename(name) unless name.nil? || name.empty?
        idle_timer = build_idle_timer(session_id, agent)

        @registry.with_session(session_id) do |s|
          s[:agent]      = agent
          s[:ui]         = ui
          s[:idle_timer] = idle_timer
        end

        # Persist an initial snapshot so the session is immediately visible in registry.list
        # (which reads from disk). Without this, new sessions only appear after their first task.
        @session_manager.save(agent.to_session_data)

        session_id
      end

      # Restore a persisted session from saved session_data (from SessionManager).
      # The agent keeps its original session_id so the frontend URL hash stays valid
      # across server restarts.
      def build_session_from_data(session_data, permission_mode: :confirm_all)
        original_id = session_data[:session_id]

        client = @client_factory.call
        config = @agent_config.deep_copy
        config.permission_mode = permission_mode
        broadcaster = method(:broadcast)
        ui = WebUIController.new(original_id, broadcaster)
        # Restore the agent profile from the persisted session; fall back to "general"
        # for sessions saved before the agent_profile field was introduced.
        profile = session_data[:agent_profile].to_s
        profile = "general" if profile.empty?
        agent = Clacky::Agent.from_session(client, config, session_data, ui: ui, profile: profile)
        idle_timer = build_idle_timer(original_id, agent)

        # Register session atomically with a fully-built agent so no concurrent
        # caller ever sees agent=nil for this session. The duplicate-restore guard
        # is handled upstream by SessionRegistry#ensure via @restoring.
        @registry.create(session_id: original_id)
        @registry.with_session(original_id) do |s|
          s[:agent]      = agent
          s[:ui]         = ui
          s[:idle_timer] = idle_timer
        end

        original_id
      end

      # Build an IdleCompressionTimer for a session.
      # Broadcasts session_update after successful compression so clients see the new cost.
      private def build_idle_timer(session_id, agent)
        Clacky::IdleCompressionTimer.new(
          agent:           agent,
          session_manager: @session_manager
        ) do |_success|
          broadcast_session_update(session_id)
        end
      end

      # Mask API key for display: show first 8 + last 4 chars, middle replaced with ****
      # Mask an api_key for safe display / transport to the browser.
      #
      # Contract: the returned string MUST contain "****" so callers (incl.
      # the frontend) can reliably detect "this is a display placeholder,
      # not a real key" and refuse to treat it as input. The old behaviour
      # of returning the raw value for short keys was a correctness bug —
      # it leaked short keys in plaintext to GET /api/config, and it let
      # short masked values slip past the frontend's mask-detection.
      def mask_api_key(key)
        return "" if key.nil? || key.empty?
        if key.length <= 12
          # Very short key — show the first char only, redact the rest.
          return "#{key[0]}****"
        end
        "#{key[0..7]}****#{key[-4..]}"
      end

      def json_response(res, status, data)
        res.status       = status
        res.content_type = "application/json; charset=utf-8"
        res["Access-Control-Allow-Origin"] = "*"
        res.body = JSON.generate(data)
      end

      def parse_json_body(req)
        return {} if req.body.nil? || req.body.empty?

        JSON.parse(req.body)
      rescue JSON::ParserError
        {}
      end

      # Parse a multipart/form-data request body to extract a single file upload.
      # Returns { filename:, data: } or nil when the field is not found.
      # This is a lightweight parser that handles the standard WEBrick multipart format.
      #
      # @param req [WEBrick::HTTPRequest]
      # @param field_name [String] The form field name to look for
      # @return [Hash, nil] { filename: String, data: String (binary) }
      private def parse_multipart_upload(req, field_name)
        content_type = req["Content-Type"].to_s
        return nil unless content_type.include?("multipart/form-data")

        # Extract boundary from Content-Type header
        boundary_match = content_type.match(/boundary=([^\s;]+)/)
        return nil unless boundary_match

        boundary = "--" + boundary_match[1].strip.gsub(/^"(.*)"$/, '')
        body     = req.body.to_s.b  # treat as binary

        # Split body by boundary and find the target field
        parts = body.split(Regexp.new(Regexp.escape(boundary)))
        parts.each do |part|
          # Each part has headers, then blank line, then body
          # Use \r\n\r\n or \n\n as separator between headers and body
          header_body_sep = part.index("\r\n\r\n") || part.index("\n\n")
          next unless header_body_sep

          sep_len     = part[header_body_sep, 4] == "\r\n\r\n" ? 4 : 2
          raw_headers = part[0, header_body_sep]
          raw_body    = part[(header_body_sep + sep_len)..]

          # Remove trailing CRLF from part body
          raw_body = raw_body.sub(/\r\n\z/, "").sub(/\n\z/, "")

          # Check Content-Disposition for our field name
          next unless raw_headers.include?("Content-Disposition")

          name_match = raw_headers.match(/name="([^"]+)"/)
          next unless name_match && name_match[1] == field_name

          file_match = raw_headers.match(/filename="([^"]*)"/)
          filename   = file_match ? file_match[1] : field_name

          return { filename: filename, data: raw_body }
        end

        nil
      end

      def not_found(res)
        res.status = 404
        res.body   = "Not Found"
      end

      # Stop any previously running server on the given port via its PID file.
      private def kill_existing_server(port)
        pid_file = File.join(Dir.tmpdir, "clacky-server-#{port}.pid")
        return unless File.exist?(pid_file)

        pid = File.read(pid_file).strip.to_i
        return if pid <= 0
        # After exec-restart, the new process inherits the same PID as the old one.
        # Skip sending TERM to ourselves — we are already the new server.
        if pid == Process.pid
          Clacky::Logger.info("[Server] exec-restart detected (PID=#{pid}), skipping self-kill.")
          return
        end

        begin
          Process.kill("TERM", pid)
          Clacky::Logger.info("[Server] Stopped existing server (PID=#{pid}) on port #{port}.")
          puts "Stopped existing server (PID: #{pid}) on port #{port}."
          # Give it a moment to release the port
          sleep 0.5
        rescue Errno::ESRCH
          Clacky::Logger.info("[Server] Existing server PID=#{pid} already gone.")
        rescue Errno::EPERM
          Clacky::Logger.warn("[Server] Could not stop existing server (PID=#{pid}) — permission denied.")
          puts "Could not stop existing server (PID: #{pid}) — permission denied."
        ensure
          File.delete(pid_file) if File.exist?(pid_file)
        end
      end

      # ── Inner classes ─────────────────────────────────────────────────────────

      # Wraps a raw TCP socket, providing thread-safe WebSocket frame sending.
      class WebSocketConnection
        attr_accessor :session_id

        def initialize(socket, version)
          @socket     = socket
          @version    = version
          @send_mutex = Mutex.new
          @closed     = false
        end

        # Returns true if the underlying socket has been detected as dead.
        def closed?
          @closed
        end

        # Send a JSON-serializable object over the WebSocket.
        # Returns true on success, false if the connection is dead.
        def send_json(data)
          send_raw(:text, JSON.generate(data))
        rescue => e
          Clacky::Logger.debug("WS send error (connection dead): #{e.message}")
          false
        end

        # Send a raw WebSocket frame.
        # Returns true on success, false on broken/closed socket.
        def send_raw(type, data)
          @send_mutex.synchronize do
            return false if @closed

            outgoing = WebSocket::Frame::Outgoing::Server.new(
              version: @version,
              data: data,
              type: type
            )
            @socket.write(outgoing.to_s)
          end
          true
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError, Errno::EBADF => e
          @closed = true
          Clacky::Logger.debug("WS send_raw error (client disconnected): #{e.message}")
          false
        rescue => e
          @closed = true
          Clacky::Logger.debug("WS send_raw unexpected error: #{e.message}")
          false
        end
      end
    end
  end
end
