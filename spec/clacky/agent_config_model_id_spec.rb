# frozen_string_literal: true

# Regression tests for runtime model id injection (Plan B).
#
# Design invariants exercised here:
#   1. Every loaded model gets a stable runtime id.
#   2. Ids are NOT written to config.yml (backward compat for old users).
#   3. switch_model_by_id preserves identity across list reorders/additions.
#   4. deep_copy shares the @models reference so per-session configs
#      observe global additions immediately (Plan B shared models).
RSpec.describe "AgentConfig model id (Plan B)" do
  def with_temp_config(data = nil)
    temp_dir = Dir.mktmpdir
    config_file = File.join(temp_dir, "config.yml")
    File.write(config_file, YAML.dump(data)) if data
    yield config_file
  ensure
    FileUtils.rm_rf(temp_dir) if temp_dir
  end

  describe "id injection at load time" do
    it "assigns a runtime id to every model" do
      with_temp_config([
        { "model" => "gpt-4o", "api_key" => "sk-a", "base_url" => "https://a.example", "type" => "default" },
        { "model" => "gpt-4o-mini", "api_key" => "sk-a", "base_url" => "https://a.example" }
      ]) do |path|
        config = Clacky::AgentConfig.load(path)
        expect(config.models.size).to eq(2)
        expect(config.models.all? { |m| m["id"] && !m["id"].empty? }).to be true
        expect(config.models[0]["id"]).not_to eq(config.models[1]["id"])
      end
    end

    it "anchors current_model_id to the loaded default model" do
      with_temp_config([
        { "model" => "a", "api_key" => "k1", "base_url" => "u1" },
        { "model" => "b", "api_key" => "k2", "base_url" => "u2", "type" => "default" }
      ]) do |path|
        config = Clacky::AgentConfig.load(path)
        default_id = config.models.find { |m| m["type"] == "default" }["id"]
        expect(config.current_model_id).to eq(default_id)
        expect(config.current_model["model"]).to eq("b")
      end
    end
  end

  describe "save (to_yaml) strips runtime-only fields" do
    it "does NOT write id or auto_injected to config.yml" do
      with_temp_config([
        { "model" => "gpt-4o", "api_key" => "sk-a", "base_url" => "https://a.example", "type" => "default" }
      ]) do |path|
        config = Clacky::AgentConfig.load(path)
        # Force-add an auto_injected entry to ensure it's also stripped
        config.models << { "model" => "lite-x", "api_key" => "sk-a", "base_url" => "u", "auto_injected" => true, "id" => "x" }

        config.save(path)
        raw = File.read(path)
        expect(raw).not_to include("id:")
        expect(raw).not_to include("auto_injected")
        # Sanity: the persisted model is still there
        expect(raw).to include("gpt-4o")
      end
    end
  end

  describe "id stability across api_key edit" do
    it "preserves id when only api_key changes (the key use case)" do
      with_temp_config([
        { "model" => "gpt-4o", "api_key" => "sk-old", "base_url" => "https://a.example", "type" => "default" }
      ]) do |path|
        config = Clacky::AgentConfig.load(path)
        original_id = config.models[0]["id"]

        # Simulate user editing api_key in Settings: the id stays the same
        # in memory (we mutate in place), and is not written to yml anyway.
        config.models[0]["api_key"] = "sk-new"
        config.save(path)

        # Reload — id will be regenerated (can't survive process restart),
        # but current_model_id resolution must still find the model.
        config2 = Clacky::AgentConfig.load(path)
        expect(config2.current_model["model"]).to eq("gpt-4o")
        expect(config2.current_model["api_key"]).to eq("sk-new")
      end
    end
  end

  describe "switch_model_by_id" do
    it "switches current model by stable id (per-session only, does not touch global default marker)" do
      with_temp_config([
        { "model" => "a", "api_key" => "k", "base_url" => "u", "type" => "default" },
        { "model" => "b", "api_key" => "k", "base_url" => "u" }
      ]) do |path|
        config = Clacky::AgentConfig.load(path)
        b_id = config.models.find { |m| m["model"] == "b" }["id"]

        expect(config.switch_model_by_id(b_id)).to be true
        expect(config.current_model["model"]).to eq("b")
        expect(config.current_model_id).to eq(b_id)
        # CRITICAL: switching the current session must NOT move the global
        # `type: default` marker — that's a separate "set global default"
        # concern handled only in api_save_config.
        expect(config.models.find { |m| m["type"] == "default" }["model"]).to eq("a")
      end
    end

    it "returns false for unknown id" do
      with_temp_config([
        { "model" => "a", "api_key" => "k", "base_url" => "u", "type" => "default" }
      ]) do |path|
        config = Clacky::AgentConfig.load(path)
        expect(config.switch_model_by_id("nonexistent-id")).to be false
      end
    end

    it "survives list reordering (id anchored identity)" do
      with_temp_config([
        { "model" => "a", "api_key" => "k", "base_url" => "u", "type" => "default" },
        { "model" => "b", "api_key" => "k", "base_url" => "u" }
      ]) do |path|
        config = Clacky::AgentConfig.load(path)
        b_id = config.models.find { |m| m["model"] == "b" }["id"]
        config.switch_model_by_id(b_id)

        # User reorders the list in Settings — "b" is now at index 0
        config.models.reverse!

        # current_model still resolves to "b" via id (not index)
        expect(config.current_model["model"]).to eq("b")
      end
    end
  end

  describe "deep_copy shares @models reference (Plan B)" do
    it "per-session config sees globally-added models without sync" do
      with_temp_config([
        { "model" => "a", "api_key" => "k", "base_url" => "u", "type" => "default" }
      ]) do |path|
        global = Clacky::AgentConfig.load(path)
        session_copy = global.deep_copy

        # Same array reference — not just equal
        expect(session_copy.models.equal?(global.models)).to be true

        # Global adds a new model (as api_save_config would via replace())
        global.models << { "id" => "new-id", "model" => "newly-added", "api_key" => "k2", "base_url" => "u2" }

        # Session sees it immediately without any sync step
        expect(session_copy.models.any? { |m| m["id"] == "new-id" }).to be true
      end
    end

    it "per-session switch does NOT affect another session's current model" do
      with_temp_config([
        { "model" => "a", "api_key" => "k", "base_url" => "u", "type" => "default" },
        { "model" => "b", "api_key" => "k", "base_url" => "u" }
      ]) do |path|
        global = Clacky::AgentConfig.load(path)
        s1 = global.deep_copy
        s2 = global.deep_copy

        b_id = global.models.find { |m| m["model"] == "b" }["id"]
        # s1 switches to b by id. This only updates s1's @current_model_id;
        # the shared @models array's `type: default` marker is NOT touched
        # (that's a Settings-level global concern, separate from per-session
        # current-model).
        s1.switch_model_by_id(b_id)

        # s1's @current_model_id is b's id
        expect(s1.current_model_id).to eq(b_id)
        # s2's @current_model_id is unchanged (still a's id)
        a_id = global.models.find { |m| m["model"] == "a" }["id"]
        expect(s2.current_model_id).to eq(a_id)
        # And s2#current_model still resolves to a.
        expect(s2.current_model["model"]).to eq("a")
        # Global default marker is ALSO unchanged by a per-session switch.
        expect(global.models.find { |m| m["type"] == "default" }["model"]).to eq("a")
      end
    end
  end
end
