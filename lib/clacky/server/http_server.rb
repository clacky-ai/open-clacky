# frozen_string_literal: true

require "webrick"
require "websocket/driver"
require "json"
require "thread"
require "fileutils"
require "uri"
require_relative "session_registry"
require_relative "web_ui_controller"
require_relative "scheduler"

module Clacky
  module Server
    # HttpServer runs an embedded WEBrick HTTP server with WebSocket support.
    #
    # Routes:
    #   GET  /ws                     → WebSocket upgrade (all real-time communication)
    #   *    /api/*                  → JSON REST API (sessions, tasks, schedules)
    #   GET  /**                     → static files served from lib/clacky/web/ directory
    class HttpServer
      WEB_ROOT = File.expand_path("../web", __dir__)

      def initialize(host: "127.0.0.1", port: 7070, agent_config:, client_factory:)
        @host           = host
        @port           = port
        @agent_config   = agent_config
        @client_factory = client_factory  # callable: -> { Clacky::Client.new(...) }
        @registry       = SessionRegistry.new
        @ws_clients     = {}  # session_id => [WebSocketConnection, ...]
        @ws_mutex       = Mutex.new
        @scheduler      = Scheduler.new(
          session_registry: @registry,
          session_builder:  method(:build_session)
        )
      end

      def start
        server = WEBrick::HTTPServer.new(
          BindAddress:     @host,
          Port:            @port,
          Logger:          WEBrick::Log.new(File::NULL),
          AccessLog:       []
        )

        # Mount API + WebSocket handler (takes priority)
        server.mount_proc("/api") { |req, res| dispatch(req, res) }
        server.mount_proc("/ws")  { |req, res| dispatch(req, res) }

        # Mount static file handler for the entire web directory.
        # Use mount_proc so we can inject no-cache headers on every response,
        # preventing stale JS/CSS from being served after a gem update.
        file_handler = WEBrick::HTTPServlet::FileHandler.new(server, WEB_ROOT,
                                                             FancyIndexing: false)
        server.mount_proc("/") do |req, res|
          file_handler.service(req, res)
          res["Cache-Control"] = "no-store"
          res["Pragma"]        = "no-cache"
        end

        # Graceful shutdown on Ctrl-C
        trap("INT")  { @scheduler.stop; server.shutdown }
        trap("TERM") { @scheduler.stop; server.shutdown }

        puts "🌐 Clacky Web UI running at http://#{@host}:#{@port}"
        puts "   Press Ctrl-C to stop."

        # Auto-create a default session on startup
        create_default_session

        # Start the background scheduler
        @scheduler.start
        puts "   ⏰ Scheduler started (#{@scheduler.schedules.size} schedule(s) loaded)"

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
        else
          if method == "DELETE" && path.start_with?("/api/sessions/")
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
          else
            not_found(res)
          end
        end
      end

      # ── REST API ──────────────────────────────────────────────────────────────

      def api_list_sessions(res)
        json_response(res, 200, { sessions: @registry.list })
      end

      def api_create_session(req, res)
        body = parse_json_body(req)
        name        = body["name"]
        working_dir = default_working_dir

        # Validate working directory
        unless Dir.exist?(working_dir)
          json_response(res, 422, { error: "Directory does not exist: #{working_dir}" })
          return
        end

        session_id = build_session(name: name, working_dir: working_dir)
        json_response(res, 201, { session: @registry.list.find { |s| s[:id] == session_id } })
      end

      # Auto-create a default session when the server starts.
      def create_default_session
        working_dir = default_working_dir
        FileUtils.mkdir_p(working_dir) unless Dir.exist?(working_dir)
        build_session(name: "Session 1", working_dir: working_dir)
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
        path = @scheduler.task_file_path(name)
        if File.exist?(path)
          File.delete(path)
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

          session_id = build_session(name: session_name, working_dir: working_dir)

          # Store the pending task prompt so the WS "run_task" message can start it
          # after the client has subscribed and is ready to receive broadcasts.
          @registry.update(session_id, pending_task: prompt, pending_working_dir: working_dir)

          session = @registry.list.find { |s| s[:id] == session_id }
          json_response(res, 202, { ok: true, session: session })
        rescue => e
          json_response(res, 422, { error: e.message })
        end
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
          handle_user_message(session_id, msg["content"].to_s, msg["images"] || [])

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

      def handle_user_message(session_id, content, images)
        return unless @registry.exist?(session_id)

        session = @registry.get(session_id)
        return if session[:status] == :running

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }
        return unless agent

        @registry.update(session_id, status: :running)
        broadcast_session_update(session_id)

        thread = Thread.new do
          Dir.chdir(session[:working_dir]) do
            agent.run(content, images: images)
          end
          @registry.update(session_id, status: :idle, error: nil)
          broadcast_session_update(session_id)

          # Persist session
          session_manager = Clacky::SessionManager.new
          session_manager.save(agent.to_session_data(status: :success))
        rescue Clacky::AgentInterrupted
          @registry.update(session_id, status: :idle)
          broadcast_session_update(session_id)
          broadcast(session_id, { type: "interrupted", session_id: session_id })
        rescue => e
          @registry.update(session_id, status: :error, error: e.message)
          broadcast_session_update(session_id)
          broadcast(session_id, { type: "error", session_id: session_id, message: e.message })
        end

        @registry.with_session(session_id) { |s| s[:thread] = thread }
      end

      def deliver_confirmation(session_id, conf_id, result)
        ui = nil
        @registry.with_session(session_id) { |s| ui = s[:ui] }
        ui&.deliver_confirmation(conf_id, result)
      end

      def interrupt_session(session_id)
        @registry.with_session(session_id) do |s|
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

        @registry.update(session_id, status: :running)
        broadcast_session_update(session_id)

        thread = Thread.new do
          Dir.chdir(working_dir) { agent.run(prompt) }
          @registry.update(session_id, status: :idle)
          broadcast_session_update(session_id)
        rescue Clacky::AgentInterrupted
          @registry.update(session_id, status: :idle)
          broadcast_session_update(session_id)
          broadcast(session_id, { type: "interrupted", session_id: session_id })
        rescue => e
          @registry.update(session_id, status: :error, error: e.message)
          broadcast_session_update(session_id)
          broadcast(session_id, { type: "error", session_id: session_id, message: e.message })
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
      def build_session(name:, working_dir:)
        session_id = @registry.create(name: name, working_dir: working_dir)

        client = @client_factory.call
        agent  = Clacky::Agent.new(client, @agent_config.dup, working_dir: working_dir)

        broadcaster = method(:broadcast)
        ui = WebUIController.new(session_id, broadcaster)
        agent.instance_variable_set(:@ui, ui)

        @registry.with_session(session_id) do |s|
          s[:agent] = agent
          s[:ui]    = ui
        end

        session_id
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

      def not_found(res)
        res.status = 404
        res.body   = "Not Found"
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
