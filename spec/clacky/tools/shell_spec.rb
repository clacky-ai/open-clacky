# frozen_string_literal: true

RSpec.describe Clacky::Tools::Shell do
  let(:tool) { described_class.new }


  # ---------------------------------------------------------------------------
  # Basic execution
  # ---------------------------------------------------------------------------
  describe "#execute — basic" do
    it "runs a simple command and returns stdout" do
      result = tool.execute(command: "echo hello")
      expect(result[:exit_code]).to eq(0)
      expect(result[:success]).to be true
      expect(result[:stdout]).to include("hello")
    end

    it "captures multi-line output" do
      result = tool.execute(command: "printf 'a\\nb\\nc\\n'")
      expect(result[:stdout]).to include("a")
      expect(result[:stdout]).to include("b")
      expect(result[:stdout]).to include("c")
    end

    it "reports non-zero exit code for failing commands" do
      result = tool.execute(command: "exit 42", soft_timeout: 5, hard_timeout: 10)
      expect(result[:exit_code]).to eq(42)
      expect(result[:success]).to be false
    end

    it "captures stderr separately from stdout" do
      result = tool.execute(command: "echo out; echo err >&2")
      expect(result[:stdout]).to include("out")
      expect(result[:stderr]).to include("err")
    end

    it "includes elapsed time in result" do
      result = tool.execute(command: "echo hi")
      expect(result[:elapsed]).to be_a(Numeric)
      expect(result[:elapsed]).to be >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # working_dir
  # ---------------------------------------------------------------------------
  describe "#execute — working_dir" do
    it "runs the command inside the specified directory" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "sentinel_file.txt"))
        result = tool.execute(command: "ls", working_dir: dir)
        expect(result[:exit_code]).to eq(0)
        expect(result[:stdout]).to include("sentinel_file.txt")
      end
    end

    it "ignores working_dir if it does not exist" do
      result = tool.execute(command: "echo ok", working_dir: "/nonexistent_xyz_dir")
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("ok")
    end
  end

  # ---------------------------------------------------------------------------
  # Output truncation
  # ---------------------------------------------------------------------------
  describe "#execute — output truncation" do
    it "does not truncate short output" do
      result = tool.execute(command: "seq 1 5", max_output_lines: 100)
      expect(result[:output_truncated]).to be false
      expect(result[:stdout]).not_to include("truncated")
    end

    it "truncates output exceeding max_output_lines" do
      result = tool.execute(command: "seq 1 500", max_output_lines: 50)
      expect(result[:output_truncated]).to be true
      expect(result[:stdout]).to include("Output truncated")
      expect(result[:stdout].lines.count).to be <= 55
    end

    it "uses default max_output_lines of 1000" do
      result = tool.execute(command: "seq 1 2000")
      expect(result[:output_truncated]).to be true
      expect(result[:stdout].lines.count).to be <= 1005
    end
  end

  # ---------------------------------------------------------------------------
  # Hard timeout
  # ---------------------------------------------------------------------------
  describe "#execute — hard timeout" do
    it "kills the process and returns TIMEOUT state when hard_timeout exceeded" do
      result = tool.execute(
        command: "sleep 60",
        soft_timeout: 0.3,
        hard_timeout: 0.6
      )
      expect(result[:state]).to eq("TIMEOUT")
      expect(result[:exit_code]).to eq(-1)
      expect(result[:success]).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Interaction / WAITING_INPUT detection
  # ---------------------------------------------------------------------------
  describe "#execute — interaction detection" do
    it "detects [Y/n] confirmation prompt and returns WAITING_INPUT" do
      result = tool.execute(
        command: "printf '[Y/n] '; sleep 30",
        soft_timeout: 0.5,
        hard_timeout: 2
      )
      expect(result[:state]).to eq("WAITING_INPUT")
      expect(result[:interaction_type]).to eq("confirmation")
    end
  end

  # ---------------------------------------------------------------------------
  # wrap_with_shell
  # ---------------------------------------------------------------------------
  describe "#wrap_with_shell" do
    it "returns the command unchanged (no shell wrapping)" do
      wrapped = tool.wrap_with_shell("ls")
      expect(wrapped).to eq("ls")
    end

    it "passes through commands with arguments" do
      wrapped = tool.wrap_with_shell("echo 'hello world'")
      expect(wrapped).to eq("echo 'hello world'")
    end
  end

  # ---------------------------------------------------------------------------
  # rc_source_snippet (private)
  # ---------------------------------------------------------------------------
  describe "#rc_source_snippet" do
    it "returns zshrc snippet for zsh" do
      allow(ENV).to receive(:[]).with("HOME").and_return("/home/user")
      snippet = tool.send(:rc_source_snippet, "/bin/zsh")
      expect(snippet).to include(".zshrc")
      expect(snippet).to include("source")
      expect(snippet).to include("2>/dev/null")
    end

    it "returns bashrc snippet for bash" do
      allow(ENV).to receive(:[]).with("HOME").and_return("/home/user")
      snippet = tool.send(:rc_source_snippet, "/bin/bash")
      expect(snippet).to include(".bashrc")
    end

    it "returns fish config snippet for fish" do
      allow(ENV).to receive(:[]).with("HOME").and_return("/home/user")
      snippet = tool.send(:rc_source_snippet, "/usr/local/bin/fish")
      expect(snippet).to include("config.fish")
    end

    it "returns nil for unknown shells" do
      allow(ENV).to receive(:[]).with("HOME").and_return("/home/user")
      snippet = tool.send(:rc_source_snippet, "/bin/sh")
      expect(snippet).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # detect_interaction
  # ---------------------------------------------------------------------------
  describe "#detect_interaction" do
    it "detects Y/n confirmation patterns" do
      result = tool.detect_interaction("Do you want to continue? [Y/n]")
      expect(result).not_to be_nil
      expect(result[:type]).to eq("confirmation")
    end

    it "detects password prompts" do
      result = tool.detect_interaction("Password: ")
      expect(result).not_to be_nil
      expect(result[:type]).to eq("password")
    end

    it "detects pager (less/more) patterns" do
      result = tool.detect_interaction("lines 1-40 (END)")
      expect(result).not_to be_nil
      expect(result[:type]).to eq("pager")
    end

    it "returns nil for normal output" do
      result = tool.detect_interaction("total 42\n-rw-r--r-- 1 user group 1234 Jan 1 foo.rb\n")
      expect(result).to be_nil
    end

    it "returns nil for empty string" do
      expect(tool.detect_interaction("")).to be_nil
    end

    it "returns UTF-8 encoded line even when input is ASCII-8BIT" do
      # Simulate raw terminal byte stream with ASCII-8BIT encoding
      raw = "Do you want to continue? [Y/n]".b
      result = tool.detect_interaction(raw)
      expect(result).not_to be_nil
      expect(result[:line].encoding).to eq(Encoding::UTF_8)
    end
  end

  # ---------------------------------------------------------------------------
  # detect_sudo_waiting
  # ---------------------------------------------------------------------------
  describe "#detect_sudo_waiting" do
    it "returns password interaction when sudo command is still running" do
      wait_thr = double("wait_thr", alive?: true)
      result = tool.detect_sudo_waiting("sudo apt-get install vim", wait_thr)
      expect(result).not_to be_nil
      expect(result[:type]).to eq("password")
    end

    it "returns nil when process has exited" do
      wait_thr = double("wait_thr", alive?: false)
      result = tool.detect_sudo_waiting("sudo apt-get install vim", wait_thr)
      expect(result).to be_nil
    end

    it "returns nil for non-sudo commands" do
      wait_thr = double("wait_thr", alive?: true)
      result = tool.detect_sudo_waiting("apt-get install vim", wait_thr)
      expect(result).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # determine_timeouts
  # ---------------------------------------------------------------------------
  describe "#determine_timeouts" do
    it "returns short timeouts for normal commands" do
      soft, hard = tool.determine_timeouts("ls", nil, nil)
      expect(soft).to eq(7)
      expect(hard).to eq(60)
    end

    it "returns longer timeouts for slow commands" do
      soft, hard = tool.determine_timeouts("bundle install", nil, nil)
      expect(soft).to eq(30)
      expect(hard).to eq(180)
    end

    it "respects explicitly provided soft_timeout" do
      soft, _hard = tool.determine_timeouts("ls", 99, nil)
      expect(soft).to eq(99)
    end

    it "respects explicitly provided hard_timeout" do
      _soft, hard = tool.determine_timeouts("ls", nil, 999)
      expect(hard).to eq(999)
    end
  end

  # ---------------------------------------------------------------------------
  # format_call / format_result
  # ---------------------------------------------------------------------------
  describe "#format_call" do
    it "includes first words of command" do
      formatted = tool.format_call({ command: "git status --short" })
      expect(formatted).to include("git")
      expect(formatted).to include("status")
    end

    it "appends ellipsis for long commands" do
      formatted = tool.format_call({ command: "word1 word2 word3 word4 word5" })
      expect(formatted).to include("...")
    end
  end

  describe "#format_result" do
    it "shows [OK] for successful commands" do
      result = { exit_code: 0, stdout: "line1\nline2\n", stderr: "" }
      expect(tool.format_result(result)).to include("[OK]")
    end

    it "shows exit code for failures" do
      result = { exit_code: 1, stdout: "", stderr: "error message" }
      expect(tool.format_result(result)).to include("[Exit 1]")
    end
  end

  # ---------------------------------------------------------------------------
  # format_waiting_input_result
  # ---------------------------------------------------------------------------
  describe "#format_waiting_input_result" do
    it "includes sudo hint when interaction type is password" do
      interaction = { type: "password", line: "[sudo] password for user:" }
      result = tool.send(:format_waiting_input_result, "sudo apt-get install vim", "", "", interaction, 1000)
      expect(result[:state]).to eq("WAITING_INPUT")
      expect(result[:interaction_type]).to eq("password")
      expect(result[:message]).to include("sudo -S")
    end

    it "does not include sudo hint for non-password interactions" do
      interaction = { type: "confirmation", line: "Do you want to continue? [Y/n]" }
      result = tool.send(:format_waiting_input_result, "apt-get install vim", "", "", interaction, 1000)
      expect(result[:state]).to eq("WAITING_INPUT")
      expect(result[:message]).not_to include("sudo -S")
    end
  end

  # ---------------------------------------------------------------------------
  # format_result_for_llm
  # ---------------------------------------------------------------------------
  describe "#format_result_for_llm" do
    it "passes through TIMEOUT results unchanged" do
      result = { state: "TIMEOUT", command: "sleep 100", stdout: "", stderr: "", exit_code: -1, success: false }
      expect(tool.format_result_for_llm(result)).to eq(result)
    end

    it "passes through WAITING_INPUT results unchanged" do
      result = { state: "WAITING_INPUT", command: "cat", stdout: "", stderr: "", exit_code: -2, success: false }
      expect(tool.format_result_for_llm(result)).to eq(result)
    end

    it "truncates long stdout for LLM" do
      long_out = "x\n" * 3000
      result = { command: "cmd", exit_code: 0, success: true, stdout: long_out, stderr: "" }
      compact = tool.format_result_for_llm(result)
      expect(compact[:stdout].length).to be < long_out.length
      expect(compact[:stdout]).to include("truncated")
    end

    it "preserves short output without truncation" do
      result = { command: "echo hi", exit_code: 0, success: true, stdout: "hi\n", stderr: "" }
      compact = tool.format_result_for_llm(result)
      expect(compact[:stdout]).to eq("hi\n")
    end

    it "includes elapsed time when present" do
      result = { command: "ls", exit_code: 0, success: true, stdout: "a\n", stderr: "", elapsed: 0.5 }
      compact = tool.format_result_for_llm(result)
      expect(compact[:elapsed]).to eq(0.5)
    end
  end
end
