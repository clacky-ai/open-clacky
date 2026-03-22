# frozen_string_literal: true

RSpec.describe Clacky::McpConfig do
  # Use a temp directory for all file-based tests to avoid touching real config
  around(:each) do |example|
    Dir.mktmpdir("mcp_config_spec") do |tmpdir|
      @tmpdir = tmpdir
      example.run
    end
  end

  # Helper: write a mcp.yml file under a given base dir
  def write_mcp_yml(base_dir, content)
    config_dir = File.join(base_dir, ".clacky")
    FileUtils.mkdir_p(config_dir)
    path = File.join(config_dir, "mcp.yml")
    File.write(path, content)
    path
  end

  # -------------------------------------------------------------------------
  # .load
  # -------------------------------------------------------------------------
  describe ".load" do
    context "when no config files exist" do
      it "returns an empty McpConfig" do
        cfg = described_class.load(
          working_dir: @tmpdir,
          user_config_file: File.join(@tmpdir, "nonexistent_user.yml")
        )
        expect(cfg).to be_a(described_class)
        expect(cfg.any?).to be false
        expect(cfg.count).to eq(0)
      end
    end

    context "with only a user-level config" do
      it "loads servers from the user file" do
        user_file = File.join(@tmpdir, "user_mcp.yml")
        File.write(user_file, <<~YAML)
          mcpServers:
            filesystem:
              type: stdio
              command: npx
              args:
                - "-y"
                - "@modelcontextprotocol/server-filesystem"
        YAML

        cfg = described_class.load(user_config_file: user_file)
        expect(cfg.count).to eq(1)
        expect(cfg.server_names).to include("filesystem")
        expect(cfg.source_of("filesystem")).to eq(:user)

        fs = cfg.server("filesystem")
        expect(fs["type"]).to eq("stdio")
        expect(fs["command"]).to eq("npx")
        expect(fs["args"]).to eq(["-y", "@modelcontextprotocol/server-filesystem"])
      end
    end

    context "with only a project-level config" do
      it "loads servers from the project .clacky/mcp.yml" do
        write_mcp_yml(@tmpdir, <<~YAML)
          mcpServers:
            github:
              type: sse
              url: https://mcp.github.com/sse
        YAML

        user_file = File.join(@tmpdir, "nonexistent.yml")
        cfg = described_class.load(working_dir: @tmpdir, user_config_file: user_file)

        expect(cfg.count).to eq(1)
        expect(cfg.server_names).to include("github")
        expect(cfg.source_of("github")).to eq(:project)
      end
    end

    context "when both user-level and project-level configs exist" do
      it "merges both, with project-level taking precedence for duplicate keys" do
        user_file = File.join(@tmpdir, "user_mcp.yml")
        File.write(user_file, <<~YAML)
          mcpServers:
            filesystem:
              type: stdio
              command: npx
              args:
                - "@modelcontextprotocol/server-filesystem"
            shared_server:
              type: sse
              url: https://user-level.example.com/sse
        YAML

        write_mcp_yml(@tmpdir, <<~YAML)
          mcpServers:
            github:
              type: sse
              url: https://mcp.github.com/sse
            shared_server:
              type: http
              url: https://project-level.example.com/mcp
        YAML

        cfg = described_class.load(working_dir: @tmpdir, user_config_file: user_file)

        # All three server names should be present
        expect(cfg.server_names).to match_array(%w[filesystem shared_server github])

        # shared_server should be the project-level version
        shared = cfg.server("shared_server")
        expect(shared["type"]).to eq("http")
        expect(shared["url"]).to eq("https://project-level.example.com/mcp")
        expect(cfg.source_of("shared_server")).to eq(:project)

        # filesystem from user level
        expect(cfg.source_of("filesystem")).to eq(:user)

        # github from project level
        expect(cfg.source_of("github")).to eq(:project)
      end
    end

    context "when working_dir is nil" do
      it "only loads the user-level config" do
        user_file = File.join(@tmpdir, "user_mcp.yml")
        File.write(user_file, <<~YAML)
          mcpServers:
            myserver:
              type: stdio
              command: my-tool
        YAML

        cfg = described_class.load(working_dir: nil, user_config_file: user_file)
        expect(cfg.count).to eq(1)
        expect(cfg.source_of("myserver")).to eq(:user)
      end
    end

    context "with a malformed YAML file" do
      it "gracefully returns an empty config and warns" do
        user_file = File.join(@tmpdir, "bad.yml")
        File.write(user_file, "mcpServers: [this is not, a hash")

        expect do
          cfg = described_class.load(user_config_file: user_file)
          expect(cfg.any?).to be false
        end.to output(/McpConfig/).to_stderr
      end
    end

    context "with mcpServers as a non-hash value" do
      it "gracefully returns empty and warns" do
        user_file = File.join(@tmpdir, "bad_type.yml")
        File.write(user_file, "mcpServers:\n  - item1\n  - item2\n")

        expect do
          cfg = described_class.load(user_config_file: user_file)
          expect(cfg.any?).to be false
        end.to output(/McpConfig/).to_stderr
      end
    end
  end

  # -------------------------------------------------------------------------
  # #validate
  # -------------------------------------------------------------------------
  describe "#validate" do
    subject(:cfg) { described_class.new(servers: servers, source_map: {}) }

    context "with a valid stdio server" do
      let(:servers) do
        {
          "filesystem" => {
            "type"    => "stdio",
            "command" => "npx",
            "args"    => ["-y", "@modelcontextprotocol/server-filesystem"]
          }
        }
      end

      it "returns no errors" do
        expect(cfg.validate).to be_empty
        expect(cfg.valid?).to be true
      end
    end

    context "with a valid sse server" do
      let(:servers) do
        {
          "github" => {
            "type"    => "sse",
            "url"     => "https://mcp.github.com/sse",
            "headers" => { "Authorization" => "Bearer tok" }
          }
        }
      end

      it "returns no errors" do
        expect(cfg.validate).to be_empty
      end
    end

    context "with a valid http server" do
      let(:servers) do
        { "api" => { "type" => "http", "url" => "https://example.com/mcp" } }
      end

      it "returns no errors" do
        expect(cfg.validate).to be_empty
      end
    end

    context "when type is missing" do
      let(:servers) { { "bad" => { "command" => "npx" } } }

      it "reports missing type error" do
        errors = cfg.validate
        expect(errors["bad"]).to include(match(/missing required field 'type'/))
      end
    end

    context "when type is invalid" do
      let(:servers) { { "bad" => { "type" => "grpc" } } }

      it "reports invalid type error" do
        errors = cfg.validate
        expect(errors["bad"]).to include(match(/invalid type 'grpc'/))
      end
    end

    context "when stdio server is missing command" do
      let(:servers) { { "bad" => { "type" => "stdio" } } }

      it "reports missing command error" do
        errors = cfg.validate
        expect(errors["bad"]).to include(match(/missing required field 'command'/))
      end
    end

    context "when stdio args is not an array" do
      let(:servers) do
        { "bad" => { "type" => "stdio", "command" => "npx", "args" => "not-an-array" } }
      end

      it "reports args type error" do
        errors = cfg.validate
        expect(errors["bad"]).to include(match(/'args' must be an Array/))
      end
    end

    context "when stdio env is not a hash" do
      let(:servers) do
        { "bad" => { "type" => "stdio", "command" => "npx", "env" => ["list"] } }
      end

      it "reports env type error" do
        errors = cfg.validate
        expect(errors["bad"]).to include(match(/'env' must be a Hash/))
      end
    end

    context "when sse server is missing url" do
      let(:servers) { { "bad" => { "type" => "sse" } } }

      it "reports missing url error" do
        errors = cfg.validate
        expect(errors["bad"]).to include(match(/missing required field 'url'/))
      end
    end

    context "when sse url does not start with http" do
      let(:servers) { { "bad" => { "type" => "sse", "url" => "ws://example.com" } } }

      it "reports invalid url scheme error" do
        errors = cfg.validate
        expect(errors["bad"]).to include(match(/http:\/\/ or https:\/\//))
      end
    end

    context "when headers is not a hash" do
      let(:servers) do
        { "bad" => { "type" => "http", "url" => "https://example.com", "headers" => "token" } }
      end

      it "reports headers type error" do
        errors = cfg.validate
        expect(errors["bad"]).to include(match(/'headers' must be a Hash/))
      end
    end

    context "with multiple servers where one is invalid" do
      let(:servers) do
        {
          "good" => { "type" => "stdio", "command" => "npx" },
          "bad"  => { "type" => "sse" }
        }
      end

      it "only reports errors for the invalid server" do
        errors = cfg.validate
        expect(errors.keys).to eq(["bad"])
        expect(cfg.valid?).to be false
      end
    end
  end

  # -------------------------------------------------------------------------
  # #set_server / #remove_server
  # -------------------------------------------------------------------------
  describe "#set_server and #remove_server" do
    let(:cfg) { described_class.new }

    it "adds a server and reflects in server_names" do
      cfg.set_server("new_srv", { "type" => "stdio", "command" => "tool" }, source: :user)
      expect(cfg.server_names).to include("new_srv")
      expect(cfg.source_of("new_srv")).to eq(:user)
    end

    it "removes a server" do
      cfg.set_server("removable", { "type" => "stdio", "command" => "x" })
      cfg.remove_server("removable")
      expect(cfg.server_names).not_to include("removable")
    end
  end

  # -------------------------------------------------------------------------
  # #save_user / #save_project
  # -------------------------------------------------------------------------
  describe "persistence" do
    it "#save_user writes only user-level servers to file" do
      user_file = File.join(@tmpdir, "out_user.yml")
      cfg = described_class.new(
        servers: {
          "srv_user"    => { "type" => "stdio", "command" => "tool_user" },
          "srv_project" => { "type" => "stdio", "command" => "tool_project" }
        },
        source_map: {
          "srv_user"    => :user,
          "srv_project" => :project
        }
      )

      cfg.save_user(user_file)
      data = YAML.safe_load(File.read(user_file))
      expect(data["mcpServers"].keys).to eq(["srv_user"])
    end

    it "#save_project writes only project-level servers to the project .clacky/mcp.yml" do
      cfg = described_class.new(
        servers: {
          "srv_user"    => { "type" => "stdio", "command" => "u" },
          "srv_project" => { "type" => "stdio", "command" => "p" }
        },
        source_map: {
          "srv_user"    => :user,
          "srv_project" => :project
        }
      )

      cfg.save_project(@tmpdir)
      project_file = File.join(@tmpdir, ".clacky", "mcp.yml")
      expect(File.exist?(project_file)).to be true
      data = YAML.safe_load(File.read(project_file))
      expect(data["mcpServers"].keys).to eq(["srv_project"])
    end
  end

  # -------------------------------------------------------------------------
  # #deep_copy
  # -------------------------------------------------------------------------
  describe "#deep_copy" do
    it "returns an independent copy" do
      original = described_class.new(
        servers: { "s1" => { "type" => "stdio", "command" => "x" } },
        source_map: { "s1" => :user }
      )
      copy = original.deep_copy

      # Mutate original's underlying data
      original.server("s1")["command"] = "mutated"

      # Copy should be unaffected
      expect(copy.server("s1")["command"]).to eq("x")
    end
  end

  # -------------------------------------------------------------------------
  # #all_servers
  # -------------------------------------------------------------------------
  describe "#all_servers" do
    it "embeds name and _source into each server hash" do
      cfg = described_class.new(
        servers: { "srv" => { "type" => "stdio", "command" => "tool" } },
        source_map: { "srv" => :user }
      )

      all = cfg.all_servers
      expect(all.size).to eq(1)
      entry = all.first
      expect(entry["name"]).to eq("srv")
      expect(entry["_source"]).to eq(:user)
      expect(entry["type"]).to eq("stdio")
    end
  end
end
