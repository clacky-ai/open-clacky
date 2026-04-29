# frozen_string_literal: true

module Clacky
  module Utils
    # Spawn child processes in an environment that has the user's shell rc
    # files sourced — so version managers (mise / rbenv / asdf / nvm) and
    # custom PATH entries are active, even when the clacky server itself
    # was started by launchd / a desktop icon with a minimal PATH.
    #
    # ## Approach: manual `source` + `exec`
    #
    # Instead of using `$SHELL -l -i -c` (which prints rc banners, triggers
    # job-control warnings in non-tty contexts, and may not even work as
    # expected under launchd), we build an inline shell snippet:
    #
    #   { source ~/.zshenv; source ~/.zprofile; source ~/.zshrc; } 1>&2
    #   exec <target-cmd>
    #
    # Then invoke it with plain `zsh -c <snippet>` (NO -l / -i flags).
    #
    # Why this wins:
    #
    # - `source ~/.zshrc` runs user's rc code including `eval "$(mise activate zsh)"`
    #   which injects the correct PATH (so `node`/`ruby`/`gem` resolve).
    # - `{ … } 1>&2` redirects ALL rc-time output (banners, welcome msgs,
    #   mise warnings) to stderr, keeping target's stdout CLEAN — critical
    #   for JSON-RPC stdio channels like chrome-devtools-mcp.
    # - `exec` replaces the shell with the target process, so our pipe's
    #   child is the target itself (pid / signals / waitpid all work).
    # - No `-i`, so no "no job control in this shell" warnings.
    # - No `-l` needed because we explicitly source what we need.
    #
    # ## Method: login_shell_command
    #
    # Build argv for `Open3.popen3` / `Process.spawn` that runs `command`
    # with rc files pre-sourced. Returns argv, not a running process —
    # caller picks the right Open3 method for their needs.
    module LoginShell
      # Build argv that runs `command` inside a shell with rc files sourced.
      #
      # @param command [String] shell-ready command (caller quotes user input).
      # @return [Array<String>] argv for Open3.popen3 / Process.spawn.
      def self.login_shell_command(command)
        shell = ENV["SHELL"].to_s
        shell = "/bin/bash" if shell.empty? || !File.executable?(shell)
        name  = File.basename(shell)
        name  = "bash" unless %w[zsh bash].include?(name)
        shell = "/bin/bash" if name == "bash" && !File.executable?(shell)

        rc_sources = rc_source_snippet(name)

        # { rc_sources; } 1>&2 — send rc-time stdout to stderr so target's
        # stdout is pristine. `exec` replaces the shell with target.
        script = "{ #{rc_sources}; } 1>&2; exec #{command}"
        [shell, "-c", script]
      end

      # Per-shell rc source chain. Order matters:
      #   zsh:  .zshenv → .zprofile → .zshrc  (login + interactive equivalent)
      #   bash: .profile → .bash_profile → .bashrc
      def self.rc_source_snippet(shell_name)
        files =
          case shell_name
          when "zsh"  then %w[.zshenv .zprofile .zshrc]
          else             %w[.profile .bash_profile .bashrc]
          end

        files.map { |f| %([ -f "$HOME/#{f}" ] && . "$HOME/#{f}") }.join("; ")
      end
    end
  end
end
