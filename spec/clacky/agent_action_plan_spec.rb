# frozen_string_literal: true

RSpec.describe Clacky::Agent, "#action_plan_without_tools?" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) do
    c = Clacky::AgentConfig.new(permission_mode: :auto_approve)
    c.add_model(
      model: "test-model",
      api_key: "test-api-key",
      base_url: "https://api.example.com"
    )
    c
  end
  let(:agent) do
    described_class.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding",
                        session_id: Clacky::SessionManager.generate_id, source: :manual)
  end

  # Access private method
  subject { agent.send(:action_plan_without_tools?, content) }

  # ── Mode 1: Intent detection (positive) ─────────────────────────────

  context "action plan + question ending" do
    let(:content) { "我建议做这个3步小测试来确认问题...要我现在直接跑吗？" }
    it { is_expected.to be true }
  end

  context "Chinese intent short distance" do
    let(:content) { "我来排查这个问题" }
    it { is_expected.to be true }
  end

  context "Chinese modal + verb" do
    let(:content) { "我先检查日志文件" }
    it { is_expected.to be true }
  end

  context "Chinese explicit future tense" do
    let(:content) { "我将修复这个bug" }
    it { is_expected.to be true }
  end

  context "Chinese 我会 + verb" do
    let(:content) { "我会创建一个新文件" }
    it { is_expected.to be true }
  end

  context "Chinese 我要 + verb" do
    let(:content) { "我要测试一下" }
    it { is_expected.to be true }
  end

  context "EN intent with modal" do
    let(:content) { "I'll investigate this issue" }
    it { is_expected.to be true }
  end

  context "EN let me + verb" do
    let(:content) { "Let me check the logs" }
    it { is_expected.to be true }
  end

  context "question ending seeking permission" do
    let(:content) { "这个需要修改吗？" }
    it { is_expected.to be true }
  end

  # ── Mode 2: False completion detection (positive) ───────────────────

  context "CN false completion: 已 + verb" do
    let(:content) { "已移除测试文件" }
    it { is_expected.to be true }
  end

  context "CN false completion: 已完成 + verb" do
    let(:content) { "已完成修改" }
    it { is_expected.to be true }
  end

  context "CN false completion: verb + ✅" do
    let(:content) { "删除了✅" }
    it { is_expected.to be true }
  end

  context "CN false completion: 已部署成功" do
    let(:content) { "已部署成功" }
    it { is_expected.to be true }
  end

  context "EN false completion: I've + verb + success" do
    let(:content) { "I've removed the file successfully" }
    it { is_expected.to be true }
  end

  context "EN false completion: verb + successfully" do
    let(:content) { "Deleted successfully" }
    it { is_expected.to be true }
  end

  # ── Negative cases: real answers / genuine completions ──────────────

  context "real answer containing 我 (explanation)" do
    let(:content) { "让我解释一下这个配置的工作原理：它通过环境变量来控制" }
    it { is_expected.to be false }
  end

  context "long genuine completion with explanation" do
    let(:content) { "修改完成！我已将配置文件中的端口号从3000改为8080，同时更新了相关的环境变量设置" }
    it { is_expected.to be false }
  end

  context "answer about checking (second person suggestion)" do
    let(:content) { "你可以检查配置文件是否正确" }
    it { is_expected.to be false }
  end

  context "real explanation" do
    let(:content) { "这个问题是因为缓存过期导致的，刷新页面即可解决" }
    it { is_expected.to be false }
  end

  context "short factual answer" do
    let(:content) { "Ruby 3.2 支持 WASI" }
    it { is_expected.to be false }
  end

  context "no changes needed" do
    let(:content) { "No changes needed — the config is already correct" }
    it { is_expected.to be false }
  end

  context "task complete with long explanation" do
    let(:content) { "已完成！这个功能的工作原理是通过中间件拦截请求，然后根据规则进行转发。具体实现包括三个部分..." }
    it { is_expected.to be false }
  end

  context "EN factual answer" do
    let(:content) { "The error is caused by a missing dependency" }
    it { is_expected.to be false }
  end

  context "empty content" do
    let(:content) { "" }
    it { is_expected.to be false }
  end

  context "very long response (>800)" do
    let(:content) { "x" * 801 }
    it { is_expected.to be false }
  end
end
