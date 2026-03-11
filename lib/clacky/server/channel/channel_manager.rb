# frozen_string_literal: true

require_relative "channel_ui_controller"

module Clacky
  module Channel
    # ChannelManager starts and supervises IM platform adapter threads.
    # When an inbound message arrives it:
    #   1. Resolves (or creates) a Server Session via in-memory session map
    #   2. Retrieves the WebUIController for that session
    #   3. Creates a ChannelUIController and subscribes it to the WebUIController
    #   4. Runs the agent task in a new thread (same pattern as HttpServer)
    #   5. Unsubscribes the ChannelUIController when the task finishes
    #
    # Thread model: each adapter runs two long-lived threads (read loop + ping).
    # ChannelManager itself is non-blocking — call #start from HttpServer after
    # the WEBrick server has started.
    #
    # Session mapping is kept purely in memory: (platform, user_id) or
    # (platform, chat_id) → session_id. Mappings are lost on restart, which is
    # fine — a fresh session is created automatically on the next message.
    class ChannelManager
      # @param session_registry [Clacky::Server::SessionRegistry]
      # @param session_builder  [Proc] accepts keyword args matching build_session signature
      # @param channel_config   [Clacky::ChannelConfig]
      # @param binding_mode     [:user | :chat] how to map IM identities to sessions
      def initialize(session_registry:, session_builder:, channel_config:, binding_mode: :user)
        @registry        = session_registry
        @session_builder = session_builder
        @channel_config  = channel_config
        @binding_mode    = binding_mode
        @session_map     = {}  # "platform:mode:id" => session_id (in-memory only)
        @adapters        = []
        @adapter_threads = []
        @running         = false
        @mutex           = Mutex.new
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
        @adapter_threads.each { |t| t.join(5) }
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

      private

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
          Clacky::Logger.info("[ChannelManager] :#{adapter.platform_id} message from #{event[:user_id]} in #{event[:chat_id]}: #{event[:text].to_s[0, 80]}")
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
        text = event[:text]&.strip
        return if text.nil? || text.empty?

        session_id = resolve_session(event)
        unless session_id
          Clacky::Logger.warn("[ChannelManager] Could not resolve session for event: #{event.inspect}")
          return
        end

        session = @registry.get(session_id)
        unless session
          Clacky::Logger.warn("[ChannelManager] Could not retrieve session #{session_id[0, 8]} from registry")
          return
        end

        Clacky::Logger.info("[ChannelManager] Routing to session #{session_id[0, 8]} (status=#{session[:status]})")

        # Prevent running a new task while the agent is already busy
        if session[:status] == :running
          Clacky::Logger.info("[ChannelManager] Session busy, rejecting message")
          adapter.send_text(event[:chat_id], "⏳ Still working on the previous task — please wait...")
          return
        end

        agent  = session[:agent]
        web_ui = session[:ui]

        channel_ui = ChannelUIController.new(event, adapter)

        # Subscribe channel UI to receive all agent output events
        web_ui&.subscribe_channel(channel_ui)

        # Run the agent task in a dedicated thread
        task_thread = Thread.new do
          Thread.current.name = "channel-task-#{session_id[0, 8]}"
          @registry.update(session_id, status: :running)
          agent.run(text)
        rescue StandardError => e
          warn "[ChannelManager] Agent error (#{session_id}): #{e.message}"
          channel_ui.show_error("Agent error: #{e.message}")
        ensure
          web_ui&.unsubscribe_channel(channel_ui)
          @registry.update(session_id, status: :idle)
        end

        @registry.with_session(session_id) { |s| s[:thread] = task_thread }
      end

      def resolve_session(event)
        key = session_map_key(event)

        @mutex.synchronize do
          session_id = @session_map[key]
          # Return existing session_id only if the session is still alive in registry
          return session_id if session_id && @registry.get(session_id)

          # Create a new session (either first time or after server restart)
          platform = event[:platform]
          user_id  = event[:user_id]
          name     = "#{platform.to_s.capitalize} — #{user_id}"
          session_id = @session_builder.call(
            name: name,
            working_dir: Dir.pwd,
            permission_mode: :auto_approve
          )
          @session_map[key] = session_id
          session_id
        end
      rescue StandardError => e
        warn "[ChannelManager] Session resolve failed: #{e.message}"
        nil
      end

      def session_map_key(event)
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
