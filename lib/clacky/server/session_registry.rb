# frozen_string_literal: true

module Clacky
  module Server
    # SessionRegistry manages multiple in-memory Agent sessions for the web server.
    # Each session holds an Agent instance, its WebUIController, and metadata.
    #
    # Thread safety: all public methods are protected by a Mutex.
    class SessionRegistry
      SESSION_TIMEOUT = 24 * 60 * 60 # 24 hours of inactivity before cleanup

      def initialize
        @sessions = {}
        @mutex    = Mutex.new
      end

      # Create a new session and return its id.
      # All arguments are required — use SessionManager.generate_id for session_id.
      def create(name:, working_dir:, session_id:)
        raise ArgumentError, "session_id is required" if session_id.nil? || session_id.empty?

        session = {
          id:          session_id,
          name:        name,
          working_dir: working_dir,
          status:      :idle,         # :idle | :running | :error
          created_at:  Time.now,
          updated_at:  Time.now,
          agent:       nil,
          ui:          nil,
          thread:      nil,
          error:       nil
        }

        @mutex.synchronize { @sessions[session_id] = session }
        session_id
      end

      # Retrieve a session hash by id (returns nil if not found).
      def get(session_id)
        @mutex.synchronize { @sessions[session_id]&.dup }
      end

      # Update arbitrary fields of a session.
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
      def list
        @mutex.synchronize do
          @sessions.values.map { |s| session_summary(s) }
                   .sort_by { |s| s[:created_at] }
                   .reverse
        end
      end

      # Delete a session. Also interrupts any running agent thread.
      def delete(session_id)
        @mutex.synchronize do
          session = @sessions.delete(session_id)
          return false unless session

          # Interrupt running thread if present
          session[:thread]&.raise(Clacky::AgentInterrupted, "Session deleted")
          true
        end
      end

      # True if the session exists.
      def exist?(session_id)
        @mutex.synchronize { @sessions.key?(session_id) }
      end

      # Execute a block with exclusive access to the raw session hash.
      # Use this to set agent/ui/thread references that shouldn't be dup'd.
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

      def session_summary(session)
        agent = session[:agent]
        {
          id:          session[:id],
          name:        session[:name],
          working_dir: session[:working_dir],
          status:      session[:status],
          created_at:  session[:created_at].iso8601,
          updated_at:  session[:updated_at].iso8601,
          total_tasks: agent&.total_tasks || 0,
          total_cost:  agent&.total_cost  || 0.0,
          error:       session[:error]
        }
      end
    end
  end
end
