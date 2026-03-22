# frozen_string_literal: true

require "webrick"
require "websocket/driver"
require "json"
require "thread"
require "fileutils"
require "tmpdir"
require "uri"
require "open3"
require "securerandom"
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
          url || (name ? "pdf:#{name}" : nil)
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
      def respond_to_missing?(name, include_private = false) = true
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

      def initialize(host: "127.0.0.1", port: 7070, agent_config:, client_factory:, brand_test: false)
        @host           = host
        @port           = port
        @agent_config   = agent_config
        @client_factory = client_factory  # callable: -> { Clacky::Client.new(...) }
        @brand_test     = brand_test      # when true, skip remote API calls for license activation
        # Capture the absolute path of the entry script and original ARGV at startup,
        # so api_restart can re-exec the correct binary even if cwd changes later.
        @restart_script = File.expand_path($0)
        @restart_argv   = ARGV.dup
        @registry        = SessionRegistry.new
        @session_manager = Clacky::SessionManager.new
        @ws_clients      = {}  # session_id => [WebSocketConnection, ...]
        @ws_mutex        = Mutex.new
        # Version cache: { latest: "x.y.z", checked_at: Time }
        @version_cache   = nil
        @version_mutex   = Mutex.new
        @scheduler       = Scheduler.new(
          session_registry: @registry,
          session_builder:  method(:build_session)
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
      end

      def start
        # Enable console logging for the server process so log lines are visible in the terminal.
        Clacky::Logger.console = true

        # Kill any previous server on the same port, then write our own PID file
        kill_existing_server(@port)
        pid_file = File.join(Dir.tmpdir, "clacky-server-#{@port}.pid")
        File.write(pid_file, Process.pid.to_s)
        at_exit { File.delete(pid_file) if File.exist?(pid_file) }

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
        server = WEBrick::HTTPServer.new(
          BindAddress:     @host,
          Port:            @port,
          Logger:          WEBrick::Log.new(File::NULL),
          AccessLog:       [],
          StartCallback:   proc { trap("INT") { exit(0) }; trap("TERM") { exit(0) } }
        )

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
            product_name = Clacky::BrandConfig.load.product_name || "Clacky"
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

        banner = Clacky::Banner.new
        puts ""
        puts banner.colored_cli_logo
        puts banner.colored_tagline
        puts ""
        puts "   Web UI: #{banner.highlight("http://#{@host}:#{@port}")}"
        puts "   Version: #{Clacky::VERSION}"
        puts "   Press Ctrl-C to stop."

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

      private

      # ── Router ────────────────────────────────────────────────────────────────

      def dispatch(req, res)
        path   = req.path
        method = req.request_method

        # WebSocket upgrade
        if websocket_upgrade?(req)
          handle_websocket(req, res)
          return
        end

        case [method, path]
        when ["GET",    "/api/sessions"]      then api_list_sessions(res)
        when ["POST",   "/api/sessions"]      then api_create_session(req, res)
        when ["GET",    "/api/schedules"]     then api_list_schedules(res)
        when ["POST",   "/api/schedules"]     then api_create_schedule(req, res)
        when ["GET",    "/api/tasks"]         then api_list_tasks(res)
        when ["POST",   "/api/tasks"]         then api_create_task(req, res)
        when ["POST",   "/api/tasks/run"]     then api_run_task(req, res)
        when ["GET",    "/api/skills"]         then api_list_skills(res)
        when ["GET",    "/api/config"]        then api_get_config(res)
        when ["POST",   "/api/config"]        then api_save_config(req, res)
        when ["POST",   "/api/config/test"]   then api_test_config(req, res)
        when ["GET",    "/api/providers"]     then api_list_providers(res)
        when ["GET",    "/api/onboard/status"]    then api_onboard_status(res)
        when ["GET",    "/api/browser/status"]    then api_browser_status(res)
        when ["POST",   "/api/browser/reload"]    then api_browser_reload(res)
        when ["POST",   "/api/onboard/complete"]  then api_onboard_complete(req, res)
        when ["POST",   "/api/onboard/skip-soul"] then api_onboard_skip_soul(req, res)
        when ["GET",    "/api/store/skills"]          then api_store_skills(res)
        when ["GET",    "/api/brand/status"]      then api_brand_status(res)
        when ["POST",   "/api/brand/activate"]    then api_brand_activate(req, res)
        when ["GET",    "/api/brand/skills"]      then api_brand_skills(res)
        when ["GET",    "/api/brand"]             then api_brand_info(res)
        when ["GET",    "/api/channels"]          then api_list_channels(res)
        when ["POST",   "/api/tool/browser"]      then api_tool_browser(req, res)
        when ["POST",   "/api/upload"]            then api_upload_file(req, res)
        when ["GET",    "/api/version"]           then api_get_version(res)
        when ["POST",   "/api/version/upgrade"]   then api_upgrade_version(req, res)
        when ["POST",   "/api/restart"]           then api_restart(req, res)
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
          elsif method == "GET" && path.match?(%r{^/api/sessions/[^/]+/messages$})
            session_id = path.sub("/api/sessions/", "").sub("/messages", "")
            api_session_messages(session_id, req, res)
          elsif method == "PATCH" && path.match?(%r{^/api/sessions/[^/]+$})
            session_id = path.sub("/api/sessions/", "")
            api_rename_session(session_id, req, res)
          elsif method == "DELETE" && path.start_with?("/api/sessions/")
            session_id = path.sub("/api/sessions/", "")
            api_delete_session(session_id, res)
          elsif method == "DELETE" && path.start_with?("/api/schedules/")
            name = URI.decode_www_form_component(path.sub("/api/schedules/", ""))
            api_delete_schedule(name, res)
          elsif method == "GET" && path.start_with?("/api/tasks/")
            name = URI.decode_www_form_component(path.sub("/api/tasks/", ""))
            api_get_task(name, res)
          elsif method == "DELETE" && path.start_with?("/api/tasks/")
            name = URI.decode_www_form_component(path.sub("/api/tasks/", ""))
            api_delete_task(name, res)
          elsif method == "PATCH" && path.match?(%r{^/api/skills/[^/]+/toggle$})
            name = URI.decode_www_form_component(path.sub("/api/skills/", "").sub("/toggle", ""))
            api_toggle_skill(name, req, res)
          elsif method == "POST" && path.match?(%r{^/api/brand/skills/[^/]+/install$})
            slug = URI.decode_www_form_component(path.sub("/api/brand/skills/", "").sub("/install", ""))
            api_brand_skill_install(slug, req, res)
          elsif method == "POST" && path.match?(%r{^/api/my-skills/[^/]+/publish$})
            name = URI.decode_www_form_component(path.sub("/api/my-skills/", "").sub("/publish", ""))
            api_publish_my_skill(name, req, res)
          else
            not_found(res)
          end
        end
      rescue => e
        $stderr.puts "[HTTP 500] #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        json_response(res, 500, { error: e.message })
      end

      # ── REST API ──────────────────────────────────────────────────────────────

      def api_list_sessions(res)
        json_response(res, 200, { sessions: @registry.list })
      end

      def api_create_session(req, res)
        body = parse_json_body(req)
        name = body["name"]
        return json_response(res, 400, { error: "name is required" }) if name.nil? || name.strip.empty?

        working_dir = default_working_dir
        FileUtils.mkdir_p(working_dir)

        session_id = build_session(name: name, working_dir: working_dir)
        json_response(res, 201, { session: @registry.list.find { |s| s[:id] == session_id } })
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

        working_dir = default_working_dir
        FileUtils.mkdir_p(working_dir) unless Dir.exist?(working_dir)

        # Restore the most recent 5 sessions for this working directory
        sessions_data = @session_manager.latest_n_for_directory(working_dir, 5)

        if sessions_data.any?
          sessions_data.each { |session_data| build_session_from_data(session_data) }
        else
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

      # POST /api/browser/reload
      # Called by browser-setup skill after writing browser.yml.
      # Hot-reloads the MCP daemon with the new configuration.
      def api_browser_reload(res)
        @browser_manager.reload
        json_response(res, 200, { ok: true })
      rescue StandardError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      # POST /api/onboard/complete
      # Called after key setup is done (soul_setup is optional/skipped).
      # Creates the default session if none exists yet, returns it.
      def api_onboard_complete(req, res)
        create_default_session if @registry.list.empty?
        first_session = @registry.list.first
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
          json_response(res, 200, {
            branded:          true,
            needs_activation: true,
            product_name:     brand.product_name,
            test_mode:        @brand_test
          })
          return
        end

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
              # Use locally cached description so it renders correctly offline
              "description"       => meta["description"].to_s,
              "installed_version" => meta["version"],
              "needs_update"      => false
            }
          end
          json_response(res, 200, {
            ok:      true,
            skills:  local_skills,
            warning: "Could not reach the license server. Showing locally installed skills only."
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
      # Runs `gem update openclacky --no-document` via Clacky::Tools::Shell (login shell)
      # in a background thread, streaming output via WebSocket broadcast.
      # On success, re-execs the process so the new gem version is loaded.
      def api_upgrade_version(req, res)
        json_response(res, 202, { ok: true, message: "Upgrade started" })

        Thread.new do
          begin
            broadcast_all(type: "upgrade_log", line: "Starting upgrade: gem update openclacky --no-document\n")

            shell  = Clacky::Tools::Shell.new
            result = shell.execute(command: "gem update openclacky --no-document",
                                   soft_timeout: 300, hard_timeout: 600)
            output  = [result[:stdout], result[:stderr]].join
            success = result[:exit_code] == 0

            broadcast_all(type: "upgrade_log", line: output)

            if success
              broadcast_all(type: "upgrade_log", line: "\n✓ Upgrade successful! Please restart the server to apply the new version.\n")
              broadcast_all(type: "upgrade_complete", success: true)
            else
              broadcast_all(type: "upgrade_log", line: "\n✗ Upgrade failed. Please try manually: gem update openclacky\n")
              broadcast_all(type: "upgrade_complete", success: false)
            end
          rescue StandardError => e
            broadcast_all(type: "upgrade_log", line: "\n✗ Error during upgrade: #{e.message}\n")
            broadcast_all(type: "upgrade_complete", success: false)
          end
        end
      end

      # POST /api/restart
      # Re-execs the current process so the newly installed gem version is loaded.
      # Uses the absolute script path captured at startup to avoid relative-path issues.
      # Responds 200 first, then waits briefly for WEBrick to flush the response before exec.
      def api_restart(req, res)
        json_response(res, 200, { ok: true, message: "Restarting…" })

        script = @restart_script
        argv   = @restart_argv
        Thread.new do
          sleep 0.5  # Let WEBrick flush the HTTP response
          Clacky::Logger.info("[Restart] exec: #{RbConfig.ruby} #{script} #{argv.join(' ')}")
          exec(RbConfig.ruby, script, *argv)
        end
      end

      # Fetch the latest gem version using `gem list -r`, with a 1-hour in-memory cache.
      # Uses Clacky::Tools::Shell (login shell) so rbenv/mise shims and gem mirrors work correctly.
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
        shell  = Clacky::Tools::Shell.new
        result = shell.execute(command: "gem list -r openclacky", soft_timeout: 15, hard_timeout: 30)
        return nil unless result[:exit_code] == 0

        out   = result[:stdout].to_s
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

      # POST /api/channels/:platform
      # Body: { fields... }  (platform-specific credential fields)
      # Saves credentials and optionally (re)starts the adapter.
      def api_save_channel(platform, req, res)
        platform = platform.to_sym
        body     = parse_json_body(req)
        config   = Clacky::ChannelConfig.load

        fields = body.transform_keys(&:to_sym).reject { |k, _| k == :platform }
        fields = fields.transform_values { |v| v.is_a?(String) ? v.strip : v }

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

      # ── Schedules API ─────────────────────────────────────────────────────────

      def api_list_schedules(res)
        json_response(res, 200, { schedules: @scheduler.schedules })
      end

      def api_create_schedule(req, res)
        body = parse_json_body(req)
        name = body["name"].to_s.strip
        task = body["task"].to_s.strip
        cron = body["cron"].to_s.strip

        if name.empty? || task.empty? || cron.empty?
          json_response(res, 422, { error: "name, task, and cron are required" })
          return
        end

        unless @scheduler.list_tasks.include?(task)
          json_response(res, 422, { error: "Task not found: #{task}" })
          return
        end

        @scheduler.add_schedule(name: name, task: task, cron: cron)
        json_response(res, 201, { ok: true, name: name })
      end

      def api_delete_schedule(name, res)
        if @scheduler.remove_schedule(name)
          json_response(res, 200, { ok: true })
        else
          json_response(res, 404, { error: "Schedule not found: #{name}" })
        end
      end

      # ── Tasks API ─────────────────────────────────────────────────────────────

      def api_list_tasks(res)
        tasks = @scheduler.list_tasks.map do |name|
          content = begin
            @scheduler.read_task(name)
          rescue StandardError
            ""
          end
          { name: name, path: @scheduler.task_file_path(name), content: content }
        end
        json_response(res, 200, { tasks: tasks })
      end

      def api_get_task(name, res)
        content = @scheduler.read_task(name)
        json_response(res, 200, { name: name, content: content })
      rescue => e
        json_response(res, 404, { error: e.message })
      end

      def api_delete_task(name, res)
        if @scheduler.delete_task(name)
          json_response(res, 200, { ok: true })
        else
          json_response(res, 404, { error: "Task not found: #{name}" })
        end
      end

      def api_create_task(req, res)
        body    = parse_json_body(req)
        name    = body["name"].to_s.strip
        content = body["content"].to_s

        if name.empty?
          json_response(res, 422, { error: "name is required" })
          return
        end

        @scheduler.write_task(name, content)
        json_response(res, 201, { ok: true, name: name })
      end

      def api_run_task(req, res)
        body = parse_json_body(req)
        name = body["name"].to_s.strip

        if name.empty?
          json_response(res, 422, { error: "name is required" })
          return
        end

        begin
          prompt       = @scheduler.read_task(name)
          session_name = "▶ #{name} #{Time.now.strftime("%H:%M")}"
          working_dir  = File.expand_path("~/clacky_workspace")
          FileUtils.mkdir_p(working_dir)

          # Tasks run unattended — use auto_approve so request_user_feedback doesn't block.
          session_id = build_session(name: session_name, working_dir: working_dir, permission_mode: :auto_approve)

          # Store the pending task prompt so the WS "run_task" message can start it
          # after the client has subscribed and is ready to receive broadcasts.
          @registry.update(session_id, pending_task: prompt, pending_working_dir: working_dir)

          session = @registry.list.find { |s| s[:id] == session_id }
          json_response(res, 202, { ok: true, session: session })
        rescue => e
          json_response(res, 422, { error: e.message })
        end
      end

      # ── Skills API ────────────────────────────────────────────────────────────

      # GET /api/skills — list all loaded skills with metadata
      def api_list_skills(res)
        @skill_loader.load_all  # refresh from disk on each request
        skills = @skill_loader.all_skills.reject(&:brand_skill).map do |skill|
          source = @skill_loader.loaded_from[skill.identifier]
          entry = {
            name:        skill.identifier,
            description: skill.context_description,
            source:      source,
            enabled:     !skill.disabled?,
            invalid:     skill.invalid?,
            warnings:    skill.warnings
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

        skill_data = skills.map do |skill|
          {
            name:        skill.identifier,
            description: skill.description || skill.context_description
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
            json_response(res, 200, { ok: true, name: name })
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
            index:            i,
            model:            m["model"],
            base_url:         m["base_url"],
            api_key_masked:   mask_api_key(m["api_key"]),
            anthropic_format: m["anthropic_format"] || false,
            type:             m["type"]
          }
        end
        json_response(res, 200, { models: models, current_index: @agent_config.current_model_index })
      end

      # POST /api/config — save updated model list
      # Body: { models: [ { index, model, base_url, api_key, anthropic_format, type } ] }
      # api_key may be masked ("sk-ab12****...5678") — keep existing key in that case
      def api_save_config(req, res)
        body = parse_json_body(req)
        return json_response(res, 400, { error: "Invalid JSON" }) unless body

        incoming = body["models"]
        return json_response(res, 400, { error: "models array required" }) unless incoming.is_a?(Array)

        incoming.each_with_index do |m, i|
          existing = @agent_config.models[i]
          # Resolve api_key: if masked placeholder, keep the stored key
          api_key = if m["api_key"].to_s.include?("****")
                      existing&.dig("api_key")
                    else
                      m["api_key"]
                    end

          if existing
            existing["model"]            = m["model"]            if m.key?("model")
            existing["base_url"]         = m["base_url"]         if m.key?("base_url")
            existing["api_key"]          = api_key               if api_key
            existing["anthropic_format"] = m["anthropic_format"] if m.key?("anthropic_format")
            existing["type"]             = m["type"]             if m.key?("type")
          else
            @agent_config.add_model(
              model:            m["model"].to_s,
              api_key:          api_key.to_s,
              base_url:         m["base_url"].to_s,
              anthropic_format: m["anthropic_format"] || false,
              type:             m["type"]
            )
          end
        end

        # Remove models that are no longer present (trim to incoming length)
        while @agent_config.models.length > incoming.length
          @agent_config.models.pop
        end

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
          test_client = Clacky::Client.new(
            api_key,
            base_url:         body["base_url"].to_s,
            anthropic_format: body["anthropic_format"] || false
          )
          model = body["model"].to_s
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
            models:        preset["models"] || []
          }
        end
        json_response(res, 200, { providers: providers })
      end

      # GET /api/sessions/:id/messages?limit=20&before=1709123456.789
      # Replays conversation history for a session via the agent's replay_history method.
      # Returns a list of UI events (same format as WS events) for the frontend to render.
      def api_session_messages(session_id, req, res)
        unless @registry.exist?(session_id)
          return json_response(res, 404, { error: "Session not found" })
        end

        # Parse query params
        query   = URI.decode_www_form(req.query_string.to_s).to_h
        limit   = [query["limit"].to_i.then { |n| n > 0 ? n : 20 }, 100].min
        before  = query["before"]&.to_f

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }

        unless agent
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
        new_name = body["name"].to_s.strip

        return json_response(res, 400, { error: "name is required" }) if new_name.empty?
        return json_response(res, 404, { error: "Session not found" }) unless @registry.exist?(session_id)

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }
        agent.rename(new_name)
        save_session(session_id, agent)
        broadcast(session_id, { type: "session_renamed", session_id: session_id, name: new_name })
        json_response(res, 200, { ok: true, name: new_name })
      rescue => e
        json_response(res, 500, { error: e.message })
      end

      def api_delete_session(session_id, res)
        if @registry.delete(session_id)
          # Notify connected clients the session is gone
          broadcast(session_id, { type: "session_deleted", session_id: session_id })
          unsubscribe_all(session_id)
          json_response(res, 200, { ok: true })
        else
          json_response(res, 404, { error: "Session not found" })
        end
      end

      # ── WebSocket ─────────────────────────────────────────────────────────────

      def websocket_upgrade?(req)
        req["Upgrade"]&.downcase == "websocket"
      end

      # Hijacks the TCP socket from WEBrick and hands it to websocket-driver.
      def handle_websocket(req, res)
        # Prevent WEBrick from closing the socket after this handler returns
        socket = req.instance_variable_get(:@socket)

        driver = WebSocket::Driver.rack(
          RackEnvAdapter.new(req, socket),
          max_length: 10 * 1024 * 1024
        )

        conn = WebSocketConnection.new(socket, driver)

        driver.on(:open)    { on_ws_open(conn) }
        driver.on(:message) { |event| on_ws_message(conn, event.data) }
        driver.on(:close)   { on_ws_close(conn) }
        driver.on(:error)   { |event| $stderr.puts "WS error: #{event.message}" }

        driver.start

        # Read loop — blocks this thread until the socket closes
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
              driver.parse(chunk)
            end
          end
        rescue IOError, Errno::ECONNRESET, Errno::EPIPE
          # Client disconnected
        ensure
          on_ws_close(conn)
          driver.close rescue nil
        end

        # Tell WEBrick not to send any response (we handled everything)
        res.instance_variable_set(:@header, {})
        res.status = -1
      rescue => e
        $stderr.puts "WebSocket handler error: #{e.class}: #{e.message}"
      end

      def on_ws_open(conn)
        # Client will send a "subscribe" message to bind to a session
      end

      def on_ws_message(conn, raw)
        msg = JSON.parse(raw)
        type = msg["type"]

        case type
        when "subscribe"
          session_id = msg["session_id"]
          if @registry.exist?(session_id)
            conn.session_id = session_id
            subscribe(session_id, conn)
            conn.send_json(type: "subscribed", session_id: session_id)
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
          conn.send_json(type: "session_list", sessions: @registry.list)

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
        conn.send_json(type: "error", message: e.message)
      end

      def on_ws_close(conn)
        unsubscribe(conn)
      end

      # ── Session actions ───────────────────────────────────────────────────────

      def handle_user_message(session_id, content, files = [])
        return unless @registry.exist?(session_id)

        session = @registry.get(session_id)
        return if session[:status] == :running

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
          save_session(session_id, agent, status: :success)
          # Start idle compression timer now that the agent is idle
          idle_timer&.start
        rescue Clacky::AgentInterrupted
          @registry.update(session_id, status: :idle)
          broadcast_session_update(session_id)
          broadcast(session_id, { type: "interrupted", session_id: session_id })
          save_session(session_id, agent, status: :interrupted)
        rescue => e
          @registry.update(session_id, status: :error, error: e.message)
          broadcast_session_update(session_id)
          broadcast(session_id, { type: "error", session_id: session_id, message: e.message })
          save_session(session_id, agent, status: :error, error_message: e.message)
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
      def broadcast(session_id, event)
        clients = @ws_mutex.synchronize { (@ws_clients[session_id] || []).dup }
        clients.each { |conn| conn.send_json(event) rescue nil }
      end

      # Broadcast an event to every connected client.
      def broadcast_all(event)
        clients = @ws_mutex.synchronize { @ws_clients.values.flatten.uniq }
        clients.each { |conn| conn.send_json(event) rescue nil }
      end

      # Broadcast a session_update event to all clients so they can patch their
      # local session list without needing a full session_list refresh.
      def broadcast_session_update(session_id)
        session = @registry.list.find { |s| s[:id] == session_id }
        return unless session

        broadcast_all(type: "session_update", session: session)
      end

      # ── Helpers ───────────────────────────────────────────────────────────────

      # Default working directory for new sessions.
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
      def build_session(name:, working_dir:, permission_mode: :confirm_all, profile: "general")
        session_id = Clacky::SessionManager.generate_id
        @registry.create(session_id: session_id)

        client = @client_factory.call
        config = @agent_config.deep_copy
        config.permission_mode = permission_mode
        broadcaster = method(:broadcast)
        ui = WebUIController.new(session_id, broadcaster)
        agent = Clacky::Agent.new(client, config, working_dir: working_dir, ui: ui, profile: profile,
                                  session_id: session_id)
        agent.rename(name) unless name.nil? || name.empty?
        idle_timer = build_idle_timer(session_id, agent)

        @registry.with_session(session_id) do |s|
          s[:agent]      = agent
          s[:ui]         = ui
          s[:idle_timer] = idle_timer
        end

        session_id
      end

      # Restore a persisted session from saved session_data (from SessionManager).
      # The agent keeps its original session_id so the frontend URL hash stays valid
      # across server restarts.
      def build_session_from_data(session_data, permission_mode: :confirm_all)
        original_id = session_data[:session_id]

        # Skip if this session is already registered (e.g., restored by a previous call)
        return nil if @registry.exist?(original_id)

        # Register with the original session_id so frontend hashes stay valid
        @registry.create(session_id: original_id)

        client = @client_factory.call
        config = @agent_config.deep_copy
        config.permission_mode = permission_mode
        broadcaster = method(:broadcast)
        ui = WebUIController.new(original_id, broadcaster)
        agent = Clacky::Agent.from_session(client, config, session_data, ui: ui, profile: "general")
        idle_timer = build_idle_timer(original_id, agent)

        # Restore channel_keys (IM platform bindings) persisted in session JSON.
        # Converts the serialized Array back into a Set so ChannelManager can locate
        # this session by IM identity after a server restart.
        persisted_channel_keys = session_data[:channel_keys] || session_data["channel_keys"]
        channel_keys_set = persisted_channel_keys&.any? ? Set.new(persisted_channel_keys) : nil

        @registry.with_session(original_id) do |s|
          s[:agent]        = agent
          s[:ui]           = ui
          s[:idle_timer]   = idle_timer
          s[:channel_keys] = channel_keys_set if channel_keys_set
        end

        original_id
      end

      # Persist a session to disk, including IM channel key bindings so they survive restarts.
      # Reads channel_keys from the registry and merges them as an Array into session_data
      # before saving — on restore, build_session_from_data converts them back to a Set.
      # @param session_id [String]
      # @param agent      [Clacky::Agent]
      # @param status     [Symbol]  :success | :interrupted | :error
      # @param error_message [String, nil]
      private def save_session(session_id, agent, status: :success, error_message: nil)
        data = agent.to_session_data(status: status, error_message: error_message)
        # Attach channel_keys (Set → Array for JSON serialisation)
        channel_keys = nil
        @registry.with_session(session_id) { |s| channel_keys = s[:channel_keys]&.to_a }
        data[:channel_keys] = channel_keys if channel_keys&.any?
        @session_manager.save(data)
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
      def mask_api_key(key)
        return "" if key.nil? || key.empty?
        return key if key.length <= 12
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

      # Thin adapter so websocket-driver (which expects a Rack env) can work with WEBrick.
      class RackEnvAdapter
        def initialize(req, socket)
          @req    = req
          @socket = socket
        end

        def env
          {
            "REQUEST_METHOD" => @req.request_method,
            "HTTP_HOST"      => @req["Host"],
            "REQUEST_URI"    => @req.request_uri.to_s,
            "HTTP_UPGRADE"   => @req["Upgrade"],
            "HTTP_CONNECTION"          => @req["Connection"],
            "HTTP_SEC_WEBSOCKET_KEY"   => @req["Sec-WebSocket-Key"],
            "HTTP_SEC_WEBSOCKET_VERSION" => @req["Sec-WebSocket-Version"],
            "rack.hijack"    => proc {},
            "rack.input"     => StringIO.new
          }
        end

        def write(data)
          @socket.write(data)
        end
      end

      # Wraps a raw TCP socket + WebSocket driver, providing a thread-safe send method.
      class WebSocketConnection
        attr_accessor :session_id

        def initialize(socket, driver)
          @socket     = socket
          @driver     = driver
          @send_mutex = Mutex.new
        end

        def send_json(data)
          @send_mutex.synchronize { @driver.text(JSON.generate(data)) }
        rescue => e
          $stderr.puts "WS send error: #{e.message}"
        end
      end
    end
  end
end
