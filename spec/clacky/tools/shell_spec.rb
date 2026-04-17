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
    it "returns command unchanged when shell configs have not changed" do
      allow(tool).to receive(:shell_configs_changed?).and_return(false)
      expect(tool.wrap_with_shell("ls")).to eq("ls")
    end

    it "wraps with -l and sources rc file when shell configs have changed" do
      allow(tool).to receive(:shell_configs_changed?).and_return(true)
      allow(tool).to receive(:shell_config_hashes).and_return({ "/home/user/.zshrc" => "abc123" })
      wrapped = tool.wrap_with_shell("ls")
      expect(wrapped).to include("-l")
      expect(wrapped).to include("source")
      expect(wrapped).to include("ls")
    end
  end

  # ---------------------------------------------------------------------------
  # shell_config_hashes (private)
  # ---------------------------------------------------------------------------
  describe "#shell_config_hashes" do
    it "returns zsh config files for zsh" do
      allow(ENV).to receive(:[]).with("HOME").and_return("/home/user")
      allow(File).to receive(:exist?).and_return(false)
      hashes = tool.send(:shell_config_hashes, "/bin/zsh")
      expect(hashes).to be_a(Hash)
    end

    it "returns bash config files for bash" do
      allow(ENV).to receive(:[]).with("HOME").and_return("/home/user")
      allow(File).to receive(:exist?).and_return(false)
      hashes = tool.send(:shell_config_hashes, "/bin/bash")
      expect(hashes).to be_a(Hash)
    end

    it "returns fish config file for fish" do
      allow(ENV).to receive(:[]).with("HOME").and_return("/home/user")
      allow(File).to receive(:exist?).and_return(false)
      hashes = tool.send(:shell_config_hashes, "/usr/local/bin/fish")
      expect(hashes).to be_a(Hash)
    end

    it "returns .profile for unknown shells" do
      allow(ENV).to receive(:[]).with("HOME").and_return("/home/user")
      allow(File).to receive(:exist?).and_return(false)
      hashes = tool.send(:shell_config_hashes, "/bin/sh")
      expect(hashes).to be_a(Hash)
    end
  end

  # ---------------------------------------------------------------------------
  # shell_configs_changed? (private)
  # ---------------------------------------------------------------------------
  describe "#shell_configs_changed?" do
    it "returns false on first call (establishes baseline)" do
      allow(tool).to receive(:shell_config_hashes).and_return({ "/home/user/.zshrc" => "abc123" })
      expect(tool.send(:shell_configs_changed?, "/bin/zsh")).to be false
    end

    it "returns true when a config file changes" do
      allow(tool).to receive(:shell_config_hashes).and_return({ "/home/user/.zshrc" => "abc123" })
      tool.send(:shell_configs_changed?, "/bin/zsh") # establish baseline
      allow(tool).to receive(:shell_config_hashes).and_return({ "/home/user/.zshrc" => "newhash" })
      expect(tool.send(:shell_configs_changed?, "/bin/zsh")).to be true
    end

    it "returns false when nothing changes" do
      allow(tool).to receive(:shell_config_hashes).and_return({ "/home/user/.zshrc" => "abc123" })
      tool.send(:shell_configs_changed?, "/bin/zsh") # establish baseline
      expect(tool.send(:shell_configs_changed?, "/bin/zsh")).to be false
    end

    it "updates snapshot after detecting a change" do
      allow(tool).to receive(:shell_config_hashes).and_return({ "/home/user/.zshrc" => "abc123" })
      tool.send(:shell_configs_changed?, "/bin/zsh")
      allow(tool).to receive(:shell_config_hashes).and_return({ "/home/user/.zshrc" => "newHash" })
      tool.send(:shell_configs_changed?, "/bin/zsh") # triggers update
      allow(tool).to receive(:shell_config_hashes).and_return({ "/home/user/.zshrc" => "newHash" })
      expect(tool.send(:shell_configs_changed?, "/bin/zsh")).to be false
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
  # Encoding regression — e2e
  # Reproduces: Tool safe_shell denied: "\xE2" from ASCII-8BIT to UTF-8
  # ---------------------------------------------------------------------------
  describe "#execute — multibyte UTF-8 encoding regression" do
    it "does not raise encoding error when command outputs multibyte UTF-8 characters" do
      result = tool.execute(command: "echo '你好世界 → ✓'")
      expect { JSON.generate(tool.format_result_for_llm(result)) }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # format_result_for_llm
  # ---------------------------------------------------------------------------
  describe "#format_result_for_llm" do
    it "applies truncation to TIMEOUT results" do
      result = { state: "TIMEOUT", command: "sleep 100", stdout: "", stderr: "", exit_code: -1, success: false, timeout_type: :execution }
      compact = tool.format_result_for_llm(result)
      expect(compact[:state]).to eq("TIMEOUT")
      expect(compact[:timeout_type]).to eq(:execution)
      expect(compact[:stdout]).to eq("")
    end

    it "applies truncation to WAITING_INPUT results and includes message" do
      result = { state: "WAITING_INPUT", command: "cat", stdout: "hello\n", stderr: "", exit_code: -2, success: false, interaction_type: "question", interaction: { type: "question", line: "hello" } }
      compact = tool.format_result_for_llm(result)
      expect(compact[:state]).to eq("WAITING_INPUT")
      expect(compact[:interaction_type]).to eq("question")
      expect(compact[:message]).to include("WAITING_INPUT")
      expect(compact[:stdout]).to eq("hello\n")
    end

    it "truncates large WAITING_INPUT output to MAX_LLM_OUTPUT_CHARS" do
      long_out = "x\n" * 3000
      result = { state: "WAITING_INPUT", command: "cat", stdout: long_out, stderr: "", exit_code: -2, success: false, interaction_type: "question", interaction: { type: "question", line: "x" } }
      compact = tool.format_result_for_llm(result)
      expect(compact[:stdout].length).to be < long_out.length
      expect(compact[:message].length).to be < long_out.length
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
