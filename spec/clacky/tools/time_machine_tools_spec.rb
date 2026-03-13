# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Time Machine Tools" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end

  let(:config) do
    Clacky::AgentConfig.new(
      model: "gpt-3.5-turbo",
      permission_mode: :auto_approve
    )
  end

  let(:agent) { Clacky::Agent.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id) }

  describe Clacky::Tools::UndoTask do
    let(:tool) { described_class.new }

    it "has correct tool metadata" do
      expect(tool.name).to eq("undo_task")
      expect(tool.category).to eq("time_machine")
    end

    it "undoes to parent task successfully" do
      # Setup: Create tasks
      agent.start_new_task  # Task 1
      agent.start_new_task  # Task 2
      
      # Execute undo (agent is injected via keyword arg like in the real agent)
      result = tool.execute(agent: agent)
      
      expect(result).to include("Undone to task 1")
      expect(agent.instance_variable_get(:@active_task_id)).to eq(1)
    end

    it "fails when at root task" do
      agent.start_new_task  # Task 1
      
      result = tool.execute(agent: agent)
      
      expect(result).to include("Error:")
      expect(result).to include("Already at root task")
    end

    it "formats call correctly" do
      formatted = tool.format_call
      expect(formatted).to include("Undoing")
    end

    it "formats result correctly" do
      result = "⏪ Undone to task 5"
      formatted = tool.format_result(result)
      
      expect(formatted).to eq(result)
    end
  end

  describe Clacky::Tools::RedoTask do
    let(:tool) { described_class.new }

    it "has correct tool metadata" do
      expect(tool.name).to eq("redo_task")
      expect(tool.category).to eq("time_machine")
    end

    it "redoes to specified task successfully" do
      # Setup: Create tasks and undo
      agent.start_new_task  # Task 1
      agent.start_new_task  # Task 2
      agent.start_new_task  # Task 3
      agent.switch_to_task(1)  # Undo to task 1
      
      # Execute redo to task 3
      result = tool.execute(task_id: 3, agent: agent)
      
      expect(result).to include("Switched to task 3")
      expect(agent.instance_variable_get(:@active_task_id)).to eq(3)
    end

    it "fails with invalid task ID" do
      agent.start_new_task  # Task 1
      
      result = tool.execute(task_id: 99, agent: agent)
      
      expect(result).to include("Error:")
      expect(result).to include("Invalid")
    end

    it "requires task_id parameter" do
      expect {
        tool.execute(agent: agent)
      }.to raise_error(ArgumentError)
    end

    it "formats call correctly" do
      formatted = tool.format_call(task_id: 5)
      expect(formatted).to include("Redoing")
      expect(formatted).to include("5")
    end

    it "formats result correctly" do
      result = "⏩ Switched to task 7"
      formatted = tool.format_result(result)
      
      expect(formatted).to eq(result)
    end
  end

  describe Clacky::Tools::ListTasks do
    let(:tool) { described_class.new }

    before do
      # Mock messages for task summaries
      agent.instance_variable_set(:@messages, [
        { role: "user", content: "First task", task_id: 1 },
        { role: "user", content: "Second task", task_id: 2 },
        { role: "user", content: "Third task", task_id: 3 }
      ])
      
      agent.instance_variable_set(:@current_task_id, 3)
      agent.instance_variable_set(:@active_task_id, 3)
      agent.instance_variable_set(:@task_parents, { 2 => 1, 3 => 2 })
    end

    it "has correct tool metadata" do
      expect(tool.name).to eq("list_tasks")
      expect(tool.category).to eq("time_machine")
    end

    it "lists task history" do
      result = tool.execute(agent: agent)
      
      expect(result).to include("Task History")
      expect(result).to include("Task 1")
      expect(result).to include("Task 2")
      expect(result).to include("Task 3")
      expect(result).to include("→")  # Current task indicator
    end

    it "respects limit parameter" do
      # Add more tasks
      10.times do
        agent.start_new_task
      end
      
      result = tool.execute(limit: 5, agent: agent)
      
      # Count lines (each task is one line, plus header "Task History:")
      lines = result.split("\n")
      expect(lines.length).to be <= 6  # Header + 5 tasks
    end

    it "uses default limit if not specified" do
      result = tool.execute(agent: agent)
      lines = result.split("\n")
      expect(lines.length).to be <= 11  # Header + 10 tasks
    end

    it "formats call correctly" do
      formatted = tool.format_call(limit: 5)
      expect(formatted).to include("Listing")
      expect(formatted).to include("5")
    end

    it "formats result correctly" do
      result = tool.execute(agent: agent)
      formatted = tool.format_result(result)
      
      expect(formatted).to include("Task History")
      expect(formatted).to include("→")  # Current task indicator
    end

    it "shows branch indicators" do
      # Create a branch
      agent.switch_to_task(2)
      agent.start_new_task  # Creates branch at task 2
      
      result = tool.execute(agent: agent)
      
      expect(result).to include("⎇")  # Branch indicator for task 2
    end
  end

  describe "Tool Registration" do
    it "registers undo_task tool" do
      registry = agent.instance_variable_get(:@tool_registry)
      expect(registry.tool_names).to include("undo_task")
    end

    it "registers redo_task tool" do
      registry = agent.instance_variable_get(:@tool_registry)
      expect(registry.tool_names).to include("redo_task")
    end

    it "registers list_tasks tool" do
      registry = agent.instance_variable_get(:@tool_registry)
      expect(registry.tool_names).to include("list_tasks")
    end
  end

  describe "Tool Integration with Agent" do
    it "allows AI to undo via tool" do
      agent.start_new_task
      agent.start_new_task
      
      # Simulate AI calling undo_task tool
      tool = Clacky::Tools::UndoTask.new
      result = tool.execute(agent: agent)
      
      expect(result).to include("Undone to task 1")
      expect(agent.instance_variable_get(:@active_task_id)).to eq(1)
    end

    it "allows AI to redo via tool" do
      agent.start_new_task  # 1
      agent.start_new_task  # 2
      agent.start_new_task  # 3
      agent.switch_to_task(1)
      
      # Simulate AI calling redo_task tool
      tool = Clacky::Tools::RedoTask.new
      result = tool.execute(task_id: 3, agent: agent)
      
      expect(result).to include("Switched to task 3")
      expect(agent.instance_variable_get(:@active_task_id)).to eq(3)
    end

    it "allows AI to list tasks via tool" do
      agent.instance_variable_set(:@messages, [
        { role: "user", content: "Test", task_id: 1 }
      ])
      agent.instance_variable_set(:@current_task_id, 1)
      agent.instance_variable_set(:@active_task_id, 1)
      
      # Simulate AI calling list_tasks tool
      tool = Clacky::Tools::ListTasks.new
      result = tool.execute(agent: agent)
      
      expect(result).to be_a(String)
      expect(result).to include("Task History")
    end
  end
end
