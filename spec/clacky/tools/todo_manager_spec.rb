# frozen_string_literal: true

RSpec.describe Clacky::Tools::TodoManager do
  let(:tool) { described_class.new }

  describe "#execute" do
    describe "add action" do
      it "adds a new todo" do
        storage = []
        result = tool.execute(action: "add", task: "Write tests", todos_storage: storage)

        expect(result[:message]).to eq("TODO added successfully")
        expect(result[:todos].size).to eq(1)
        expect(result[:todos][0][:id]).to eq(1)
        expect(result[:todos][0][:task]).to eq("Write tests")
        expect(result[:todos][0][:status]).to eq("pending")
        expect(storage.size).to eq(1)
      end

      it "adds multiple todos at once with tasks array" do
        storage = []
        result = tool.execute(
          action: "add",
          tasks: ["Task 1", "Task 2", "Task 3"],
          todos_storage: storage
        )

        expect(result[:message]).to eq("3 TODOs added successfully")
        expect(result[:todos].size).to eq(3)
        expect(result[:todos][0][:id]).to eq(1)
        expect(result[:todos][1][:id]).to eq(2)
        expect(result[:todos][2][:id]).to eq(3)
        expect(storage.size).to eq(3)
      end

      it "increments todo IDs correctly when adding multiple" do
        storage = []
        tool.execute(action: "add", task: "First task", todos_storage: storage)
        result = tool.execute(
          action: "add",
          tasks: ["Second task", "Third task"],
          todos_storage: storage
        )

        expect(result[:todos][0][:id]).to eq(2)
        expect(result[:todos][1][:id]).to eq(3)
        expect(storage.size).to eq(3)
      end

      it "prefers tasks array over task when both provided" do
        storage = []
        result = tool.execute(
          action: "add",
          task: "Single task",
          tasks: ["Batch 1", "Batch 2"],
          todos_storage: storage
        )

        expect(result[:todos].size).to eq(2)
        expect(result[:todos][0][:task]).to eq("Batch 1")
      end

      it "returns error when task is empty" do
        storage = []
        result = tool.execute(action: "add", task: "", todos_storage: storage)

        expect(result[:error]).to eq("At least one task description is required")
      end

      it "returns error when task is nil and tasks is empty" do
        storage = []
        result = tool.execute(action: "add", todos_storage: storage)

        expect(result[:error]).to eq("At least one task description is required")
      end

      it "filters out empty tasks from array" do
        storage = []
        result = tool.execute(
          action: "add",
          tasks: ["Task 1", "", "  ", "Task 2"],
          todos_storage: storage
        )

        expect(result[:todos].size).to eq(2)
        expect(result[:todos][0][:task]).to eq("Task 1")
        expect(result[:todos][1][:task]).to eq("Task 2")
      end
    end

    describe "list action" do
      it "returns empty list when no todos" do
        storage = []
        result = tool.execute(action: "list", todos_storage: storage)

        expect(result[:message]).to eq("No TODO items")
        expect(result[:todos]).to eq([])
        expect(result[:total]).to eq(0)
      end

      it "lists all todos" do
        storage = []
        tool.execute(action: "add", task: "Task 1", todos_storage: storage)
        tool.execute(action: "add", task: "Task 2", todos_storage: storage)

        result = tool.execute(action: "list", todos_storage: storage)

        expect(result[:message]).to eq("TODO list")
        expect(result[:todos].size).to eq(2)
        expect(result[:total]).to eq(2)
        expect(result[:pending]).to eq(2)
        expect(result[:completed]).to eq(0)
      end

      it "shows pending and completed counts" do
        storage = []
        tool.execute(action: "add", task: "Task 1", todos_storage: storage)
        tool.execute(action: "add", task: "Task 2", todos_storage: storage)
        tool.execute(action: "complete", id: 1, todos_storage: storage)

        result = tool.execute(action: "list", todos_storage: storage)

        expect(result[:pending]).to eq(1)
        expect(result[:completed]).to eq(1)
      end
    end

    describe "complete action" do
      it "marks a todo as completed" do
        storage = []
        tool.execute(action: "add", task: "Task to complete", todos_storage: storage)
        result = tool.execute(action: "complete", id: 1, todos_storage: storage)

        expect(result[:message]).to eq("Task marked as completed")
        expect(result[:todo][:status]).to eq("completed")
        expect(result[:todo][:completed_at]).not_to be_nil
      end

      it "returns message if already completed" do
        storage = []
        tool.execute(action: "add", task: "Task", todos_storage: storage)
        tool.execute(action: "complete", id: 1, todos_storage: storage)
        result = tool.execute(action: "complete", id: 1, todos_storage: storage)

        expect(result[:message]).to eq("Task already completed")
      end

      it "returns error when task not found" do
        storage = []
        result = tool.execute(action: "complete", id: 999, todos_storage: storage)

        expect(result[:error]).to eq("Task not found: 999")
      end

      it "returns error when id is nil" do
        storage = []
        result = tool.execute(action: "complete", todos_storage: storage)

        expect(result[:error]).to eq("Task ID is required")
      end
    end

    describe "remove action" do
      it "removes a todo" do
        storage = []
        tool.execute(action: "add", task: "Task to remove", todos_storage: storage)
        result = tool.execute(action: "remove", id: 1, todos_storage: storage)

        expect(result[:message]).to eq("Task removed")
        expect(result[:remaining]).to eq(0)
      end

      it "returns error when task not found" do
        storage = []
        result = tool.execute(action: "remove", id: 999, todos_storage: storage)

        expect(result[:error]).to eq("Task not found: 999")
      end

      it "returns error when id is nil" do
        storage = []
        result = tool.execute(action: "remove", todos_storage: storage)

        expect(result[:error]).to eq("Task ID is required")
      end

      it "removes multiple todos at once with ids array" do
        storage = []
        tool.execute(action: "add", tasks: ["Task 1", "Task 2", "Task 3", "Task 4"], todos_storage: storage)
        result = tool.execute(action: "remove", ids: [1, 3], todos_storage: storage)

        expect(result[:message]).to eq("2 task(s) removed")
        expect(result[:removed].size).to eq(2)
        expect(result[:removed][0][:id]).to eq(1)
        expect(result[:removed][1][:id]).to eq(3)
        expect(result[:remaining]).to eq(2)
        expect(storage.size).to eq(2)
        expect(storage.map { |t| t[:id] }).to eq([2, 4])
      end

      it "handles batch remove with some non-existent IDs" do
        storage = []
        tool.execute(action: "add", tasks: ["Task 1", "Task 2"], todos_storage: storage)
        result = tool.execute(action: "remove", ids: [1, 999, 2, 888], todos_storage: storage)

        expect(result[:message]).to eq("2 task(s) removed")
        expect(result[:removed].size).to eq(2)
        expect(result[:not_found]).to eq([999, 888])
        expect(result[:remaining]).to eq(0)
      end

      it "returns error when ids array is empty" do
        storage = []
        result = tool.execute(action: "remove", ids: [], todos_storage: storage)

        expect(result[:error]).to eq("Task IDs array is required")
      end

      it "prefers ids array over id when both provided" do
        storage = []
        tool.execute(action: "add", tasks: ["Task 1", "Task 2", "Task 3"], todos_storage: storage)
        result = tool.execute(action: "remove", id: 1, ids: [2, 3], todos_storage: storage)

        expect(result[:message]).to eq("2 task(s) removed")
        expect(result[:removed].size).to eq(2)
        expect(result[:removed].map { |t| t[:id] }).to eq([2, 3])
        expect(storage.size).to eq(1)
        expect(storage[0][:id]).to eq(1)
      end
    end

    describe "clear action" do
      it "clears all todos" do
        storage = []
        tool.execute(action: "add", task: "Task 1", todos_storage: storage)
        tool.execute(action: "add", task: "Task 2", todos_storage: storage)

        result = tool.execute(action: "clear", todos_storage: storage)

        expect(result[:message]).to eq("All TODOs cleared")
        expect(result[:cleared_count]).to eq(2)
        expect(storage).to be_empty
      end

      it "clears empty list" do
        storage = []
        result = tool.execute(action: "clear", todos_storage: storage)

        expect(result[:message]).to eq("All TODOs cleared")
        expect(result[:cleared_count]).to eq(0)
      end
    end

    describe "unknown action" do
      it "returns error for unknown action" do
        storage = []
        result = tool.execute(action: "invalid_action", todos_storage: storage)

        expect(result[:error]).to eq("Unknown action: invalid_action")
      end
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("todo_manager")
      expect(definition[:function][:parameters][:type]).to eq("object")
    end

    it "includes all action types in enum" do
      definition = tool.to_function_definition
      actions = definition[:function][:parameters][:properties][:action][:enum]

      expect(actions).to include("add", "list", "complete", "remove", "clear")
    end
  end
end
