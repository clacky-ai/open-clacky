# frozen_string_literal: true

require "digest"

module Clacky
  module Tools
    class Terminal < Base
      # Holds (at most) ONE long-lived PTY shell session that is reused
      # across multiple terminal calls. Reusing the session eliminates the
      # ~1s cold-start cost of `zsh -l -i` / `bash -l -i` on every command.
      #
      # Reuse rules:
      #   - Only non-background, non-dedicated calls take from the persistent
      #     slot. background / env-overridden calls spawn a fresh session.
      #   - Before each call we diff rc-file mtime(s); if changed, we
      #     `source` them once inside the live shell so the user sees freshly
      #     installed PATH / functions / aliases on the very next command.
      #   - If a command leaves the session in a non-clean state (marker not
      #     hit — i.e. the program is still running and interactive), the
      #     session is "donated" to the caller as a dedicated session_id and
      #     the persistent slot is cleared (next call rebuilds a fresh one).
      #   - If cleanup fails or a spawn fails, we transparently fall back to
      #     the old one-shot `bash --noprofile --norc -i` spawn.
      #
      # Thread safety:
      #   - Each persistent session has its own mutex (Session#mutex) that
      #     serialises PTY writes (unchanged).
      #   - The PersistentSessionPool itself is guarded by a class-level
      #     mutex so concurrent terminal calls don't race on acquire/release.
      class PersistentSessionPool
        class << self
          def instance
            @instance ||= new
          end

          def reset!
            if @instance
              begin
                @instance.shutdown!
              rescue StandardError
                # swallow — best-effort during tests / shutdown
              end
            end
            @instance = nil
          end
        end

        def initialize
          @mutex            = Mutex.new
          @session          = nil   # currently-idle persistent session, or nil
          @rc_fingerprint   = nil   # mtime snapshot used to detect rc changes
          @last_env_keys    = []    # keys we exported last time; unset them on env change
          @disabled         = false # set to true after a spawn failure to stop retrying
        end

        # Acquire a persistent session for a new command.
        #
        # Returns [session, reused:] where `session` is a running PTY
        # session ready to accept a command (no concurrent command in
        # flight). Raises SpawnFailed if we can't build one.
        #
        # `reused:` is true when an existing session was handed out; false
        # when we had to spawn a fresh one.
        #
        # Side effects when reusing:
        #   - Sources rc files if their mtimes changed.
        #   - `cd`s to `cwd` if given.
        #   - Resets env vars that were exported last time and exports the
        #     new ones (only when `env` is non-nil).
        def acquire(runner:, cwd: nil, env: nil)
          @mutex.synchronize do
            return [nil, false] if @disabled

            # 1) Make sure the stored session is still healthy.
            if @session
              unless session_healthy?(@session)
                drop_locked
              end
            end

            # 2) Spawn a fresh one if we don't have anything warm.
            unless @session
              begin
                @session = runner.spawn_persistent_session
              rescue StandardError => e
                @disabled = true
                raise SpawnFailed, e.message
              end
              @rc_fingerprint = current_rc_fingerprint
              @last_env_keys  = []
              reused = false
            else
              reused = true
            end

            # 3) If rc files changed since last use, re-source them once.
            if reused && rc_changed?
              runner.source_rc_in_session(@session, rc_files_for_shell(@session.shell_name))
              @rc_fingerprint = current_rc_fingerprint
            end

            # 4) Reset env — unset old, export new.
            if env && !env.empty?
              new_keys = env.keys.map(&:to_s)
              to_unset = @last_env_keys - new_keys
              runner.reset_env_in_session(@session, unset_keys: to_unset, set_env: env)
              @last_env_keys = new_keys
            elsif !@last_env_keys.empty?
              runner.reset_env_in_session(@session, unset_keys: @last_env_keys, set_env: {})
              @last_env_keys = []
            end

            # 5) cd to the requested directory.
            if cwd && Dir.exist?(cwd.to_s)
              runner.cd_in_session(@session, cwd.to_s)
            end

            session = @session
            # Remove it from the slot for the duration of the command so
            # a concurrent caller can't grab the same shell mid-run.
            @session = nil

            [session, reused]
          end
        end

        # Put a session back into the persistent slot after a successful
        # command. Returns true if stored (caller keeps the session),
        # false if the slot was already filled or the session is unhealthy
        # (caller MUST clean up the session — fds and process — itself).
        def release(session)
          @mutex.synchronize do
            if @session.nil? && session_healthy?(session)
              @session = session
              true
            else
              false
            end
          end
        end

        # The caller has decided the session is unusable (e.g. command left
        # an interactive program running). Forget it without killing — the
        # caller is keeping the PTY alive for their own use.
        def discard
          @mutex.synchronize { @session = nil }
        end

        # Shut the persistent session down (typically at_exit).
        def shutdown!
          @mutex.synchronize do
            sess = @session
            @session = nil
            next unless sess
            begin
              Process.kill("TERM", sess.pid)
            rescue StandardError
              # ignore
            end
            close_fds(sess)
          end
        end

        def drop_locked
          sess = @session
          @session = nil
          return unless sess
          begin
            Process.kill("TERM", sess.pid)
          rescue StandardError
            # ignore
          end
          close_fds(sess)
          SessionManager.forget(sess.id)
        end

        private :drop_locked

        # Close all open file descriptors on a session struct. Safe to call
        # multiple times (all closes are rescue-wrapped).
        private def close_fds(session)
          session.log_io&.close rescue nil
          session.writer&.close rescue nil
          session.reader&.close rescue nil
        end

        def session_healthy?(session)
          return false unless session
          return false if %w[exited killed].include?(session.status.to_s)
          # Probe the child process to make sure it's still alive.
          begin
            Process.kill(0, session.pid)
            true
          rescue Errno::ESRCH
            false
          rescue StandardError
            # EPERM etc. — assume alive
            true
          end
        end

        private :session_healthy?

        # --- rc mtime tracking ---------------------------------------------------

        def current_rc_fingerprint
          files = rc_files_for_shell(nil) # superset of all known rc files
          files.each_with_object({}) do |path, h|
            h[path] = File.mtime(path).to_f if File.exist?(path)
          end
        end

        private :current_rc_fingerprint

        def rc_changed?
          new_fp = current_rc_fingerprint
          changed = (new_fp != @rc_fingerprint)
          changed
        end

        private :rc_changed?

        # Return the rc files relevant to the given shell, in the *startup*
        # order the shell itself would read them. This order matters when
        # we re-source after a user edit: later files may depend on vars /
        # PATH prefixes set by earlier ones (e.g. `.zshrc` invoking
        # `mise activate zsh` which expects `~/.local/bin` already on PATH
        # from `.zshenv` / `.zprofile`).
        #
        # zsh order:  .zshenv  ->  .zprofile (login)  ->  .zshrc (interactive)
        # bash order: .profile / .bash_profile (login)  ->  .bashrc
        #
        # If shell_name is nil (used by current_rc_fingerprint when we have
        # no session), we return a superset so we always catch changes
        # regardless of shell.
        def rc_files_for_shell(shell_name)
          home = ENV["HOME"].to_s
          case shell_name
          when "zsh"
            %w[.zshenv .zprofile .zshrc]
          when "bash"
            %w[.profile .bash_profile .bashrc]
          else
            %w[.zshenv .zprofile .zshrc .profile .bash_profile .bashrc]
          end.map { |f| File.join(home, f) }.select { |f| File.exist?(f) }
        end

        private :rc_files_for_shell
      end

      # Raised by the pool when a persistent spawn can't be created; callers
      # should fall back to a one-shot session.
      class SpawnFailed < StandardError; end
    end
  end
end

# Ensure the persistent shell is cleaned up on interpreter exit. Session-
# level kill_all! in SessionManager handles anything that's still registered,
# but we also explicitly SIGTERM the pool's current slot so the child shell
# doesn't linger.
at_exit do
  begin
    Clacky::Tools::Terminal::PersistentSessionPool.instance.shutdown!
  rescue StandardError
    # never raise from at_exit
  end
end
