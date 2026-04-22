# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Clacky::SessionManager, "#files_for" do
  let(:temp_dir) { Dir.mktmpdir("clacky_sm_spec") }
  subject(:manager) { described_class.new(sessions_dir: temp_dir) }

  after { FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir) }

  def persist_session(session_id: "abcdef1234567890", created_at: "2025-01-02T03:04:05+00:00")
    data = { session_id: session_id, created_at: created_at, updated_at: created_at, messages: [] }
    manager.save(data)
    data
  end

  it "returns nil when the session does not exist" do
    expect(manager.files_for("nope")).to be_nil
  end

  it "returns the json path and no chunks when nothing is archived" do
    data = persist_session
    result = manager.files_for(data[:session_id])

    expect(result).not_to be_nil
    expect(result[:json_path]).to end_with(".json")
    expect(File.exist?(result[:json_path])).to be true
    expect(result[:chunks]).to eq([])
    expect(result[:session][:session_id]).to eq(data[:session_id])
  end

  it "includes all chunk-*.md files, sorted" do
    data = persist_session
    base = File.basename(manager.last_saved_path, ".json")

    # Create chunks out-of-order to confirm sort.
    [3, 1, 2].each do |n|
      File.write(File.join(temp_dir, "#{base}-chunk-#{n}.md"), "chunk #{n}")
    end

    result = manager.files_for(data[:session_id])
    expect(result[:chunks].size).to eq(3)
    expect(result[:chunks].map { |p| File.basename(p) }).to eq(
      ["#{base}-chunk-1.md", "#{base}-chunk-2.md", "#{base}-chunk-3.md"]
    )
  end

  it "matches by session id prefix (consistent with load/delete)" do
    data = persist_session(session_id: "deadbeefcafebabe")
    result = manager.files_for("deadbeef")
    expect(result).not_to be_nil
    expect(result[:session][:session_id]).to eq(data[:session_id])
  end
end
