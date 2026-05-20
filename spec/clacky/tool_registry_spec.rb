# frozen_string_literal: true

RSpec.describe Clacky::ToolRegistry do
  # Build a minimal tool-like object for testing
  let(:mock_tool) do
    Struct.new(:name, :category, :to_function_definition).new("file_reader", "general", {})
  end
  let(:mock_tool2) do
    Struct.new(:name, :category, :to_function_definition).new("terminal", "general", {})
  end
  let(:mock_tool3) do
    Struct.new(:name, :category, :to_function_definition).new("web_search", "general", {})
  end

  describe "#register and #get" do
    it "registers and retrieves a tool by exact name" do
      registry = described_class.new
      registry.register(mock_tool)
      expect(registry.get("file_reader")).to eq(mock_tool)
    end

    it "raises ToolCallError for unknown tool" do
      registry = described_class.new
      expect { registry.get("nonexistent") }.to raise_error(Clacky::ToolCallError, /Tool not found/)
    end
  end

  describe "#resolve" do
    let(:registry) do
      r = described_class.new
      r.register(mock_tool)   # file_reader
      r.register(mock_tool2)  # terminal
      r.register(mock_tool3)  # web_search
      r
    end

    # Case-insensitive matching
    it "resolves exact name to itself" do
      expect(registry.resolve("file_reader")).to eq("file_reader")
    end

    it "resolves uppercase name via case-insensitive match" do
      expect(registry.resolve("File_reader")).to eq("file_reader")
    end

    it "resolves all-caps name via case-insensitive match" do
      expect(registry.resolve("FILE_READER")).to eq("file_reader")
    end

    it "resolves 'Read' to 'file_reader' via alias" do
      # "Read" downcases to "read", which is an alias for "file_reader"
      expect(registry.resolve("Read")).to eq("file_reader")
    end

    it "resolves 'Terminal' to 'terminal'" do
      expect(registry.resolve("Terminal")).to eq("terminal")
    end

    it "resolves 'Web_Search' to 'web_search'" do
      expect(registry.resolve("Web_Search")).to eq("web_search")
    end

    # Alias matching
    it "resolves 'read' alias to 'file_reader'" do
      expect(registry.resolve("read")).to eq("file_reader")
    end

    it "resolves 'Read' (capitalized alias) to 'file_reader'" do
      expect(registry.resolve("Read")).to eq("file_reader")
    end

    it "resolves 'read_file' alias to 'file_reader'" do
      expect(registry.resolve("read_file")).to eq("file_reader")
    end

    it "resolves 'Read_File' alias to 'file_reader'" do
      expect(registry.resolve("Read_File")).to eq("file_reader")
    end

    it "resolves 'shell' alias to 'terminal'" do
      expect(registry.resolve("shell")).to eq("terminal")
    end

    it "resolves 'bash' alias to 'terminal'" do
      expect(registry.resolve("bash")).to eq("terminal")
    end

    it "resolves 'search' alias to 'web_search'" do
      expect(registry.resolve("search")).to eq("web_search")
    end

    it "resolves 'write_file' alias to 'write'" do
      # write is not registered in this test registry, but resolve still maps the alias
      expect(registry.resolve("write_file")).to eq("write")
    end

    # Hyphen normalisation
    it "resolves 'file-reader' to 'file_reader' via hyphen normalisation" do
      expect(registry.resolve("file-reader")).to eq("file_reader")
    end

    it "resolves 'web-search' to 'web_search' via hyphen normalisation" do
      expect(registry.resolve("web-search")).to eq("web_search")
    end

    # Unknown names
    it "returns nil for completely unknown name" do
      expect(registry.resolve("foobar")).to be_nil
    end

    it "returns nil for unknown name with no close match" do
      expect(registry.resolve("xyz_abc")).to be_nil
    end
  end

  describe "#tool_names" do
    it "returns all registered tool names" do
      registry = described_class.new
      registry.register(mock_tool)
      registry.register(mock_tool2)
      expect(registry.tool_names).to contain_exactly("file_reader", "terminal")
    end
  end

  describe "#all" do
    it "returns all registered tools" do
      registry = described_class.new
      registry.register(mock_tool)
      registry.register(mock_tool2)
      expect(registry.all).to contain_exactly(mock_tool, mock_tool2)
    end
  end

  describe "#allowed_definitions" do
    it "returns all tools when allowed_tools includes all" do
      registry = described_class.new
      registry.register(mock_tool)
      registry.register(mock_tool2)

      expect(registry.allowed_definitions(["all"]).size).to eq(2)
    end

    it "filters definitions by allowed tool names" do
      registry = described_class.new
      registry.register(mock_tool)
      registry.register(mock_tool2)

      definitions = registry.allowed_definitions(["file_reader"])
      expect(definitions.size).to eq(1)
      expect(definitions.first).to eq({})
    end
  end

  describe "#allowed?" do
    it "allows all tools when allowlist is nil" do
      registry = described_class.new
      expect(registry.allowed?("terminal", nil)).to be true
    end

    it "checks whether a tool name is present in the allowlist" do
      registry = described_class.new
      expect(registry.allowed?("terminal", ["terminal"])).to be true
      expect(registry.allowed?("terminal", ["file_reader"])).to be false
    end
  end
end
