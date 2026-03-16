# frozen_string_literal: true

module Clacky
  module Server
    # SessionRegistry manages runtime state for active Agent sessions in the web server.
    # Each entry holds the Agent instance plus web-server-specific runtime fields that
    # the Agent itself doesn't own: status, error, execution thread, UI controller, and
    # transient scheduling fields (pending_task / pending_working_dir).
    #
    # Fields that already live on the Agent (name, created_at, working_dir, total_tasks,
    # total_cost) are read directly from the agent — the registry never duplicates them.
    #
    # Thread safety: all public methods are protected by a Mutex.
    class SessionRegistry
      SESSION_TIMEOUT = 24 * 60 * 60 # 24 hours of inactivity before cleanup

      def initialize
        @sessions = {}
        @mutex    = Mutex.new
      end

      # Create a new session entry and return its id.
      # session_id must come from the caller (use SessionManager.generate_id).
      # agent/ui/thread are set later via with_session once they are constructed.
      # Pass hidden: true for system/channel sessions that should not appear in the UI list.
      def create(session_id:, hidden: false)
        raise ArgumentError, "session_id is required" if session_id.nil? || session_id.empty?

        session = {
          id:                   session_id,
          status:               :idle,   # :idle | :running | :error
          error:                nil,
          updated_at:           Time.now,
          hidden:               hidden,  # true = exclude from UI session list (e.g. channel sessions)
          agent:                nil,
          ui:                   nil,
          thread:               nil,
          idle_timer:           nil,     # IdleCompressionTimer instance
          pending_task:         nil,
          pending_working_dir:  nil
        }

        @mutex.synchronize { @sessions[session_id] = session }
        session_id
      end

      # Retrieve a session hash by id (returns nil if not found).
      def get(session_id)
        @mutex.synchronize { @sessions[session_id]&.dup }
      end

      # Update arbitrary runtime fields of a session (status, error, pending_*, etc.).
      # Always stamps updated_at.
      def update(session_id, **fields)
        @mutex.synchronize do
          session = @sessions[session_id]
          return false unless session

          fields[:updated_at] = Time.now
          session.merge!(fields)
          true
        end
      end

      # Return a lightweight summary list (no agent/ui/thread objects) for API responses.
      # Sorted newest-first using agent.created_at (ISO8601 strings sort lexicographically).
      # Hidden sessions (e.g. channel/IM sessions) are excluded from the list.
      def list
        @mutex.synchronize do
          @sessions.values
                   .reject { |s| s[:hidden] }
                   .map { |s| session_summary(s) }
                   .sort_by { |s| s[:created_at] }
                   .reverse
        end
      end

      # Delete a session. Also interrupts any running agent thread.
      def delete(session_id)
        @mutex.synchronize do
          session = @sessions.delete(session_id)
          return false unless session

          session[:idle_timer]&.cancel
          session[:thread]&.raise(Clacky::AgentInterrupted, "Session deleted")
          true
        end
      end

      # True if the session exists.
      def exist?(session_id)
        @mutex.synchronize { @sessions.key?(session_id) }
      end

      # Execute a block with exclusive access to the raw session hash.
      # Use this to set agent/ui/thread references that must not be dup'd.
      def with_session(session_id)
        @mutex.synchronize do
          session = @sessions[session_id]
          return nil unless session

          yield session
        end
      end

      # Remove sessions that have been idle longer than SESSION_TIMEOUT.
      def cleanup_stale!
        cutoff = Time.now - SESSION_TIMEOUT
        @mutex.synchronize do
          @sessions.delete_if do |_id, session|
            session[:status] == :idle && session[:updated_at] < cutoff
          end
        end
      end

      private

      # Build a summary hash for API responses, reading authoritative fields from the
      # agent and runtime-only fields from the registry entry.
      def session_summary(session)
        agent      = session[:agent]
        model_info = agent&.current_model_info
        {
          id:              session[:id],
          name:            agent&.name        || "",
          working_dir:     agent&.working_dir || "",
          status:          session[:status],
          created_at:      agent&.created_at  || session[:updated_at].iso8601,
          updated_at:      session[:updated_at].iso8601,
          total_tasks:     agent&.total_tasks || 0,
          total_cost:      agent&.total_cost  || 0.0,
          error:           session[:error],
          model:           model_info&.dig(:model) || "",
          permission_mode: agent&.permission_mode || ""
        }
      end
    end
  end
end
