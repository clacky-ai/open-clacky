# frozen_string_literal: true

module Clacky
  # IdleCompressionTimer triggers memory compression after a period of inactivity.
  #
  # Both CLI and WebUI use the same agent-level compression logic; this class
  # abstracts the "wait N seconds, then compress" pattern so it can be shared.
  #
  # Usage:
  #   timer = IdleCompressionTimer.new(agent: agent, session_manager: sm) do |success|
  #     # called on the compression thread after compression finishes
  #     broadcast_update if success
  #   end
  #   timer.start   # call after each agent run completes
  #   timer.cancel  # call when new user input arrives
  class IdleCompressionTimer
    # Seconds of inactivity before idle compression is triggered
    IDLE_DELAY = 180

    # @param agent [Clacky::Agent] the agent whose messages will be compressed
    # @param session_manager [Clacky::SessionManager, nil] used to persist session after compression
    # @param logger [#call, nil] optional logger lambda: ->(msg, level:) { ... }
    # @param on_compress [Proc, nil] block called after compression attempt with success (bool)
    def initialize(agent:, session_manager: nil, logger: nil, &on_compress)
      @agent           = agent
      @session_manager = session_manager
      @logger          = logger
      @on_compress     = on_compress

      @timer_thread    = nil
      @compress_thread = nil
      @mutex           = Mutex.new
    end

    # Start (or restart) the idle timer.
    # Cancels any existing timer first, then waits IDLE_DELAY seconds before compressing.
    def start
      cancel # reset any existing timer

      @timer_thread = Thread.new do
        Thread.current.name = "idle-compression-timer"
        sleep IDLE_DELAY

        # Kick off compression in a separate thread so it can be interrupted
        compress_thread = Thread.new do
          Thread.current.name = "idle-compression-work"
          run_compression
        end

        @mutex.synchronize { @compress_thread = compress_thread }
        compress_thread.join
        @mutex.synchronize { @compress_thread = nil; @timer_thread = nil }
      end
    end

    # Cancel the timer and any in-progress compression.
    # Safe to call even if the timer is not running.
    def cancel
      @mutex.synchronize do
        @timer_thread&.kill
        @compress_thread&.raise(Clacky::AgentInterrupted, "Idle timer cancelled")
        @timer_thread    = nil
        @compress_thread = nil
      end
    end

    # True if the timer or compression is currently active.
    def active?
      @mutex.synchronize { @timer_thread&.alive? || @compress_thread&.alive? }
    end

    private def run_compression
      success = @agent.trigger_idle_compression

      if success && @session_manager
        @session_manager.save(@agent.to_session_data(status: :success))
      end

      @on_compress&.call(success)
    rescue Clacky::AgentInterrupted
      log("Idle compression cancelled", level: :info)
      @on_compress&.call(false)
    rescue => e
      log("Idle compression error: #{e.message}", level: :error)
      @on_compress&.call(false)
    end

    private def log(message, level: :info)
      @logger&.call(message, level: level)
    end
  end
end
