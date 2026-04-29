# frozen_string_literal: true

RSpec.describe Clacky::AgentConfig do
  # Helper to create a temporary config file
  def with_temp_config(data = nil)
    temp_dir = Dir.mktmpdir
    config_file = File.join(temp_dir, "config.yml")

    if data
      File.write(config_file, YAML.dump(data))
    end

    yield config_file
  ensure
    FileUtils.rm_rf(temp_dir) if temp_dir
  end

  describe ".load" do
    context "when config file doesn't exist" do
      it "returns a new config with empty models" do
        with_env("ANTHROPIC_API_KEY" => nil, "ANTHROPIC_AUTH_TOKEN" => nil) do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file) # Ensure it doesn't exist

            config = described_class.load(config_file)
            expect(config.models).to eq([])
            expect(config.models_configured?).to be false
          end
        end
      end

      # context "with ClaudeCode environment variables" do
      #   it "creates a default model from environment variables" do
      #     with_env("ANTHROPIC_API_KEY" => "sk-test-env-key", "ANTHROPIC_BASE_URL" => "https://api.env.test.com") do
      #       with_temp_config do |config_file|
      #         FileUtils.rm_f(config_file)
      #
      #         config = described_class.load(config_file)
      #
      #         expect(config.models.length).to eq(1)
      #         expect(config.models.first["model"]).to eq("claude-sonnet-4-5")
      #         expect(config.models.first["api_key"]).to eq("sk-test-env-key")
      #         expect(config.models.first["base_url"]).to eq("https://api.env.test.com")
      #         expect(config.models.first["anthropic_format"]).to be true
      #       end
      #     end
      #   end
      # end
    end

    context "when config file exists with new top-level array format" do
      it "loads array of models directly" do
        with_temp_config([
          {
            "model" => "claude-sonnet-4",
            "api_key" => "sk-key1",
            "base_url" => "https://api.test.com",
            "anthropic_format" => true
          },
          {
            "model" => "gpt-4",
            "api_key" => "sk-key2",
            "base_url" => "https://api.openai.com",
            "anthropic_format" => false
          }
        ]) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(2)
          expect(config.models[0]["model"]).to eq("claude-sonnet-4")
          expect(config.models[0]["api_key"]).to eq("sk-key1")
          expect(config.models[1]["model"]).to eq("gpt-4")
          expect(config.models[1]["api_key"]).to eq("sk-key2")
        end
      end
    end

    context "backward compatibility with old models: key format" do
      it "loads array under models key" do
        with_temp_config({
          "models" => [
            {
              "model" => "claude-sonnet-4",
              "api_key" => "sk-key1",
              "base_url" => "https://api.test.com",
              "anthropic_format" => true
            },
            {
              "model" => "gpt-4",
              "api_key" => "sk-key2",
              "base_url" => "https://api.openai.com",
              "anthropic_format" => false
            }
          ]
        }) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(2)
          expect(config.models[0]["model"]).to eq("claude-sonnet-4")
          expect(config.models[1]["model"]).to eq("gpt-4")
        end
      end

      it "converts old name field to model field" do
        with_temp_config({
          "models" => [
            {
              "name" => "default",
              "api_key" => "sk-key1",
              "base_url" => "https://api.test.com",
              "anthropic_format" => true
            }
          ]
        }) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(1)
          expect(config.models[0]["model"]).to eq("default")
          expect(config.models[0]["name"]).to be_nil
        end
      end
    end

    context "backward compatibility with old hash format" do
      it "converts old tier-based hash to new array format" do
        with_temp_config({
          "models" => {
            "claude-sonnet-4" => {
              "api_key" => "sk-old-key",
              "base_url" => "https://api.old.com",
              "model_name" => "claude-sonnet-4",
              "anthropic_format" => true
            },
            "claude-opus-4" => {
              "api_key" => "sk-old-key",
              "base_url" => "https://api.old.com",
              "model_name" => "claude-opus-4",
              "anthropic_format" => true
            }
          }
        }) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(2)
          expect(config.models[0]["model"]).to eq("claude-sonnet-4")
          expect(config.models[1]["model"]).to eq("claude-opus-4")
        end
      end

      it "converts very old format with single model" do
        with_temp_config({
          "api_key" => "sk-very-old",
          "base_url" => "https://api.very-old.com",
          "model" => "claude-2",
          "anthropic_format" => false
        }) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(1)
          expect(config.models[0]["api_key"]).to eq("sk-very-old")
          expect(config.models[0]["model"]).to eq("claude-2")
          expect(config.models[0]["anthropic_format"]).to be false
        end
      end
    end
  end

  describe "#save" do
    it "saves configuration as hash with settings and models" do
      with_temp_config do |config_file|
        config = described_class.new(
          models: [
            {
              "model" => "test-model",
              "api_key" => "sk-test",
              "base_url" => "https://api.test.com",
              "anthropic_format" => true
            }
          ]
        )

        config.save(config_file)

        expect(File.exist?(config_file)).to be true
        
        loaded_data = YAML.load_file(config_file)
        expect(loaded_data).to be_a(Hash)
        expect(loaded_data).to have_key("settings")
        expect(loaded_data).to have_key("models")
        expect(loaded_data["models"]).to be_a(Array)
        expect(loaded_data["models"].length).to eq(1)
        expect(loaded_data["models"][0]["api_key"]).to eq("sk-test")
        expect(loaded_data["models"][0]["model"]).to eq("test-model")
      end
    end

    it "sets file permissions to 0600" do
      with_temp_config do |config_file|
        config = described_class.new(models: [])
        config.save(config_file)

        stat = File.stat(config_file)
        expect(sprintf("%o", stat.mode & 0o777)).to eq("600")
      end
    end
  end

  describe "#models_configured?" do
    it "returns true when models are configured" do
      config = described_class.new(
        models: [{ "model" => "test-model" }]
      )
      expect(config.models_configured?).to be true
    end

    it "returns false when models array is empty" do
      config = described_class.new(models: [])
      expect(config.models_configured?).to be false
    end
  end

  describe "#current_model" do
    it "returns the first model by default" do
      config = described_class.new(
        models: [
          { "model" => "model-1" },
          { "model" => "model-2" }
        ]
      )
      
      expect(config.current_model["model"]).to eq("model-1")
    end

    it "returns nil when no models configured" do
      config = described_class.new(models: [])
      expect(config.current_model).to be_nil
    end
  end

  describe "#current_model_supports?" do
    it "returns true when no models are configured (conservative default)" do
      config = described_class.new(models: [])
      expect(config.current_model_supports?(:vision)).to be true
    end

    it "returns true when current model has no base_url" do
      # Defensive: a partial/invalid model entry shouldn't trigger a false-negative.
      config = described_class.new(models: [{ "model" => "m-1" }])
      expect(config.current_model_supports?(:vision)).to be true
    end

    it "returns true for a custom (non-preset) base_url" do
      # Self-hosted or unknown endpoint: assume capabilities supported; the
      # user knows their stack better than our preset list.
      config = described_class.new(
        models: [{ "api_key" => "x", "base_url" => "https://my-proxy.example/v1", "model" => "anything" }]
      )
      expect(config.current_model_supports?(:vision)).to be true
    end

    it "returns false for MiniMax (provider-level vision:false)" do
      config = described_class.new(
        models: [{ "api_key" => "x", "base_url" => "https://api.minimaxi.com/v1", "model" => "MiniMax-M2.7" }]
      )
      expect(config.current_model_supports?(:vision)).to be false
    end

    it "returns true for openclacky + Claude model" do
      config = described_class.new(
        models: [{ "api_key" => "x", "base_url" => "https://api.openclacky.com", "model" => "abs-claude-opus-4-7" }]
      )
      expect(config.current_model_supports?(:vision)).to be true
    end

    it "returns false for openclacky + DeepSeek model (model-level override)" do
      config = described_class.new(
        models: [{ "api_key" => "x", "base_url" => "https://api.openclacky.com", "model" => "dsk-deepseek-v4-pro" }]
      )
      expect(config.current_model_supports?(:vision)).to be false
    end

    it "tracks the currently-active model when multiple are configured" do
      # Switching the current model must immediately change the answer —
      # no caching, no stale state.
      config = described_class.new(
        models: [
          { "id" => "a", "api_key" => "x", "base_url" => "https://api.openclacky.com", "model" => "abs-claude-opus-4-7" },
          { "id" => "b", "api_key" => "x", "base_url" => "https://api.openclacky.com", "model" => "dsk-deepseek-v4-pro" }
        ]
      )

      config.instance_variable_set(:@current_model_id, "a")
      expect(config.current_model_supports?(:vision)).to be true

      config.instance_variable_set(:@current_model_id, "b")
      expect(config.current_model_supports?(:vision)).to be false
    end

    it "accepts either Symbol or String capability names" do
      config = described_class.new(
        models: [{ "api_key" => "x", "base_url" => "https://api.minimaxi.com/v1", "model" => "MiniMax-M2.7" }]
      )
      expect(config.current_model_supports?(:vision)).to be false
      expect(config.current_model_supports?("vision")).to be false
    end

    it "returns true for an unknown capability name (conservative default)" do
      config = described_class.new(
        models: [{ "api_key" => "x", "base_url" => "https://api.minimaxi.com/v1", "model" => "MiniMax-M2.7" }]
      )
      expect(config.current_model_supports?(:some_future_cap)).to be true
    end
  end

  describe "#get_model" do
    let(:config) do
      described_class.new(
        models: [
          { "model" => "model-1", "api_key" => "key1" },
          { "model" => "model-2", "api_key" => "key2" }
        ]
      )
    end

    it "returns model by index" do
      model = config.get_model(1)
      expect(model["model"]).to eq("model-2")
      expect(model["api_key"]).to eq("key2")
    end

    it "returns nil for out of range index" do
      expect(config.get_model(10)).to be_nil
    end
  end

  describe "#model_names" do
    it "returns array of model names" do
      config = described_class.new(
        models: [
          { "model" => "claude-sonnet-4" },
          { "model" => "gpt-4" },
          { "model" => "custom-model" }
        ]
      )

      expect(config.model_names).to eq(["claude-sonnet-4", "gpt-4", "custom-model"])
    end

    it "returns empty array when no models" do
      config = described_class.new(models: [])
      expect(config.model_names).to eq([])
    end
  end

  describe "#api_key" do
    it "returns api_key for current model" do
      config = described_class.new(
        models: [{ "model" => "test", "api_key" => "sk-test-key" }]
      )
      expect(config.api_key).to eq("sk-test-key")
    end

    it "returns nil when no models" do
      config = described_class.new(models: [])
      expect(config.api_key).to be_nil
    end
  end

  describe "#base_url" do
    it "returns base_url for current model" do
      config = described_class.new(
        models: [{ "model" => "test", "base_url" => "https://api.test.com" }]
      )
      expect(config.base_url).to eq("https://api.test.com")
    end

    it "returns nil when no models" do
      config = described_class.new(models: [])
      expect(config.base_url).to be_nil
    end
  end

  describe "#model_name" do
    it "returns model name for current model" do
      config = described_class.new(
        models: [{ "model" => "claude-sonnet-4" }]
      )
      expect(config.model_name).to eq("claude-sonnet-4")
    end

    it "returns nil when no models" do
      config = described_class.new(models: [])
      expect(config.model_name).to be_nil
    end
  end

  describe "#anthropic_format?" do
    it "returns true when anthropic_format is true" do
      config = described_class.new(
        models: [{ "model" => "test", "anthropic_format" => true }]
      )
      expect(config.anthropic_format?).to be true
    end

    it "returns false when anthropic_format is false" do
      config = described_class.new(
        models: [{ "model" => "test", "anthropic_format" => false }]
      )
      expect(config.anthropic_format?).to be false
    end

    it "returns false when anthropic_format is not set" do
      config = described_class.new(
        models: [{ "model" => "test" }]
      )
      expect(config.anthropic_format?).to be false
    end
  end

  describe "#add_model" do
    it "adds a new model to the array" do
      config = described_class.new(models: [])
      
      config.add_model(
        model: "new-model",
        api_key: "sk-new",
        base_url: "https://api.new.com",
        anthropic_format: true
      )

      expect(config.models.length).to eq(1)
      expect(config.models[0]["model"]).to eq("new-model")
      expect(config.models[0]["api_key"]).to eq("sk-new")
    end

    it "adds multiple models" do
      config = described_class.new(models: [])
      
      config.add_model(model: "model-1", api_key: "key1", base_url: "url1")
      config.add_model(model: "model-2", api_key: "key2", base_url: "url2")

      expect(config.models.length).to eq(2)
      expect(config.model_names).to eq(["model-1", "model-2"])
    end
  end

  describe "#remove_model" do
    let(:config) do
      described_class.new(
        models: [
          { "model" => "model-1" },
          { "model" => "model-2" },
          { "model" => "model-3" }
        ]
      )
    end

    it "removes model by index" do
      expect(config.remove_model(1)).to be true
      expect(config.models.length).to eq(2)
      expect(config.model_names).to eq(["model-1", "model-3"])
    end

    it "returns false when trying to remove last model" do
      single_model_config = described_class.new(
        models: [{ "model" => "only-one" }]
      )
      
      expect(single_model_config.remove_model(0)).to be false
      expect(single_model_config.models.length).to eq(1)
    end

    it "returns false for out of range index" do
      expect(config.remove_model(10)).to be false
      expect(config.models.length).to eq(3)
    end

    it "adjusts current_model_index when necessary" do
      last_id = config.models[2]["id"]
      config.switch_model_by_id(last_id) # Switch to last model
      expect(config.current_model["model"]).to eq("model-3")

      config.remove_model(2) # Remove last model
      expect(config.current_model["model"]).to eq("model-2")
    end
  end

  describe "permission modes" do
    it "defaults to confirm_safes mode" do
      config = described_class.new
      expect(config.permission_mode).to eq(:confirm_safes)
    end

    it "accepts valid permission modes" do
      config = described_class.new(permission_mode: :auto_approve)
      expect(config.permission_mode).to eq(:auto_approve)
    end

    it "raises error for invalid permission mode" do
      expect {
        described_class.new(permission_mode: :invalid_mode)
      }.to raise_error(ArgumentError, /Invalid permission mode/)
    end
  end

  describe "type field support" do
    describe "#find_model_by_type" do
      it "returns model with specified type" do
        models = [
          { "model" => "sonnet", "type" => "default" },
          { "model" => "haiku", "type" => "lite" },
          { "model" => "opus" }
        ]
        config = described_class.new(models: models)
        
        expect(config.find_model_by_type("default")["model"]).to eq("sonnet")
        expect(config.find_model_by_type("lite")["model"]).to eq("haiku")
        expect(config.find_model_by_type("other")).to be_nil
      end
    end

    describe "#lite_model" do
      it "returns lite model if configured" do
        models = [
          { "model" => "sonnet", "type" => "default" },
          { "model" => "haiku", "type" => "lite" }
        ]
        config = described_class.new(models: models)
        
        expect(config.lite_model["model"]).to eq("haiku")
      end

      it "returns nil if no lite model" do
        models = [{ "model" => "sonnet", "type" => "default" }]
        config = described_class.new(models: models)
        
        expect(config.lite_model).to be_nil
      end
    end

    describe "#current_model" do
      it "returns model with type: default" do
        models = [
          { "model" => "opus" },
          { "model" => "sonnet", "type" => "default" },
          { "model" => "haiku", "type" => "lite" }
        ]
        config = described_class.new(models: models)
        
        expect(config.current_model["model"]).to eq("sonnet")
      end

      it "falls back to index-based for backward compatibility" do
        models = [
          { "model" => "opus" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models, current_model_index: 1)
        
        expect(config.current_model["model"]).to eq("sonnet")
      end
    end

    describe "#switch_model_by_id" do
      it "switches the current session model without touching the global type: default marker" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet" },
          { "model" => "haiku", "type" => "lite" }
        ]
        config = described_class.new(models: models)
        sonnet_id = config.models[1]["id"]

        expect(config.switch_model_by_id(sonnet_id)).to be true

        # Current session now points at sonnet
        expect(config.current_model["model"]).to eq("sonnet")
        expect(config.current_model_id).to eq(sonnet_id)
        expect(config.current_model_index).to eq(1)

        # Global type markers are UNCHANGED — "default" is a Settings-level
        # concept, switching the session's current model must not mutate it.
        expect(config.models[0]["type"]).to eq("default")
        expect(config.models[1]["type"]).to be_nil
        expect(config.models[2]["type"]).to eq("lite")
      end

      it "returns false for unknown id" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models)

        expect(config.switch_model_by_id("nonexistent")).to be false
        expect(config.switch_model_by_id(nil)).to be false
        expect(config.switch_model_by_id("")).to be false
      end
    end

    describe "#set_default_model_by_id" do
      it "moves the global type: default marker to the given model" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet" },
          { "model" => "haiku", "type" => "lite" }
        ]
        config = described_class.new(models: models)
        sonnet_id = config.models[1]["id"]

        expect(config.set_default_model_by_id(sonnet_id)).to be true

        # Marker moved to sonnet
        expect(config.models[0]["type"]).to be_nil
        expect(config.models[1]["type"]).to eq("default")
        # Other type markers (lite) untouched
        expect(config.models[2]["type"]).to eq("lite")
      end

      it "does not change the current session's model (session vs global are separate)" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models)
        opus_id = config.models[0]["id"]
        sonnet_id = config.models[1]["id"]

        # Currently on opus (anchored via type: default)
        expect(config.current_model_id).to eq(opus_id)

        config.set_default_model_by_id(sonnet_id)

        # Global default is now sonnet, but this session is still on opus
        expect(config.models[1]["type"]).to eq("default")
        expect(config.current_model_id).to eq(opus_id)
        expect(config.current_model["model"]).to eq("opus")
      end

      it "handles the case when no model currently has type: default" do
        models = [
          { "model" => "opus" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models)
        sonnet_id = config.models[1]["id"]

        expect(config.set_default_model_by_id(sonnet_id)).to be true
        expect(config.models[0]["type"]).to be_nil
        expect(config.models[1]["type"]).to eq("default")
      end

      it "is idempotent when called on the already-default model" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models)
        opus_id = config.models[0]["id"]

        expect(config.set_default_model_by_id(opus_id)).to be true
        expect(config.models[0]["type"]).to eq("default")
        expect(config.models[1]["type"]).to be_nil
      end

      it "clears any stale duplicate default markers" do
        # Defensive: config.yml could in theory have two `type: default`
        # entries if hand-edited. Setting default on a third model should
        # clean all of them.
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet", "type" => "default" },
          { "model" => "haiku" }
        ]
        config = described_class.new(models: models)
        haiku_id = config.models[2]["id"]

        config.set_default_model_by_id(haiku_id)

        expect(config.models[0]["type"]).to be_nil
        expect(config.models[1]["type"]).to be_nil
        expect(config.models[2]["type"]).to eq("default")
      end

      it "returns false for unknown id / nil / empty" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models)

        expect(config.set_default_model_by_id("nonexistent")).to be false
        expect(config.set_default_model_by_id(nil)).to be false
        expect(config.set_default_model_by_id("")).to be false

        # Original default unchanged on failure
        expect(config.models[0]["type"]).to eq("default")
      end
    end

    describe "#set_model_type" do
      it "sets type on specified model" do
        models = [
          { "model" => "opus" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models)
        
        config.set_model_type(0, "default")
        config.set_model_type(1, "lite")
        
        expect(config.models[0]["type"]).to eq("default")
        expect(config.models[1]["type"]).to eq("lite")
      end

      it "ensures only one model has each type" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models)
        
        config.set_model_type(1, "default")
        
        expect(config.models[0]["type"]).to be_nil
        expect(config.models[1]["type"]).to eq("default")
      end

      it "removes type when set to nil" do
        models = [{ "model" => "opus", "type" => "default" }]
        config = described_class.new(models: models)
        
        config.set_model_type(0, nil)
        
        expect(config.models[0]["type"]).to be_nil
      end
    end
  end

  describe "ClackyEnv environment variables" do
    describe "default model" do
      it "loads from CLACKY_XXX env vars when config is empty" do
        with_env(
          "CLACKY_API_KEY" => "sk-clacky-test",
          "CLACKY_BASE_URL" => "https://api.clacky.test",
          "CLACKY_MODEL" => "claude-test-model",
          "CLACKY_ANTHROPIC_FORMAT" => "false"
        ) do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file)
            
            config = described_class.load(config_file)
            
            expect(config.models.length).to eq(1)
            expect(config.models.first["type"]).to eq("default")
            expect(config.models.first["api_key"]).to eq("sk-clacky-test")
            expect(config.models.first["base_url"]).to eq("https://api.clacky.test")
            expect(config.models.first["model"]).to eq("claude-test-model")
            expect(config.models.first["anthropic_format"]).to be false
          end
        end
      end

      it "uses default model name if CLACKY_MODEL not set" do
        with_env("CLACKY_API_KEY" => "sk-test") do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file)
            
            config = described_class.load(config_file)
            
            expect(config.models.first["model"]).to eq("claude-sonnet-4-5")
          end
        end
      end
    end

    describe "lite model" do
      it "loads from CLACKY_LITE_XXX env vars" do
        with_env(
          "CLACKY_API_KEY" => "sk-default",
          "CLACKY_LITE_API_KEY" => "sk-lite",
          "CLACKY_LITE_MODEL" => "claude-haiku-test"
        ) do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file)
            
            config = described_class.load(config_file)
            
            expect(config.models.length).to eq(2)
            expect(config.models[0]["type"]).to eq("default")
            expect(config.models[1]["type"]).to eq("lite")
            expect(config.models[1]["api_key"]).to eq("sk-lite")
            expect(config.models[1]["model"]).to eq("claude-haiku-test")
          end
        end
      end
    end

    describe "priority: config file > CLACKY_XXX > ClaudeCode" do
      it "prefers config file over environment variables" do
        with_env(
          "CLACKY_API_KEY" => "sk-env",
          "ANTHROPIC_API_KEY" => "sk-claude"
        ) do
          with_temp_config([{ "model" => "from-file", "api_key" => "sk-file", "type" => "default" }]) do |config_file|
            config = described_class.load(config_file)
            
            expect(config.models.length).to eq(1)
            expect(config.models.first["api_key"]).to eq("sk-file")
          end
        end
      end

      it "prefers CLACKY_XXX over ClaudeCode env vars" do
        with_env(
          "CLACKY_API_KEY" => "sk-clacky",
          "ANTHROPIC_API_KEY" => "sk-claude"
        ) do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file)
            
            config = described_class.load(config_file)
            
            expect(config.models.first["api_key"]).to eq("sk-clacky")
          end
        end
      end

      # it "falls back to ClaudeCode if CLACKY_XXX not set" do
      #   with_env("ANTHROPIC_API_KEY" => "sk-claude") do
      #     with_temp_config do |config_file|
      #       FileUtils.rm_f(config_file)
      #
      #       config = described_class.load(config_file)
      #
      #       expect(config.models.first["api_key"]).to eq("sk-claude")
      #       expect(config.models.first["type"]).to eq("default")
      #     end
      #   end
      # end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Lite model resolution (virtual, on-demand; no longer materialized into @models)
  # ─────────────────────────────────────────────────────────────────────────
  describe "#lite_model_config_for_current (virtual lite derivation)" do
    context "when clackyai-sea is the configured provider (base_url matches)" do
      it "does NOT materialize lite into @models at load time" do
        with_temp_config([
          {
            "model"            => "abs-claude-sonnet-4-6",
            "api_key"          => "absk-test-key",
            "base_url"         => "https://api.clacky.ai",
            "anthropic_format" => false,
            "type"             => "default"
          }
        ]) do |config_file|
          config = described_class.load(config_file)

          # Under the new architecture @models stays a clean list of
          # user-facing models. Lite is derived virtually.
          expect(config.models.length).to eq(1)
          expect(config.lite_model).to be_nil   # no explicit env lite
        end
      end

      it "derives a virtual lite config that pairs the Claude family with Haiku" do
        with_temp_config([
          {
            "model"            => "abs-claude-sonnet-4-6",
            "api_key"          => "absk-test-key",
            "base_url"         => "https://api.clacky.ai",
            "anthropic_format" => false,
            "type"             => "default"
          }
        ]) do |config_file|
          config = described_class.load(config_file)
          lite = config.lite_model_config_for_current

          expect(lite).not_to be_nil
          expect(lite["model"]).to eq("abs-claude-haiku-4-5")
          expect(lite["api_key"]).to eq("absk-test-key")
          expect(lite["base_url"]).to eq("https://api.clacky.ai")
          expect(lite["type"]).to eq("lite")
          expect(lite["virtual"]).to be true
        end
      end

      it "returns nil when the current model IS already a lite-class model (Haiku)" do
        with_temp_config([
          {
            "model"            => "abs-claude-haiku-4-5",
            "api_key"          => "absk-test-key",
            "base_url"         => "https://api.clacky.ai",
            "anthropic_format" => false,
            "type"             => "default"
          }
        ]) do |config_file|
          config = described_class.load(config_file)
          expect(config.lite_model_config_for_current).to be_nil
        end
      end

      it "prefers an explicit user-configured lite (type: lite) over provider derivation" do
        with_temp_config([
          {
            "model"            => "abs-claude-sonnet-4-6",
            "api_key"          => "absk-test-key",
            "base_url"         => "https://api.clacky.ai",
            "anthropic_format" => false,
            "type"             => "default"
          },
          {
            "model"            => "my-custom-lite",
            "api_key"          => "absk-test-key",
            "base_url"         => "https://api.clacky.ai",
            "anthropic_format" => false,
            "type"             => "lite"
          }
        ]) do |config_file|
          config = described_class.load(config_file)
          lite = config.lite_model_config_for_current
          expect(lite["model"]).to eq("my-custom-lite")
          # explicit entry is NOT a virtual hash — it's a real @models row
          expect(lite["virtual"]).to be_nil
        end
      end
    end

    context "when openclacky is the configured provider (DeepSeek lite pairing)" do
      it "pairs the DeepSeek family with V4-flash (runtime follows current model)" do
        # Two user-facing models — one Claude, one DeepSeek — with Claude as
        # default. Switching primary to DeepSeek should flip the derived lite
        # from Haiku to DSK-v4-flash automatically.
        with_temp_config([
          {
            "model"            => "abs-claude-sonnet-4-6",
            "api_key"          => "clacky-test-key",
            "base_url"         => "https://api.openclacky.com",
            "anthropic_format" => false,
            "type"             => "default"
          },
          {
            "model"            => "dsk-deepseek-v4-pro",
            "api_key"          => "clacky-test-key",
            "base_url"         => "https://api.openclacky.com",
            "anthropic_format" => false
          }
        ]) do |config_file|
          config = described_class.load(config_file)

          # Start on Claude → lite = Haiku
          lite1 = config.lite_model_config_for_current
          expect(lite1["model"]).to eq("abs-claude-haiku-4-5")

          # Switch to DSK-pro → lite follows, now V4-flash
          dsk = config.models.find { |m| m["model"] == "dsk-deepseek-v4-pro" }
          expect(config.switch_model_by_id(dsk["id"])).to be true
          lite2 = config.lite_model_config_for_current
          expect(lite2["model"]).to eq("dsk-deepseek-v4-flash")
        end
      end
    end

    context "when provider is unknown" do
      it "returns nil (no derivation possible)" do
        with_temp_config([
          {
            "model"            => "some-model",
            "api_key"          => "sk-custom",
            "base_url"         => "https://api.custom-provider.com",
            "anthropic_format" => false,
            "type"             => "default"
          }
        ]) do |config_file|
          config = described_class.load(config_file)
          expect(config.models.length).to eq(1)
          expect(config.lite_model_config_for_current).to be_nil
        end
      end
    end

    describe "#to_yaml / #save persistence" do
      it "does not leak any lite entry to disk when lite is purely virtual" do
        with_temp_config([
          {
            "model"            => "abs-claude-sonnet-4-6",
            "api_key"          => "absk-test-key",
            "base_url"         => "https://api.clacky.ai",
            "anthropic_format" => false,
            "type"             => "default"
          }
        ]) do |config_file|
          config = described_class.load(config_file)

          # Virtual lite is available...
          expect(config.lite_model_config_for_current).not_to be_nil

          # ...but @models and disk only hold the explicit default
          expect(config.models.length).to eq(1)
          config.save(config_file)
          saved = YAML.load_file(config_file)
          expect(saved["models"].length).to eq(1)
          expect(saved["models"].none? { |m| m["type"] == "lite" }).to be true
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Providers.find_by_base_url
  # ─────────────────────────────────────────────────────────────────────────
  describe "Clacky::Providers.find_by_base_url" do
    it "returns clackyai-sea for https://api.clacky.ai" do
      expect(Clacky::Providers.find_by_base_url("https://api.clacky.ai")).to eq("clackyai-sea")
    end

    it "is tolerant of trailing slashes" do
      expect(Clacky::Providers.find_by_base_url("https://api.clacky.ai/")).to eq("clackyai-sea")
    end

    it "matches sub-path variants like /v1" do
      expect(Clacky::Providers.find_by_base_url("https://api.clacky.ai/v1")).to eq("clackyai-sea")
    end

    it "matches sub-path variants like /v1/" do
      expect(Clacky::Providers.find_by_base_url("https://api.clacky.ai/v1/")).to eq("clackyai-sea")
    end

    it "returns nil for unknown base URLs" do
      expect(Clacky::Providers.find_by_base_url("https://unknown.example.com")).to be_nil
    end

    it "returns nil for nil input" do
      expect(Clacky::Providers.find_by_base_url(nil)).to be_nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Providers.lite_model (per-family lookup)
  # ─────────────────────────────────────────────────────────────────────────
  describe "Clacky::Providers.lite_model" do
    context "clackyai-sea (Claude-only lite_models table)" do
      it "returns Haiku for Claude-family primaries" do
        expect(Clacky::Providers.lite_model("clackyai-sea", "abs-claude-sonnet-4-6"))
          .to eq("abs-claude-haiku-4-5")
        expect(Clacky::Providers.lite_model("clackyai-sea", "abs-claude-opus-4-6"))
          .to eq("abs-claude-haiku-4-5")
      end

      it "returns nil for lite-class primaries (Haiku)" do
        expect(Clacky::Providers.lite_model("clackyai-sea", "abs-claude-haiku-4-5")).to be_nil
      end

      it "returns nil for models not in the lite_models table (e.g. DeepSeek, not hosted)" do
        # clackyai-sea only hosts Claude; DeepSeek models are not mapped.
        expect(Clacky::Providers.lite_model("clackyai-sea", "dsk-deepseek-v4-pro")).to be_nil
      end

      it "returns nil when called without a primary on a per-family provider" do
        # Per-family providers require context — no sensible global default.
        expect(Clacky::Providers.lite_model("clackyai-sea")).to be_nil
      end
    end

    it "returns nil for providers without any lite mapping (e.g. minimax)" do
      expect(Clacky::Providers.lite_model("minimax")).to be_nil
      expect(Clacky::Providers.lite_model("minimax", "MiniMax-M2")).to be_nil
    end

    it "returns nil for unknown provider IDs" do
      expect(Clacky::Providers.lite_model("nonexistent")).to be_nil
      expect(Clacky::Providers.lite_model("nonexistent", "anything")).to be_nil
    end
  end

  # Helper to set environment variables temporarily
  def with_env(vars)
    old_values = {}
    vars.each do |key, value|
      old_values[key] = ENV[key]
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    old_values.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
