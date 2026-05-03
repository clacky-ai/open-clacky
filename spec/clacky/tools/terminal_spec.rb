# frozen_string_literal: true

require "shellwords"
require "tmpdir"
require "json"

# Specs for the redesigned, unified Terminal tool.
# Contract recap:
#   - `terminal(command: ...)`                     → run a new command
#   - `terminal(session_id:, input: ...)`          → continue a blocked session
#   - `terminal(session_id:, kill: true)`          → kill a session
#
# Response contract:
#   - NO session_id in result → finished; `exit_code` is set
#   - session_id in result    → still running, waiting for input
RSpec.describe Clacky::Tools::Terminal do
  let(:tool) { described_class.new }

  # Keep the spec suite fast: we don't want every "blocked on a prompt"
  # scenario to burn the production 3s idle threshold. 200ms is plenty of
  # time for a child to flush "Name: " before we check, and slashes total
  # suite runtime by ~6x compared to the production default.
  #
  # We also shrink the background-startup collection window: 2s per
  # background launch × 4 background specs = 8s of otherwise-idle waiting.
  # 400ms is still enough for ruby/bash to flush their first line.
  #
  # And we force the persistent shell to be `bash --noprofile --norc -i`
  # rather than the user's interactive login shell (`zsh -l -i`, etc).
  # Real login shells take ~1.2s to initialize on macOS because they
  # source `.zshenv` / `.zprofile` / `.zshrc`, and the pool is discarded
  # every time a command goes idle/times out — which happens in ~20 of
  # these specs. 20 × 1.2s = 24s of pure shell cold-start cost per suite
  # run. A bare bash is ~100ms, dropping that to ~2s.
  before do
    stub_const("Clacky::Tools::Terminal::DEFAULT_IDLE_MS", 200)
    stub_const("Clacky::Tools::Terminal::BACKGROUND_COLLECT_SECONDS", 0.4)
    allow_any_instance_of(Clacky::Tools::Terminal).to receive(:persistent_shell_args)
      .and_return(["/bin/bash", "--noprofile", "--norc", "-i"])
    allow_any_instance_of(Clacky::Tools::Terminal).to receive(:user_shell)
      .and_return(["/bin/bash", "bash"])
  end

  # The PersistentSessionPool is expensive to spawn (~1.2s cold-start for
  # `zsh -l -i` on macOS). Resetting it between every example would cost
  # ~30s per suite run. The pool is specifically designed to recover from
  # dirty state (it drops unhealthy sessions on the next acquire and cds
  # back to the requested cwd), so we only clear it ONCE at suite start.
  #
  # We still kill any *dedicated* sessions left behind between examples —
  # those are per-session (background runs, timed-out commands, blocked
  # prompts), so they won't bleed across tests, but we don't want them
  # lingering as zombie PIDs.
  before(:suite) do
    begin
      Clacky::Tools::Terminal::PersistentSessionPool.reset!
    rescue StandardError
    end
    Clacky::Tools::Terminal::SessionManager.reset!
  end

  after do
    t = Clacky::Tools::Terminal.new
    begin
      Clacky::Tools::Terminal::SessionManager.list.each do |s|
        t.execute(session_id: s.id, kill: true)
      end
    rescue StandardError
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatcher / argument validation
  # ---------------------------------------------------------------------------
  describe "argument validation" do
    it "rejects calls with neither command nor session_id" do
      result = tool.execute
      expect(result).to include(:error)
    end

    it "requires input when session_id is given" do
      result = tool.execute(session_id: 1)
      expect(result).to include(:error)
      expect(result[:error]).to match(/input/i)
    end

    it "requires session_id when kill: true" do
      result = tool.execute(kill: true)
      expect(result).to include(:error)
      expect(result[:error]).to match(/session_id/i)
    end

    it "rejects unknown session_id on continue" do
      result = tool.execute(session_id: 99_999, input: "hi\n")
      expect(result).to include(:error)
      expect(result[:error]).to match(/not found/i)
    end

    it "rejects cwd that does not exist" do
      result = tool.execute(command: "echo hi", cwd: "/nonexistent/path/xyz")
      expect(result).to include(:error)
      expect(result[:error]).to match(/cwd/i)
    end
  end

  # ---------------------------------------------------------------------------
  # One-shot commands (shell mode, auto-closing)
  # ---------------------------------------------------------------------------
  describe "one-shot commands (shell mode)" do
    it "runs a simple command and returns exit_code without session_id" do
      result = tool.execute(command: "echo hello")
      expect(result).not_to have_key(:session_id)
      expect(result[:exit_code]).to eq(0)
      expect(result[:output]).to include("hello")
    end

    it "captures non-zero exit codes" do
      result = tool.execute(command: "bash -c 'exit 42'")
      expect(result).not_to have_key(:session_id)
      expect(result[:exit_code]).to eq(42)
    end

    it "captures pipeline exit (last command wins)" do
      result = tool.execute(command: "true | false")
      expect(result[:exit_code]).to eq(1)
    end

    it "strips ANSI escape sequences from output" do
      result = tool.execute(command: %q{printf '\033[31mred\033[0m\n'})
      expect(result[:output]).to include("red")
      expect(result[:output]).not_to match(/\e\[31m/)
    end

    it "starts the command in the given cwd" do
      result = tool.execute(command: "pwd", cwd: "/tmp")
      expect(result[:output]).to include("/tmp")
    end

    it "does not expose a session_id to callers after marker" do
      result = tool.execute(command: "echo done")
      # Completed commands should NOT leak a session_id; a persistent
      # shell may still be registered internally for reuse, but the
      # caller's response is final.
      expect(result).not_to include(:session_id)
      expect(result[:exit_code]).to eq(0)
    end

    it "passes env vars through" do
      result = tool.execute(command: "echo $MY_VAR", env: { "MY_VAR" => "hi-from-env" })
      expect(result[:output]).to include("hi-from-env")
    end
  end

  # ---------------------------------------------------------------------------
  # Raw mode (non-shell commands)
  # ---------------------------------------------------------------------------
  describe "raw-mode commands" do
    it "runs a python one-liner and returns exit_code on EOF" do
      result = tool.execute(command: "python3 -c 'print(\"raw-ok\")'")
      expect(result[:output]).to include("raw-ok")
      expect(result).not_to have_key(:session_id)   # EOF auto-closed
    end
  end

  # ---------------------------------------------------------------------------
  # Interactive handshake (command blocks on prompt → continue with input)
  # ---------------------------------------------------------------------------
  describe "interactive prompt handshake" do
    it "returns session_id when the command blocks on stdin" do
      result = tool.execute(
        command: %q{bash -c 'read -p "Name: " name && echo "hi $name"'},
        timeout: 3
      )
      # Prompt appeared but command hasn't finished → we get a session_id back.
      expect(result[:session_id]).to be_a(Integer)
      expect(result[:output]).to include("Name:")
      expect(result).not_to have_key(:exit_code)
    end

    it "resumes a waiting session via session_id+input" do
      first = tool.execute(
        command: %q{bash -c 'read -p "Name: " name && echo "hi $name"'},
        timeout: 3
      )
      sid = first[:session_id]
      expect(sid).to be_a(Integer)

      second = tool.execute(session_id: sid, input: "Alice\n", timeout: 5)
      expect(second[:output]).to include("hi Alice")
      expect(second).not_to have_key(:session_id)    # command finished
      expect(second[:exit_code]).to eq(0)
    end

    xit "translates \n to \r so raw-mode TUIs see 'Enter' (not a literal newline char)" do
      # A raw-mode Ruby reader: STDIN.raw { STDIN.getc } reads ONE byte, no
      # line-discipline translation. If we sent \n, the child would see 0x0A.
      # We expect 0x0D because the tool should have translated it.
      script = <<~'RUBY'
        require "io/console"
        STDOUT.sync = true
        print "ready\n"
        ch = STDIN.raw { STDIN.getc }
        printf "got=0x%02X\n", ch.ord
      RUBY

      first = tool.execute(command: %(ruby -e #{Shellwords.escape(script)}), timeout: 2)
      sid = first[:session_id]
      expect(sid).to be_a(Integer), "expected child to block on getc, got: #{first.inspect}"

      # AI sends the conventional "\n" meaning "press Enter".
      second = tool.execute(session_id: sid, input: "\n", timeout: 5)
      expect(second[:output]).to include("got=0x0D"),
        "expected raw-mode child to receive \r (0x0D), got: #{second[:output].inspect}"
      expect(second[:exit_code]).to eq(0)
    end

    it "does not treat command output containing a bogus marker as completion" do
      # Output literal looks like a marker but uses a different token.
      result = tool.execute(
        command: %q{echo "__CLACKY_DONE_fakeToken_0__"}
      )
      expect(result[:exit_code]).to eq(0)
      expect(result[:output]).to include("__CLACKY_DONE_fakeToken_0__")
    end

    it "returns early (well before timeout) when output goes idle at a prompt" do
      # The command produces output ("Name: ") then blocks on stdin. Without
      # idle detection, we would wait the full timeout. With our test-suite
      # idle override (200ms, see top-level before hook), we should return
      # in well under a second.
      t0 = Time.now
      result = tool.execute(
        command: %q{bash -c 'read -p "Name: " name && echo "hi $name"'},
        timeout: 10
      )
      elapsed = Time.now - t0

      expect(result[:session_id]).to be_a(Integer)
      expect(result[:output]).to include("Name:")
      expect(elapsed).to be < 3.0   # well under the 10s timeout
    end
  end

  # ---------------------------------------------------------------------------
  # Kill
  # ---------------------------------------------------------------------------
  describe "kill" do
    it "kills a waiting session and forgets it" do
      first = tool.execute(
        command: %q{bash -c 'read -p "go? " x'},
        timeout: 2
      )
      sid = first[:session_id]
      expect(sid).to be_a(Integer)

      killed = tool.execute(session_id: sid, kill: true)
      expect(killed[:killed]).to eq(true)
      expect(killed[:session_id]).to eq(sid)

      # Subsequent continue is rejected.
      followup = tool.execute(session_id: sid, input: "hi\n")
      expect(followup).to include(:error)
    end

    it "errors when killing an unknown session" do
      result = tool.execute(session_id: 99_999, kill: true)
      expect(result).to include(:error)
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple concurrent sessions
  # ---------------------------------------------------------------------------
  describe "concurrent sessions" do
    it "allows multiple interactive sessions at once, tracked by distinct ids" do
      a = tool.execute(command: %q{bash -c 'read -p "A? " x && echo A=$x'}, timeout: 3)
      b = tool.execute(command: %q{bash -c 'read -p "B? " y && echo B=$y'}, timeout: 3)

      expect(a[:session_id]).not_to eq(b[:session_id])

      ra = tool.execute(session_id: a[:session_id], input: "one\n", timeout: 5)
      rb = tool.execute(session_id: b[:session_id], input: "two\n", timeout: 5)

      expect(ra[:output]).to include("A=one")
      expect(rb[:output]).to include("B=two")
      expect(ra[:exit_code]).to eq(0)
      expect(rb[:exit_code]).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout / still-running case
  # ---------------------------------------------------------------------------
  describe "long-running commands" do
    it "returns a session_id when a command runs past the timeout" do
      result = tool.execute(command: "sleep 5", timeout: 1)
      # Didn't finish in time, so we hand control back to the AI.
      expect(result[:session_id]).to be_a(Integer)
      expect(result).not_to have_key(:exit_code)
      # Clean up.
      tool.execute(session_id: result[:session_id], kill: true)
    end
  end

  # ---------------------------------------------------------------------------
  # Security integration (make_safe is applied to `command` only)
  # ---------------------------------------------------------------------------
  describe "security layer" do
    it "blocks sudo commands before spawning a PTY" do
      result = tool.execute(command: "sudo ls /")
      expect(result[:security_blocked]).to eq(true)
      expect(result[:error]).to match(/\[Security\]/)
      expect(result).not_to have_key(:session_id)
    end

    it "moves rm'd files into the project trash via the safe-rm shell function" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "doomed.txt")
        File.write(path, "bye")

        # Discover where the persistent shell thinks the trash dir is.
        # (The spec suite reuses a single pooled shell, so its
        # CLACKY_TRASH_DIR is whatever the first spawn's cwd computed —
        # not necessarily the current `dir`.)
        probe = tool.execute(command: 'printf "TRASH=%s\n" "$CLACKY_TRASH_DIR"', cwd: dir)
        trash = probe[:output][/TRASH=(\S+)/, 1]
        expect(trash).not_to be_nil
        expect(trash).not_to be_empty

        result = tool.execute(command: "rm #{path}", cwd: dir)
        expect(result[:exit_code]).to eq(0)
        # rm is intercepted by a shell function at runtime (not by the
        # Ruby Security layer), so there's no :security_rewrite entry.
        expect(result[:security_rewrite]).to be_nil
        # The file is gone from its original location ...
        expect(File.exist?(path)).to be(false)
        # ... and appears in the trash with a matching metadata sidecar.
        moved = Dir.glob(File.join(trash, "doomed.txt_deleted_*"))
                   .reject { |f| f.end_with?(".metadata.json") }
        expect(moved.size).to be >= 1
        sidecar = "#{moved.last}.metadata.json"
        expect(File.exist?(sidecar)).to be(true)
        meta = JSON.parse(File.read(sidecar))
        expect(meta["original_path"]).to eq(File.expand_path(path))
        expect(meta["deleted_by"]).to eq("clacky_rm_shell")
      ensure
        # Best-effort cleanup of files we leaked into the pooled trash.
        Dir.glob(File.join(trash.to_s, "doomed.txt_deleted_*")).each do |f|
          FileUtils.rm_f(f) if File.file?(f)
        end if trash && !trash.empty?
      end
    end

    it "safe-rm refuses catastrophic targets (e.g. /etc) via the shell function" do
      Dir.mktmpdir do |dir|
        result = tool.execute(command: "rm -rf /etc", cwd: dir)
        # Shell function emits an error to stderr and returns non-zero;
        # /etc must still exist.
        expect(result[:exit_code]).not_to eq(0)
        expect(result[:output]).to include("refused dangerous target")
        expect(Dir.exist?("/etc")).to be(true)
      end
    end

    it "does NOT rewrite rm inside a heredoc body (regression: multi-line commands)" do
      # A command that writes a heredoc whose body contains the word 'rm'
      # must be executed as-is — not mangled by the old static rewriter,
      # which would have treated the heredoc body tokens as rm targets.
      Dir.mktmpdir do |dir|
        script = File.join(dir, "heredoc_victim.txt")
        cmd = <<~CMD
          cat > #{script} <<'PYEOF'
          this line mentions rm but must NOT be interpreted as a command
          rm is just a word here
          PYEOF
        CMD
        result = tool.execute(command: cmd, cwd: dir)
        expect(result[:exit_code]).to eq(0)
        expect(File.exist?(script)).to be(true)
        expect(File.read(script)).to include("rm is just a word here")
      end
    end

    it "does NOT apply security rewriting to input (input is a reply, not a command)" do
      # Start a session that reads a line from stdin.
      out = tool.execute(command: %(ruby -e 'puts STDIN.gets'), timeout: 1)
      # Either we got a session back (blocked on gets), or it finished too fast; handle both.
      if out[:session_id]
        sid = out[:session_id]
        # `rm -rf /` as *input* is just text sent to a running program — must not be blocked.
        reply = tool.execute(session_id: sid, input: "rm -rf /\n")
        expect(reply).not_to include(:security_blocked)
      else
        # In the unlikely event the child finished before we could catch it, just pass.
        expect(out[:exit_code]).not_to be_nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Background mode
  # ---------------------------------------------------------------------------
  describe "background mode" do
    it "returns a session_id with state=background for a long-running process" do
      result = tool.execute(command: "sleep 5", background: true)
      expect(result[:session_id]).to be_a(Integer)
      expect(result[:state]).to eq("background")
      expect(result).not_to have_key(:exit_code)
      tool.execute(session_id: result[:session_id], kill: true)
    end

    it "captures startup output within the collection window" do
      script = %(ruby -e 'puts "booted"; STDOUT.flush; sleep 5')
      result = tool.execute(command: script, background: true)
      expect(result[:session_id]).to be_a(Integer)
      expect(result[:output].to_s).to include("booted")
      tool.execute(session_id: result[:session_id], kill: true)
    end

    it "returns exit_code (not session_id) when the process crashes during the collection window" do
      result = tool.execute(command: "false", background: true)
      expect(result[:exit_code]).to eq(1)
      expect(result).not_to have_key(:session_id)
    end

    it "supports polling a background session with empty input" do
      # Must still be alive after the 2s background collection window.
      script = %q{ruby -e 'STDOUT.sync=true; 10.times { |i| puts "tick #{i}"; sleep 0.4 }'}
      started = tool.execute(command: script, background: true)
      expect(started[:session_id]).to be_a(Integer)
      sid = started[:session_id]

      # Poll after giving it a moment to produce more output.
      sleep 0.5
      polled = tool.execute(session_id: sid, input: "")
      # Either the process is still alive (session_id again) or it just exited (exit_code).
      if polled[:session_id]
        expect(polled[:output]).to be_a(String)
      else
        expect(polled[:exit_code]).to eq(0)
      end

      # Clean up if still alive.
      tool.execute(session_id: sid, kill: true) if polled[:session_id]
    end
  end

  # ---------------------------------------------------------------------------
  # Persistent-session reuse — the same PTY shell is reused across calls.
  # This is what saves us the ~1s cold-start cost of `zsh -l -i` on every
  # foreground command.
  # ---------------------------------------------------------------------------
  describe "persistent shell reuse" do
    it "reuses the same shell pid across consecutive foreground commands" do
      r1 = tool.execute(command: "echo $$")
      r2 = tool.execute(command: "echo $$")

      pid1 = r1[:output].strip.to_i
      pid2 = r2[:output].strip.to_i

      expect(pid1).to be > 0
      expect(pid1).to eq(pid2)
    end

    it "respects per-call cwd when reusing the shell" do
      tool.execute(command: "echo first", cwd: "/tmp")
      r = tool.execute(command: "pwd", cwd: "/")

      # PWD may resolve /tmp symlinks on macOS, but cwd: "/" must be honoured
      # on the SECOND call even though the shell is reused.
      expect(r[:output].strip).to eq("/")
    end

    it "injects per-call env vars and unsets them on the next call" do
      r1 = tool.execute(command: "echo $MY_VAR", env: { "MY_VAR" => "alpha" })
      expect(r1[:output]).to include("alpha")

      # Second call: no MY_VAR given → it must be unset inside the shell,
      # NOT bleed through from the previous call.
      r2 = tool.execute(command: "echo \"[${MY_VAR:-unset}]\"")
      expect(r2[:output]).to include("[unset]")
    end

    it "background commands do NOT poison the persistent shell" do
      bg = tool.execute(command: "sleep 30", background: true)
      expect(bg[:session_id]).to be_a(Integer)

      fg = tool.execute(command: "echo alive")
      expect(fg[:exit_code]).to eq(0)
      expect(fg[:output]).to include("alive")

      tool.execute(session_id: bg[:session_id], kill: true)
    end

    it "recovers on the next call after a session blocks mid-command" do
      # Short timeout forces the command to be handed back as a session_id,
      # which "donates" the persistent slot to the caller.
      stuck = tool.execute(command: "sleep 5", timeout: 1)
      expect(stuck[:session_id]).to be_a(Integer)
      # state will be "waiting" (idle with no output) or "timeout" — either
      # way, the persistent slot must be released back to the pool.
      expect(%w[waiting timeout]).to include(stuck[:state])

      # Next foreground call must succeed (a fresh persistent shell is
      # spawned to replace the donated one).
      ok = tool.execute(command: "echo recovered")
      expect(ok[:exit_code]).to eq(0)
      expect(ok[:output]).to include("recovered")

      tool.execute(session_id: stuck[:session_id], kill: true)
    end
  end

  # ---------------------------------------------------------------------------
  # Format helpers (used by UI renderers)
  # ---------------------------------------------------------------------------
  describe "#format_call" do
    it "formats a command invocation" do
      expect(tool.format_call(command: "ls -la")).to eq("terminal(ls -la)")
    end

    it "formats a background invocation" do
      expect(tool.format_call(command: "rails s", background: true)).to eq("terminal(rails s, background)")
    end

    it "formats a continue invocation (input send)" do
      s = tool.format_call(session_id: 3, input: "mypass\n")
      expect(s).to eq("terminal(send \"mypass\")")
    end

    it "formats a check-output (empty input poll) invocation" do
      expect(tool.format_call(session_id: 3, input: "")).to eq("terminal(check output)")
    end

    it "formats a kill invocation" do
      expect(tool.format_call(session_id: 3, kill: true)).to eq("terminal(stop)")
    end

    it "collapses multi-line commands into a single line" do
      multi_line_cmd = "ruby -e '\nputs 1\nputs 2\n'"
      result = tool.format_call(command: multi_line_cmd)
      expect(result).not_to include("\n")
      expect(result).to eq("terminal(ruby -e ' puts 1 puts 2 ')")
    end

    it "truncates very long commands with an ellipsis" do
      long_cmd = "echo " + ("x" * 200)
      result = tool.format_call(command: long_cmd)
      # summary must fit on one line and end with an ellipsis
      expect(result).not_to include("\n")
      expect(result).to end_with("...)")
      # "terminal(" prefix + 80 char budget + ")" ≈ 90 chars, well under a wrapped row
      expect(result.length).to be <= "terminal(".length + Clacky::Tools::Terminal::DISPLAY_COMMAND_MAX_CHARS + 1
    end
  end

  describe "#format_result" do
    it "renders a finished command" do
      expect(tool.format_result(exit_code: 0, bytes_read: 12)).to eq("✓ exit=0")
    end

    it "renders a failed command with ✗ marker" do
      expect(tool.format_result(exit_code: 1, bytes_read: 12)).to eq("✗ exit=1")
    end

    it "renders a waiting session" do
      expect(tool.format_result(session_id: 3, bytes_read: 5)).to eq("… waiting")
    end

    it "renders a kill result" do
      expect(tool.format_result(killed: true, session_id: 3)).to eq("stopped")
    end

    it "renders an error" do
      expect(tool.format_result(error: "boom")).to include("error")
    end

    it "puts output lines first and the status as a trailing footer" do
      formatted = tool.format_result(
        session_id: 7, bytes_read: 30,
        output: "line1\nline2\nline3"
      )
      expect(formatted).to eq("line1\nline2\nline3\n… waiting")
    end

    it "keeps only the last DISPLAY_TAIL_LINES lines and drops blanks, then status" do
      output = ((1..20).map { |i| "row#{i}" }).join("\n")
      formatted = tool.format_result(session_id: 1, bytes_read: 100, output: output)
      lines = formatted.split("\n")
      # last line is the status footer
      expect(lines.last).to eq("… waiting")
      tail_lines = lines[0..-2]
      expect(tail_lines.size).to eq(Clacky::Tools::Terminal::DISPLAY_TAIL_LINES)
      expect(tail_lines.last).to eq("row20")
    end

    it "shows a single status line when output is empty" do
      formatted = tool.format_result(exit_code: 0, bytes_read: 0, output: "")
      expect(formatted).to eq("✓ exit=0")
    end

    # Regression: when `output` is a String whose encoding is UTF-8 but
    # contains an invalid byte sequence (e.g. produced by byteslice cutting
    # through the middle of a multi-byte char), format_result used to raise
    #   ArgumentError: invalid byte sequence in UTF-8
    # from `text.split(/\r?\n/)` / `text.strip` in #display_tail. We want a
    # graceful render.
    it "does not raise when output contains invalid UTF-8 bytes" do
      # Lone continuation bytes — not a valid UTF-8 sequence.
      broken = "hello\n\x80\xFF\x9C world".b.force_encoding("UTF-8")
      expect(broken.valid_encoding?).to eq(false)

      expect {
        tool.format_result(exit_code: 0, bytes_read: broken.bytesize, output: broken)
      }.not_to raise_error
    end

    it "does not raise when output is chopped mid-multibyte (real byteslice scenario)" do
      # Simulate the exact wait_and_package truncation path: build a string
      # whose byte-N boundary falls INSIDE a 3-byte CJK character, then
      # byteslice to N. This is what MAX_LLM_OUTPUT_CHARS truncation does
      # when the cut happens mid-char.
      raw = ("a" * 7999) + "中家".dup
      raw.force_encoding("UTF-8")
      sliced = raw.byteslice(0, 8000)
      sliced.force_encoding("UTF-8")
      expect(sliced.valid_encoding?).to eq(false)

      expect {
        tool.format_result(exit_code: 0, bytes_read: 8000, output: sliced)
      }.not_to raise_error
    end

    it "shows the full_output_file path in the UI footer when output overflowed" do
      formatted = tool.format_result(
        exit_code: 0, bytes_read: 9999, output: "tail line",
        output_truncated: true,
        full_output_file: "/tmp/clacky-terminal-overflow/x.log"
      )
      expect(formatted).to include("tail line")
      expect(formatted).to include("✓ exit=0")
      expect(formatted).to include("[full: /tmp/clacky-terminal-overflow/x.log]")
    end
  end

  # ---------------------------------------------------------------------------
  # Long-output spill: overflow to disk with disclosed path
  # ---------------------------------------------------------------------------
  # When a command produces output larger than MAX_LLM_OUTPUT_CHARS:
  #   1. The full cleaned output MUST be written to a sidecar file in
  #      `/tmp/clacky-terminal-overflow/`.
  #   2. The returned `output:` MUST NOT exceed the budget (it is
  #      truncated to OVERFLOW_PREVIEW_CHARS + a short notice).
  #   3. The returned hash MUST carry `full_output_file:` pointing at
  #      the sidecar so the LLM can grep/tail it in a follow-up call.
  #   4. `output_truncated: true` must be set.
  describe "overflow handling" do
    it "spills to disk and discloses the path when output exceeds MAX_LLM_OUTPUT_CHARS" do
      # Generate output LARGER than MAX_LLM_OUTPUT_CHARS (4000 bytes).
      # Must use many short lines rather than one long line, because the
      # MAX_LINE_CHARS=500 per-line cap runs BEFORE overflow detection —
      # a single 5000-char line would be cut to ~540 chars and never
      # trigger the sidecar write.
      # 500 lines × ~20 chars = ~10 KB, well over the 4 KB budget.
      # We emit via one `printf` invocation so the test doesn't hit the
      # spec-level 200ms idle threshold between iterations.
      n_lines = 500
      cmd = %(awk 'BEGIN{for(i=1;i<=#{n_lines};i++) print "payload-line-number-"i}')
      result = tool.execute(command: cmd, idle_ms: Clacky::Tools::Terminal::DISABLED_IDLE_MS)

      expect(result[:exit_code]).to eq(0)
      expect(result[:output_truncated]).to eq(true)
      expect(result[:full_output_file]).to be_a(String)
      expect(File.exist?(result[:full_output_file])).to eq(true)

      # Sidecar on disk must contain BOTH the head and tail of the output
      # (proves the FULL cleaned output was written, not just the preview).
      disk_content = File.read(result[:full_output_file])
      expect(disk_content).to include("payload-line-number-1\n")
      expect(disk_content).to include("payload-line-number-#{n_lines}")

      # The in-context `output` MUST be under the budget (+ notice slack).
      expect(result[:output].bytesize).to be <= Clacky::Tools::Terminal::MAX_LLM_OUTPUT_CHARS + 400
      # And must disclose the overflow path in a way the LLM can parse.
      expect(result[:output]).to include(result[:full_output_file])
      expect(result[:output]).to include("grep")
    ensure
      File.delete(result[:full_output_file]) if result && result[:full_output_file] && File.exist?(result[:full_output_file])
    end

    it "does NOT create a sidecar when output fits under the budget" do
      result = tool.execute(command: "echo small")
      expect(result[:exit_code]).to eq(0)
      expect(result[:output_truncated]).to be_falsey
      expect(result[:full_output_file]).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Per-line truncation: prevent a single minified blob from eating the
  # whole 4 KB budget. `truncate_long_lines` must chop any line whose byte
  # length exceeds MAX_LINE_CHARS and annotate how many chars were elided.
  # ---------------------------------------------------------------------------
  describe "#truncate_long_lines" do
    it "leaves short lines untouched" do
      text = "line a\nline b\nline c"
      result = tool.send(:truncate_long_lines, text)
      expect(result).to eq(text)
    end

    it "truncates a line that exceeds MAX_LINE_CHARS and annotates the original length" do
      long = "x" * 900
      text = "short\n#{long}\nafter"
      result = tool.send(:truncate_long_lines, text)
      # short and after survive
      expect(result).to start_with("short\n")
      expect(result).to end_with("\nafter")
      # the long line is chopped and annotated
      expect(result).to include("line truncated: 900 chars")
      # total size is dramatically smaller than input
      expect(result.bytesize).to be < text.bytesize
    end

    it "only truncates the long lines, preserving the rest verbatim" do
      long1 = "a" * 600
      long2 = "b" * 700
      text = "pre\n#{long1}\nmid\n#{long2}\npost"
      result = tool.send(:truncate_long_lines, text)
      expect(result).to include("pre\n")
      expect(result).to include("\nmid\n")
      expect(result).to include("\npost")
      expect(result).to include("line truncated: 600 chars")
      expect(result).to include("line truncated: 700 chars")
    end

    it "returns nil/empty inputs unchanged" do
      expect(tool.send(:truncate_long_lines, nil)).to be_nil
      expect(tool.send(:truncate_long_lines, "")).to eq("")
    end
  end

  # ---------------------------------------------------------------------------
  # SLOW_COMMAND auto-tuning: rspec / bundle install / cargo build must not
  # be split into N polling round-trips just because output went quiet for
  # a few seconds between test files / compilation phases.
  # ---------------------------------------------------------------------------
  describe "slow-command auto-tuning" do
    it "recognises a bare slow command" do
      expect(tool.send(:slow_command?, "rspec spec/")).to eq(true)
      expect(tool.send(:slow_command?, "bundle install")).to eq(true)
      expect(tool.send(:slow_command?, "cargo build --release")).to eq(true)
      expect(tool.send(:slow_command?, "npm install")).to eq(true)
    end

    it "recognises a slow command behind common prefixes" do
      expect(tool.send(:slow_command?, "cd myproj && bundle install")).to eq(true)
      expect(tool.send(:slow_command?, "cd myproj; rspec spec/foo_spec.rb")).to eq(true)
      expect(tool.send(:slow_command?, "RAILS_ENV=test bundle exec rspec")).to eq(true)
      expect(tool.send(:slow_command?, "NODE_ENV=production npm run build")).to eq(true)
    end

    it "does not misfire on quick commands" do
      expect(tool.send(:slow_command?, "ls -la")).to eq(false)
      expect(tool.send(:slow_command?, "echo hello")).to eq(false)
      expect(tool.send(:slow_command?, "git status")).to eq(false)
      expect(tool.send(:slow_command?, nil)).to eq(false)
      expect(tool.send(:slow_command?, "")).to eq(false)
    end

    it "auto-extends timeout and disables idle-return when execute() sees a slow command" do
      # Observe the values do_start receives. We don't care about the
      # actual run, only that auto-tuning kicked in — so we stub do_start
      # to return immediately.
      captured = {}
      allow(tool).to receive(:do_start) do |_cmd, cwd:, env:, timeout:, idle_ms:, background:|
        captured[:timeout] = timeout
        captured[:idle_ms] = idle_ms
        captured[:background] = background
        { exit_code: 0, output: "", bytes_read: 0 }
      end

      tool.execute(command: "bundle exec rspec spec/foo_spec.rb")

      expect(captured[:timeout]).to eq(Clacky::Tools::Terminal::SLOW_COMMAND_TIMEOUT)
      expect(captured[:idle_ms]).to eq(Clacky::Tools::Terminal::DISABLED_IDLE_MS)
      expect(captured[:background]).to eq(false)
    end

    it "respects caller-supplied timeout/idle_ms even for slow commands" do
      captured = {}
      allow(tool).to receive(:do_start) do |_cmd, cwd:, env:, timeout:, idle_ms:, background:|
        captured[:timeout] = timeout
        captured[:idle_ms] = idle_ms
        { exit_code: 0, output: "", bytes_read: 0 }
      end

      tool.execute(command: "rspec spec/", timeout: 30, idle_ms: 500)

      expect(captured[:timeout]).to eq(30)
      expect(captured[:idle_ms]).to eq(500)
    end

    it "does NOT auto-tune background launches" do
      captured = {}
      allow(tool).to receive(:do_start) do |_cmd, cwd:, env:, timeout:, idle_ms:, background:|
        captured[:timeout] = timeout
        captured[:idle_ms] = idle_ms
        captured[:background] = background
        { exit_code: 0, output: "", bytes_read: 0 }
      end

      tool.execute(command: "bundle exec rspec", background: true)

      expect(captured[:background]).to eq(true)
      expect(captured[:timeout]).to eq(Clacky::Tools::Terminal::DEFAULT_TIMEOUT)
      # background leaves idle_ms at whatever default the caller wanted —
      # in practice wait_and_package disables idle for backgrounds anyway.
    end
  end

  # ---------------------------------------------------------------------------
  # strip_command_echo: PTY wrapper-echo removal
  # ---------------------------------------------------------------------------
  # When `stty -echo` silently fails (zsh ZLE re-enabling echo on session
  # reuse, cooked PTY mode, line-wrap truncation, etc.), the shell echoes
  # back the full wrapper line we inject around every user command:
  #
  #     { USER_CMD\n}; __clacky_ec=$?; printf "\n__CLACKY_DONE_<tok>_%s__\n" "$__clacky_ec"
  #
  # strip_command_echo must remove that echoed wrapper — in all its observed
  # shapes — without ever touching legitimate user output.
  describe "#strip_command_echo" do
    let(:token) { "6fbad5cb5904a3b5" }

    def strip(text, token: nil)
      tool.send(:strip_command_echo, text, marker_token: token)
    end

    it "strips a single-line wrapper echo even when the leading `{` was dropped by PTY width-wrap" do
      # Reproduces the real-world report: rails runner command, width-wrapped
      # so the terminal ate the first `{ r`, collapsed \n escapes to spaces.
      input = %(ails runner script/reconcile_stripe_payments.rb 2>&1 | tail -80 }; __clacky_ec=$?; printf " __CLACKY_DONE_#{token}_%s__ " "$__clacky_ec"\n) \
              "actual output line 1\n" \
              "actual output line 2\n"

      expect(strip(input, token: token)).to eq("actual output line 1\nactual output line 2\n")
    end

    it "strips a multi-line anchored wrapper echo (legacy behaviour, no token needed)" do
      input = "{ echo hi\n}; __clacky_ec=$?; printf \"\n__CLACKY_DONE_#{token}_%s__\n\" \"$__clacky_ec\"\nhi\n"
      expect(strip(input, token: token)).to eq("hi\n")
    end

    it "strips a wrapper echo that appears mid-stream, not anchored to the start" do
      input = "previous output\n" \
              "{ echo hi\n}; __clacky_ec=$?; printf \"\n__CLACKY_DONE_#{token}_%s__\n\" \"$__clacky_ec\"\nhi\n"
      expect(strip(input, token: token)).to eq("previous output\nhi\n")
    end

    it "does not touch user output that mentions __clacky_ec but lacks the session token" do
      input = "my script prints __clacky_ec=$? for debugging\nnext line\n"
      expect(strip(input, token: token)).to eq(input)
    end

    it "strips a wrapper-shaped echo even when the token is different or missing" do
      # PTY width-wrap can truncate the token or even the entire
      # `__CLACKY_DONE_..._%s__` format out of the printf format argument.
      # The `}; __clacky_ec=$?; printf ... "$__clacky_ec"` fingerprint is
      # unique enough that we strip it on sight regardless of token.
      input = "real output\n{ echo hi\n}; __clacky_ec=$?; printf \"\n__CLACKY_DONE_OTHER_%s__\n\" \"$__clacky_ec\"\nhi\n"
      expect(strip(input, token: token)).to eq("real output\n{ echo hi\nhi\n")
    end

    it "strips a wrapper echo where the __CLACKY_DONE marker format was truncated away entirely" do
      # Real-world: rails / cat commands so long that PTY width-wrap
      # shredded the printf format, leaving only `printf \" \" \"$__clacky_ec\"`
      # with the marker gone. Token-aware patterns don't match this, so
      # the token-independent fingerprint pass must catch it.
      input = %(d -c 2000 }; __clacky_ec=$?; printf " " "$__clacky_ec" brand_skills.json pptx ---\n) \
              "---\n" \
              "{\"pptx\":{\"version\":\"1.0.1\"}}\n"

      expect(strip(input, token: token)).to eq("---\n{\"pptx\":{\"version\":\"1.0.1\"}}\n")
    end

    it "strips a wrapper echo where the entire printf was truncated, leaving only the `}; __clacky_ec=$?` pivot" do
      input = "tail -80 }; __clacky_ec=$?\nactual output\n"
      expect(strip(input, token: token)).to eq("actual output\n")
    end

    it "falls back to the legacy anchored strip when no token is supplied" do
      input = "{ echo hi\n}; __clacky_ec=$?; printf \"\n__CLACKY_DONE_xxx_%s__\n\" \"$__clacky_ec\"\nhi\n"
      expect(strip(input, token: nil)).to eq("hi\n")
    end

    it "handles nil and empty input" do
      expect(strip(nil, token: token)).to be_nil
      expect(strip("", token: token)).to eq("")
    end
  end

  # ---------------------------------------------------------------------------
  # .run_sync — internal Ruby synchronous-capture API
  # ---------------------------------------------------------------------------
  describe ".run_sync" do
    it "returns [output, exit_code] for a fast command" do
      output, exit_code = described_class.run_sync("echo hello-sync", timeout: 10)
      expect(exit_code).to eq(0)
      expect(output).to include("hello-sync")
    end

    it "captures a non-zero exit code" do
      _output, exit_code = described_class.run_sync("sh -c 'exit 7'", timeout: 10)
      expect(exit_code).to eq(7)
    end

    it "waits through an idle window longer than DEFAULT_IDLE_MS and still returns exit_code" do
      # This is the exact shape that broke 0.9.36 upgrade: a command that
      # stays silent past the 3s idle threshold, then finishes.
      # sleep 5 produces NO output for 5s — #execute alone would return
      # {session_id: ..., exit_code: nil}; #run_sync must poll and wait.
      start = Time.now
      _output, exit_code = described_class.run_sync("sleep 5 && echo done", timeout: 30)
      elapsed = Time.now - start

      expect(exit_code).to eq(0)
      expect(elapsed).to be >= 4.5   # actually waited
    end

    it "forwards cwd" do
      Dir.mktmpdir do |dir|
        output, exit_code = described_class.run_sync("pwd", timeout: 10, cwd: dir)
        expect(exit_code).to eq(0)
        # On macOS /tmp is symlinked to /private/tmp; compare via realpath.
        expect(File.realpath(output.strip)).to eq(File.realpath(dir))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # OutputCleaner (kept here, independent utility)
  # ---------------------------------------------------------------------------
  describe Clacky::Tools::Terminal::OutputCleaner do
    describe ".clean" do
      it "strips ANSI CSI sequences" do
        expect(described_class.clean("\e[31mred\e[0m")).to eq("red")
      end

      it "strips OSC sequences" do
        expect(described_class.clean("\e]0;window-title\atext")).to eq("text")
      end

      it "collapses CR-overwrites (progress bar)" do
        expect(described_class.clean("50%\r100%\n")).to eq("100%\n")
      end

      it "applies backspace erase" do
        expect(described_class.clean("abX\bc")).to eq("abc")
      end

      it "normalizes CRLF to LF" do
        expect(described_class.clean("line1\r\nline2\r\n")).to eq("line1\nline2\n")
      end

      it "handles nil and empty input" do
        expect(described_class.clean(nil)).to eq("")
        expect(described_class.clean("")).to eq("")
      end

      it "is idempotent on already-clean text" do
        expect(described_class.clean("hello world\n")).to eq("hello world\n")
      end

      it "scrubs invalid UTF-8 byte sequences into a valid UTF-8 string" do
        # ASCII-8BIT bytes that are NOT valid UTF-8 (lone continuation bytes).
        raw = "before \x80\xFF\x9C after".b
        cleaned = described_class.clean(raw)

        expect(cleaned.encoding).to eq(Encoding::UTF_8)
        expect(cleaned.valid_encoding?).to eq(true)
        expect(cleaned).to include("before")
        expect(cleaned).to include("after")
      end
    end
  end
end
