# frozen_string_literal: true

module Clacky
  module Server
    # SessionRegistry is the single authoritative source for session state.
    #
    # It owns two concerns:
    #   1. Runtime state  — agent instance, thread, status, pending_task, idle_timer.
    #   2. Session list   — reads from disk (via session_manager) and enriches with
    #                       live runtime status. `list` is the only place the session
    #                       list is assembled; no callers should build it elsewhere.
    #
    # Lazy restore: `ensure(session_id)` loads a disk session into the registry on
    # demand. All session-specific APIs call this before touching the registry so
    # disk-only sessions (e.g. loaded via loadMore) just work transparently.
    #
    # Thread safety: all public methods are protected by a Mutex.
    class SessionRegistry
      SESSION_TIMEOUT = 24 * 60 * 60 # 24 hours of inactivity before cleanup

      # session_manager: Clacky::SessionManager instance
      # session_restorer: callable(session_data) → session_id — builds agent + wires into registry
      def initialize(session_manager: nil, session_restorer: nil)
        @sessions         = {}
        @mutex            = Mutex.new
        @session_manager  = session_manager
        @session_restorer = session_restorer
        # Tracks sessions currently being restored from disk.
        # Other threads calling ensure() for the same id will wait via @restore_cond
        # instead of seeing a half-built session (agent=nil).
        @restoring        = {}
        @restore_cond     = ConditionVariable.new
      end

      # Create a new (empty) session entry and return its id.
      # agent/ui/thread are set later via with_session once they are constructed.
      def create(session_id:)
        raise ArgumentError, "session_id is required" if session_id.nil? || session_id.empty?

        session = {
          id:                   session_id,
          status:               :idle,
          error:                nil,
          updated_at:           Time.now,
          agent:                nil,
          ui:                   nil,
          thread:               nil,
          idle_timer:           nil,
          pending_task:         nil,
          pending_working_dir:  nil
        }

        @mutex.synchronize { @sessions[session_id] = session }
        session_id
      end

      # Ensure a session is in the registry, loading from disk if necessary.
      # Returns true if the session is now available, false if not found anywhere.
      #
      # Thread-safe: if two threads race on the same session_id, the second one
      # waits for the first to finish restoring (including agent construction) rather
      # than seeing a half-built entry with agent=nil.
      def ensure(session_id)
        session_data = nil

        @mutex.synchronize do
          # Already fully ready — fast path.
          return true if @sessions.key?(session_id)

          # Another thread is currently restoring this session — wait for it.
          if @restoring[session_id]
            @restore_cond.wait(@mutex) until !@restoring[session_id]
            return @sessions.key?(session_id)
          end

          return false unless @session_manager && @session_restorer

          session_data = @session_manager.load(session_id)
          return false unless session_data

          # Mark as "restore in progress" so concurrent callers wait.
          @restoring[session_id] = true
        end

        # Run the (potentially slow) restore outside the mutex so other sessions
        # are not blocked during agent construction.
        begin
          @session_restorer.call(session_data)
        ensure
          @mutex.synchronize do
            @restoring.delete(session_id)
            @restore_cond.broadcast
          end
        end

        @sessions.key?(session_id)
      end

      # Restore all sessions from disk (up to n per source type) into the registry.
      # Used at startup. Already-registered sessions are skipped.
      def restore_from_disk(n: 5)
        return unless @session_manager && @session_restorer

        all = @session_manager.all_sessions
          .sort_by { |s| s[:created_at] || "" }
          .reverse

        # Take up to n per source type
        counts = Hash.new(0)
        all.each do |session_data|
          src = (session_data[:source] || "manual").to_s
          next if counts[src] >= n
          next if exist?(session_data[:session_id])
          @session_restorer.call(session_data)
          counts[src] += 1
        end
      end

      # Retrieve a session hash by id (returns nil if not found).
      def get(session_id)
        @mutex.synchronize { @sessions[session_id]&.dup }
      end

      # Update arbitrary runtime fields of a session (status, error, pending_*, etc.).
      def update(session_id, **fields)
        @mutex.synchronize do
          session = @sessions[session_id]
          return false unless session

          fields[:updated_at] = Time.now
          session.merge!(fields)
          true
        end
      end

      # Return a session list from disk enriched with live registry status.
      # Sorted by created_at descending (newest first).
      #
      # Parameters (all optional, independent):
      #   source:  "manual"|"cron"|"channel"|"setup"|nil
      #            nil = no source filter (all sessions)
      #   profile: "general"|"coding"|nil
      #            nil = no agent_profile filter
      #   limit:   max sessions to return
      #   before:  ISO8601 cursor — only sessions with created_at < before
      #
      # source and profile are orthogonal — either can be nil independently.
      def list(limit: nil, before: nil, source: nil, profile: nil)
        return [] unless @session_manager

        live = @mutex.synchronize do
          @sessions.transform_values do |s|
            model_info = s[:agent]&.current_model_info
            { status: s[:status], error: s[:error], model: model_info&.dig(:model) }
          end
        end

        all = @session_manager.all_sessions  # already sorted newest-first

        # ── source filter ────────────────────────────────────────────────────
        all = all.select { |s| s_source(s) == source } if source
        # source == nil → no filter, return all

        # ── profile filter ───────────────────────────────────────────────────
        all = all.select { |s| (s[:agent_profile] || "general").to_s == profile } if profile

        all = all.select { |s| (s[:created_at] || "") < before } if before
        all = all.first(limit) if limit

        all.map do |s|
          id = s[:session_id]
          ls = live[id]
          {
            id:            id,
            name:          s[:name] || "",
            status:        ls ? ls[:status].to_s : "idle",
            error:         ls ? ls[:error] : nil,
            model:         ls&.dig(:model),
            source:        s_source(s),
            agent_profile: (s[:agent_profile] || "general").to_s,
            working_dir:   s[:working_dir],
            created_at:    s[:created_at],
            updated_at:    s[:updated_at],
            total_tasks:   s.dig(:stats, :total_tasks) || 0,
            total_cost:    s.dig(:stats, :total_cost_usd) || 0.0,
          }
        end
      end


      # Normalize source field from a disk session hash.
      # "system" is a legacy value renamed to "setup" — treat them as equivalent.
      def s_source(s)
        src = (s[:source] || "manual").to_s
        src == "system" ? "setup" : src
      end

      public

      # Delete a session from registry (and interrupt its thread).
      def delete(session_id)
        @mutex.synchronize do
          session = @sessions.delete(session_id)
          return false unless session

          session[:idle_timer]&.cancel
          session[:thread]&.raise(Clacky::AgentInterrupted, "Session deleted")
          true
        end
      end

      # True if the session exists in registry (runtime).
      def exist?(session_id)
        @mutex.synchronize { @sessions.key?(session_id) }
      end

      # Execute a block with exclusive access to the raw session hash.
      def with_session(session_id)
        @mutex.synchronize do
          session = @sessions[session_id]
          return nil unless session
          yield session
        end
      end

      # Remove sessions idle longer than SESSION_TIMEOUT.
      def cleanup_stale!
        cutoff = Time.now - SESSION_TIMEOUT
        @mutex.synchronize do
          @sessions.delete_if do |_id, session|
            session[:status] == :idle && session[:updated_at] < cutoff
          end
        end
      end

      # Build a summary hash for API responses (for in-registry sessions).
      # Used when we need live agent fields (name, cost, etc.) after ensure().
      def session_summary(session_id)
        session = @mutex.synchronize { @sessions[session_id] }
        return nil unless session
        agent = session[:agent]
        return nil unless agent

        model_info = agent.current_model_info
        {
          id:              session[:id],
          name:            agent.name,
          working_dir:     agent.working_dir,
          status:          session[:status],
          created_at:      agent.created_at,
          updated_at:      session[:updated_at].iso8601,
          total_tasks:     agent.total_tasks || 0,
          total_cost:      agent.total_cost  || 0.0,
          error:           session[:error],
          model:           model_info&.dig(:model),
          permission_mode: agent.permission_mode,
          source:          agent.source.to_s,
          agent_profile:   agent.agent_profile.name,
        }
      end
    end
  end
end
