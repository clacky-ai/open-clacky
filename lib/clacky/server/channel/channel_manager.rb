# frozen_string_literal: true

require_relative "channel_ui_controller"

module Clacky
  module Channel
    # ChannelManager starts and supervises IM platform adapter threads.
    # When an inbound message arrives it:
    #   1. Resolves (or auto-creates) a Session bound to this IM identity
    #   2. Retrieves the WebUIController for that session
    #   3. Creates a ChannelUIController and subscribes it to the WebUIController
    #   4. Runs the agent task via run_agent_task (same as HttpServer)
    #   5. Unsubscribes the ChannelUIController when the task finishes
    #
    # Thread model: each adapter runs two long-lived threads (read loop + ping).
    # ChannelManager itself is non-blocking — call #start from HttpServer after
    # the WEBrick server has started.
    #
    # Session binding: the first message from an IM identity automatically creates
    # a new session and binds it. Users can use /bind <session_id> to switch to an
    # existing WebUI session instead. Bindings are stored in the session registry as
    # :channel_keys => Set of channel key strings.
    # WebUI sessions are persisted by HttpServer — channel adds no extra persistence.
    class ChannelManager
      # @param session_registry   [Clacky::Server::SessionRegistry]
      # @param session_builder    [Proc] (name:, working_dir:) => session_id — from HttpServer
      # @param run_agent_task     [Proc] (session_id, agent, &task) — from HttpServer
      # @param interrupt_session  [Proc] (session_id) — from HttpServer
      # @param channel_config     [Clacky::ChannelConfig]
      # @param binding_mode       [:user | :chat] how to map IM identities to sessions
      def initialize(session_registry:, session_builder:, run_agent_task:, interrupt_session:, channel_config:, binding_mode: :user)
        @registry          = session_registry
        @session_builder   = session_builder
        @run_agent_task    = run_agent_task
        @interrupt_session = interrupt_session
        @channel_config    = channel_config
        @binding_mode      = binding_mode
        @adapters          = []
        @adapter_threads   = []
        @running           = false
        @mutex             = Mutex.new
        @session_counters  = Hash.new(0)  # platform => count, for short session names
      end

      # Start all enabled adapters in background threads. Non-blocking.
      def start
        enabled_platforms = @channel_config.enabled_platforms
        if enabled_platforms.empty?
          Clacky::Logger.info("[ChannelManager] No channels configured — skipping")
          return
        end

        Clacky::Logger.info("[ChannelManager] Starting channels: #{enabled_platforms.join(", ")}")
        @running = true
        enabled_platforms.each { |platform| start_adapter(platform) }
        puts "   📱 Channels started: #{enabled_platforms.join(", ")}"
      end

      # Stop all adapters gracefully.
      def stop
        @running = false
        @mutex.synchronize do
          @adapters.each { |adapter| safe_stop_adapter(adapter) }
          @adapters.clear
        end
        @adapter_threads.each { |t| t.join(1) }
        @adapter_threads.clear
      end

      # @return [Array<Symbol>] platforms currently running
      def running_platforms
        @mutex.synchronize { @adapters.map(&:platform_id) }
      end

      # Hot-reload a single platform adapter with updated config.
      # Stops the existing adapter (if running), then starts a new one if enabled.
      # @param platform [Symbol]
      # @param config [Clacky::ChannelConfig]
      def reload_platform(platform, config)
        # Stop existing adapter for this platform
        @mutex.synchronize do
          existing = @adapters.find { |a| a.platform_id == platform }
          if existing
            safe_stop_adapter(existing)
            @adapters.delete(existing)
          end
        end

        # Start new adapter if enabled
        if config.enabled?(platform)
          @channel_config = config
          start_adapter(platform)
          Clacky::Logger.info("[ChannelManager] :#{platform} adapter reloaded")
        else
          Clacky::Logger.info("[ChannelManager] :#{platform} disabled — adapter not started")
        end
      end


      def start_adapter(platform)
        klass = Adapters.find(platform)
        unless klass
          Clacky::Logger.warn("[ChannelManager] No adapter registered for :#{platform} — skipping")
          return
        end

        raw_config = @channel_config.platform_config(platform)
        Clacky::Logger.info("[ChannelManager] Initializing :#{platform} adapter")
        adapter = klass.new(raw_config)

        errors = adapter.validate_config(raw_config)
        if errors.any?
          Clacky::Logger.warn("[ChannelManager] Config errors for :#{platform}: #{errors.join(", ")}")
          return
        end

        @mutex.synchronize { @adapters << adapter }
        Clacky::Logger.info("[ChannelManager] :#{platform} adapter ready, starting thread")

        thread = Thread.new do
          Thread.current.name = "channel-#{platform}"
          adapter_loop(adapter)
        end

        @adapter_threads << thread
      end

      def adapter_loop(adapter)
        Clacky::Logger.info("[ChannelManager] :#{adapter.platform_id} adapter loop started")
        adapter.start do |event|
          summary = event[:text].to_s.lines.first.to_s.strip[0, 80]
          summary = "[image]" if summary.empty? && !event[:files].to_a.empty?
          Clacky::Logger.info("[ChannelManager] :#{adapter.platform_id} message from #{event[:user_id]} in #{event[:chat_id]}: #{summary}")
          route_message(adapter, event)
        rescue StandardError => e
          Clacky::Logger.warn("[ChannelManager] Error routing :#{adapter.platform_id} message: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
          adapter.send_text(event[:chat_id], "Error: #{e.message}")
        end
      rescue StandardError => e
        Clacky::Logger.warn("[ChannelManager] :#{adapter.platform_id} adapter crashed: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
        if @running
          Clacky::Logger.info("[ChannelManager] :#{adapter.platform_id} restarting in 5s...")
          sleep 5
          retry
        end
      end

      def route_message(adapter, event)
        text  = event[:text]&.strip
        files = event[:files] || []
        return if (text.nil? || text.empty?) && files.empty?

        # Handle built-in commands
        if text&.start_with?("/")
          handle_command(adapter, event, text)
          return
        end

        session_id = resolve_session(event)
        session_id = auto_create_session(adapter, event) unless session_id

        session = @registry.get(session_id)
        unless session
          Clacky::Logger.warn("[ChannelManager] Session #{session_id[0, 8]} not found in registry after create")
          adapter.send_text(event[:chat_id], "Failed to initialize session. Please try again.")
          return
        end

        Clacky::Logger.info("[ChannelManager] Routing to session #{session_id[0, 8]} (status=#{session[:status]})")

        if session[:status] == :running
          Clacky::Logger.info("[ChannelManager] Session busy, rejecting message")
          adapter.send_text(event[:chat_id], "Still working on the previous task. Send `/stop` to interrupt.")
          return
        end

        agent  = session[:agent]
        web_ui = session[:ui]

        # Update reply context so responses thread under the current message.
        # channel_ui is bound to the session for its full lifetime (created in auto_create_session).
        channel_ui_for_session(session_id)&.update_message_context(event)

        # Sync the inbound message to WebUI so it shows up in the browser session.
        # source: :channel prevents the message from being echoed back to the IM channel.
        web_ui&.show_user_message(text, source: :channel) unless text.nil? || text.empty?

        # Acknowledge to the IM channel only — WebUI doesn't need a "Thinking..." noise.
        adapter.send_text(event[:chat_id], "Thinking...")

        @run_agent_task.call(session_id, agent) do
          agent.run(text, files: files)
        end
      end

      def handle_command(adapter, event, text)
        chat_id = event[:chat_id]
        key     = channel_key(event)

        case text
        when /\A\/bind\s+(\S+)\z/i
          arg = Regexp.last_match(1)
          # Support numeric index from /list (1-based)
          session_id = if arg =~ /\A\d+\z/
            recent = @registry.list.last(5).reverse
            idx = arg.to_i - 1
            recent[idx]&.fetch(:id, nil)
          else
            arg
          end
          unless session_id && @registry.get(session_id)
            adapter.send_text(chat_id, "Session not found. Use /list to see available sessions.")
            return
          end

          # Detach channel_ui from the old session's web_ui, reattach to the new one.
          old_session_id = resolve_session(event)
          channel_ui = old_session_id ? channel_ui_for_session(old_session_id) : nil

          if channel_ui
            @registry.with_session(old_session_id) { |s| s[:ui]&.unsubscribe_channel(channel_ui); s.delete(:channel_ui) }
          else
            channel_ui = ChannelUIController.new(event, adapter)
          end

          bind_key_to_session(key, session_id)
          @registry.with_session(session_id) do |s|
            s[:ui]&.subscribe_channel(channel_ui)
            s[:channel_ui] = channel_ui
          end

          Clacky::Logger.info("[ChannelManager] Bound #{key} -> session #{session_id[0, 8]}")
          adapter.send_text(chat_id, "Bound to session `#{session_id[0, 8]}`.")

        when "/stop"
          session_id = resolve_session(event)
          unless session_id
            adapter.send_text(chat_id, "No session bound.")
            return
          end
          @interrupt_session.call(session_id)
          adapter.send_text(chat_id, "Task interrupted.")

        when "/unbind"
          unbound = false
          @registry.list.each do |summary|
            @registry.with_session(summary[:id]) do |s|
              unbound = true if s[:channel_keys]&.delete(key)
            end
          end
          adapter.send_text(chat_id, unbound ? "Unbound." : "No binding found.")

        when "/status"
          session_id = resolve_session(event)
          if session_id
            session = @registry.get(session_id)
            adapter.send_text(chat_id, "Bound to session `#{session_id[0, 8]}` (status: #{session&.dig(:status) || "unknown"})")
          else
            adapter.send_text(chat_id, "No session bound yet. Send any message to auto-create one.")
          end

        when "/list"
          list_sessions(adapter, chat_id)

        else
          adapter.send_text(chat_id,
            "Commands:\n" \
            "  /bind <n|session_id> - switch to a session (use /list to see numbers)\n" \
            "  /unbind - remove binding\n" \
            "  /stop - interrupt current task\n" \
            "  /status - show current binding\n" \
            "  /list - show recent sessions")
        end
      end

      def resolve_session(event)
        key = channel_key(event)
        @registry.list.each do |summary|
          found = nil
          @registry.with_session(summary[:id]) { |s| found = s[:channel_keys]&.include?(key) }
          return summary[:id] if found
        end
        nil
      rescue StandardError => e
        Clacky::Logger.error("[ChannelManager] Session resolve failed: #{e.message}")
        nil
      end

      def auto_create_session(adapter, event)
        key      = channel_key(event)
        platform = event[:platform].to_s
        count    = @mutex.synchronize { @session_counters[platform] += 1 }
        name     = "#{platform}-#{count}"
        session_id = @session_builder.call(name: name, working_dir: Dir.home, source: :channel)
        bind_key_to_session(key, session_id)

        # Create a long-lived ChannelUIController for this session and subscribe it
        # to the session's WebUIController. It stays for the session's full lifetime
        # so all events (agent output, errors, status) flow through web_ui → channel_ui.
        channel_ui = ChannelUIController.new(event, adapter)
        @registry.with_session(session_id) do |s|
          s[:ui]&.subscribe_channel(channel_ui)
          s[:channel_ui] = channel_ui
        end

        Clacky::Logger.info("[ChannelManager] Auto-created session #{session_id[0, 8]} for #{key}")
        session_id
      end

      # Retrieve the ChannelUIController bound to a session (if any).
      def channel_ui_for_session(session_id)
        result = nil
        @registry.with_session(session_id) { |s| result = s[:channel_ui] }
        result
      end

      def bind_key_to_session(key, session_id)
        @registry.list.each do |summary|
          @registry.with_session(summary[:id]) { |s| s[:channel_keys]&.delete(key) }
        end
        @registry.with_session(session_id) do |s|
          s[:channel_keys] ||= Set.new
          s[:channel_keys].add(key)
        end
      end

      def list_sessions(adapter, chat_id)
        sessions = @registry.list.last(5).reverse
        if sessions.empty?
          adapter.send_text(chat_id, "No sessions available.")
          return
        end
        lines = sessions.each_with_index.map do |s, i|
          name = s[:name].to_s.empty? ? "(unnamed)" : s[:name]
          time = s[:updated_at].to_s[5, 11]&.tr("T", " ") || "-"
          "#{i + 1}. `#{s[:id][0, 8]}` #{name} (#{s[:status]}) #{time}"
        end
        adapter.send_text(chat_id, "Recent sessions:\n#{lines.join("\n")}\n\nUse `/bind <n>` to switch.")
      end

      def channel_key(event)
        platform = event[:platform].to_s
        case @binding_mode
        when :chat then "#{platform}:chat:#{event[:chat_id]}"
        else            "#{platform}:user:#{event[:user_id]}"
        end
      end

      def safe_stop_adapter(adapter)
        adapter.stop
      rescue StandardError => e
        warn "[ChannelManager] Error stopping #{adapter.platform_id}: #{e.message}"
      end
    end
  end
end
