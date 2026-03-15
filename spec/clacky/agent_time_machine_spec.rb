# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "Clacky::Agent TimeMachine" do
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

  let(:working_dir) { Dir.mktmpdir("clacky_time_machine_test") }
  let(:agent) { Clacky::Agent.new(client, config, working_dir: working_dir, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id) }

  # Helper to get snapshot directory for a task
  def snapshot_dir(task_id)
    File.join(Dir.home, ".clacky", "snapshots", agent.session_id, "task-#{task_id}")
  end

  # Helper to create a file with content
  def create_file(path, content)
    full_path = File.join(working_dir, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end

  # Helper to read file content
  def read_file(path)
    full_path = File.join(working_dir, path)
    File.exist?(full_path) ? File.read(full_path) : nil
  end

  after do
    FileUtils.rm_rf(working_dir)
  end

  describe "initialization" do
    it "initializes time machine state" do
      expect(agent.instance_variable_get(:@task_parents)).to eq({})
      expect(agent.instance_variable_get(:@current_task_id)).to eq(0)
      expect(agent.instance_variable_get(:@active_task_id)).to eq(0)
    end
  end

  describe "#start_new_task" do
    it "creates first task with no parent" do
      agent.start_new_task
      expect(agent.instance_variable_get(:@current_task_id)).to eq(1)
      expect(agent.instance_variable_get(:@active_task_id)).to eq(1)
      expect(agent.instance_variable_get(:@task_parents)[1]).to eq(0)  # First task has parent 0
    end

    it "creates child task with correct parent" do
      agent.start_new_task  # Task 1
      agent.start_new_task  # Task 2
      
      task_parents = agent.instance_variable_get(:@task_parents)
      expect(task_parents[2]).to eq(1)
      expect(agent.instance_variable_get(:@current_task_id)).to eq(2)
      expect(agent.instance_variable_get(:@active_task_id)).to eq(2)
    end

    it "creates branching task correctly" do
      agent.start_new_task  # Task 1
      agent.start_new_task  # Task 2
      agent.switch_to_task(1)  # Go back to task 1
      agent.start_new_task  # Task 3 (branch from task 1)
      
      task_parents = agent.instance_variable_get(:@task_parents)
      expect(task_parents[3]).to eq(1)  # Task 3's parent is task 1
      expect(agent.instance_variable_get(:@current_task_id)).to eq(3)
    end
  end

  describe "#save_modified_files_snapshot" do
    it "saves file snapshots after modification" do
      # Create initial file
      create_file("test.txt", "initial content")
      
      # Start task and modify file
      agent.start_new_task
      File.write(File.join(working_dir, "test.txt"), "modified content")
      
      # Save snapshot
      agent.save_modified_files_snapshot([File.join(working_dir, "test.txt")])
      
      # Check snapshot exists
      snapshot_path = File.join(snapshot_dir(1), "test.txt")
      expect(File.exist?(snapshot_path)).to be true
      expect(File.read(snapshot_path)).to eq("modified content")
    end

    it "handles nested directory paths" do
      # Create nested file
      create_file("dir/subdir/nested.txt", "nested content")
      
      agent.start_new_task
      File.write(File.join(working_dir, "dir/subdir/nested.txt"), "updated nested")
      
      # Save snapshot
      agent.save_modified_files_snapshot([File.join(working_dir, "dir/subdir/nested.txt")])
      
      # Check snapshot preserves directory structure
      snapshot_path = File.join(snapshot_dir(1), "dir", "subdir", "nested.txt")
      expect(File.exist?(snapshot_path)).to be true
      expect(File.read(snapshot_path)).to eq("updated nested")
    end

    it "handles multiple files" do
      create_file("file1.txt", "content1")
      create_file("file2.txt", "content2")
      
      agent.start_new_task
      File.write(File.join(working_dir, "file1.txt"), "new1")
      File.write(File.join(working_dir, "file2.txt"), "new2")
      
      agent.save_modified_files_snapshot([
        File.join(working_dir, "file1.txt"),
        File.join(working_dir, "file2.txt")
      ])
      
      expect(File.read(File.join(snapshot_dir(1), "file1.txt"))).to eq("new1")
      expect(File.read(File.join(snapshot_dir(1), "file2.txt"))).to eq("new2")
    end
  end

  describe "#restore_to_task_state" do
    before do
      # Create initial state
      create_file("file.txt", "v0")
      
      # Task 1: Modify to v1
      agent.start_new_task
      File.write(File.join(working_dir, "file.txt"), "v1")
      agent.save_modified_files_snapshot([File.join(working_dir, "file.txt")])
      
      # Task 2: Modify to v2
      agent.start_new_task
      File.write(File.join(working_dir, "file.txt"), "v2")
      agent.save_modified_files_snapshot([File.join(working_dir, "file.txt")])
      
      # Task 3: Modify to v3
      agent.start_new_task
      File.write(File.join(working_dir, "file.txt"), "v3")
      agent.save_modified_files_snapshot([File.join(working_dir, "file.txt")])
    end

    it "restores files to target task state" do
      # Current state is v3 at task 3
      expect(read_file("file.txt")).to eq("v3")
      
      # Restore to task 1
      agent.restore_to_task_state(1)
      expect(read_file("file.txt")).to eq("v1")
    end

    it "restores through multiple tasks" do
      # Restore from task 3 to task 1
      agent.restore_to_task_state(1)
      expect(read_file("file.txt")).to eq("v1")
      
      # Forward to task 2
      agent.restore_to_task_state(2)
      expect(read_file("file.txt")).to eq("v2")
    end

    it "handles missing snapshots for some tasks" do
      # Create task 4 without modifying file.txt
      agent.start_new_task
      # No snapshot saved
      
      # Restore to task 4 should succeed (keeps current state)
      expect { agent.restore_to_task_state(4) }.not_to raise_error
    end
  end

  describe "#undo_last_task" do
    before do
      create_file("file.txt", "v0")
      agent.start_new_task  # Task 1
      File.write(File.join(working_dir, "file.txt"), "v1")
      agent.save_modified_files_snapshot([File.join(working_dir, "file.txt")])
      
      agent.start_new_task  # Task 2
      File.write(File.join(working_dir, "file.txt"), "v2")
      agent.save_modified_files_snapshot([File.join(working_dir, "file.txt")])
    end

    it "undoes to parent task" do
      result = agent.undo_last_task
      
      expect(result[:success]).to be true
      expect(agent.instance_variable_get(:@active_task_id)).to eq(1)
      expect(read_file("file.txt")).to eq("v1")
    end

    it "cannot undo from root task" do
      agent.switch_to_task(1)
      result = agent.undo_last_task
      
      expect(result[:success]).to be false
      expect(result[:message]).to include("Already at root task")
    end
  end

  describe "#switch_to_task" do
    before do
      create_file("file.txt", "v0")
      
      agent.start_new_task  # Task 1
      File.write(File.join(working_dir, "file.txt"), "v1")
      agent.save_modified_files_snapshot([File.join(working_dir, "file.txt")])
      
      agent.start_new_task  # Task 2
      File.write(File.join(working_dir, "file.txt"), "v2")
      agent.save_modified_files_snapshot([File.join(working_dir, "file.txt")])
      
      agent.start_new_task  # Task 3
      File.write(File.join(working_dir, "file.txt"), "v3")
      agent.save_modified_files_snapshot([File.join(working_dir, "file.txt")])
    end

    it "switches to target task" do
      result = agent.switch_to_task(1)
      
      expect(result[:success]).to be true
      expect(agent.instance_variable_get(:@active_task_id)).to eq(1)
      expect(read_file("file.txt")).to eq("v1")
    end

    it "can switch forward (redo)" do
      agent.switch_to_task(1)
      result = agent.switch_to_task(3)
      
      expect(result[:success]).to be true
      expect(agent.instance_variable_get(:@active_task_id)).to eq(3)
      expect(read_file("file.txt")).to eq("v3")
    end

    it "rejects invalid task ID" do
      result = agent.switch_to_task(99)
      
      expect(result[:success]).to be false
      expect(result[:message]).to include("Invalid task ID")
    end

    it "rejects switching to future task ID" do
      result = agent.switch_to_task(10)
      
      expect(result[:success]).to be false
      expect(result[:message]).to include("Invalid task ID")
    end
  end

  describe "#get_child_tasks" do
    before do
      agent.start_new_task  # Task 1
      agent.start_new_task  # Task 2 (child of 1)
      agent.switch_to_task(1)
      agent.start_new_task  # Task 3 (another child of 1, creates branch)
    end

    it "returns children of a task" do
      children = agent.get_child_tasks(1)
      expect(children).to contain_exactly(2, 3)
    end

    it "returns empty array for leaf task" do
      children = agent.get_child_tasks(2)
      expect(children).to be_empty
    end
  end

  describe "#get_task_history" do
    before do
      # Mock messages to provide summaries
      agent.instance_variable_set(:@messages, [
        { role: "user", content: "First task", task_id: 1 },
        { role: "user", content: "Second task", task_id: 2 },
        { role: "user", content: "Third task", task_id: 3 }
      ])
      
      agent.instance_variable_set(:@current_task_id, 3)
      agent.instance_variable_set(:@active_task_id, 3)
      agent.instance_variable_set(:@task_parents, { 2 => 1, 3 => 2 })
    end

    it "returns task history with metadata" do
      history = agent.get_task_history(limit: 10)
      
      expect(history.length).to eq(3)
      expect(history[0][:task_id]).to eq(1)
      expect(history[2][:task_id]).to eq(3)
      expect(history[2][:status]).to eq(:current)
    end

    it "marks future tasks correctly after undo" do
      agent.switch_to_task(1)
      history = agent.get_task_history(limit: 10)
      
      task_1 = history.find { |t| t[:task_id] == 1 }
      task_2 = history.find { |t| t[:task_id] == 2 }
      
      expect(task_1[:status]).to eq(:current)
      expect(task_2[:status]).to eq(:future)
    end

    it "detects branches" do
      # Create a branch
      agent.start_new_task  # Task 4 (child of 3)
      agent.switch_to_task(2)
      agent.start_new_task  # Task 5 (creates branch at task 2)
      
      history = agent.get_task_history(limit: 10)
      task_2 = history.find { |t| t[:task_id] == 2 }
      
      expect(task_2[:has_branches]).to be true
    end

    it "respects limit parameter" do
      10.times { agent.start_new_task }
      history = agent.get_task_history(limit: 5)
      
      expect(history.length).to eq(5)
    end
  end

  describe "#active_messages" do
    before do
      agent.instance_variable_set(:@messages, [
        { role: "user", content: "Task 1", task_id: 1 },
        { role: "assistant", content: "Response 1", task_id: 1 },
        { role: "user", content: "Task 2", task_id: 2 },
        { role: "assistant", content: "Response 2", task_id: 2 },
        { role: "user", content: "Task 3", task_id: 3 },
        { role: "assistant", content: "Response 3", task_id: 3 }
      ])
      
      agent.instance_variable_set(:@current_task_id, 3)
      agent.instance_variable_set(:@active_task_id, 3)
    end

    it "returns all messages when at current task" do
      messages = agent.active_messages
      expect(messages.length).to eq(6)
    end

    it "filters messages after undo" do
      agent.instance_variable_set(:@active_task_id, 1)
      messages = agent.active_messages
      
      expect(messages.length).to eq(2)
      expect(messages.last[:task_id]).to eq(1)
    end

    it "includes system messages without task_id" do
      agent.instance_variable_get(:@messages).unshift({ role: "system", content: "You are an AI" })
      agent.instance_variable_set(:@active_task_id, 1)
      
      messages = agent.active_messages
      expect(messages.first[:role]).to eq("system")
      expect(messages.length).to eq(3)  # system + 2 messages from task 1
    end
  end

  describe "integration with session serialization" do
    it "saves time machine state to session" do
      agent.start_new_task
      agent.start_new_task
      
      session_data = agent.to_session_data(status: :success)
      
      expect(session_data[:time_machine]).to be_a(Hash)
      expect(session_data[:time_machine][:task_parents]).to be_a(Hash)
      expect(session_data[:time_machine][:current_task_id]).to eq(2)
      expect(session_data[:time_machine][:active_task_id]).to eq(2)
    end

    it "restores time machine state from session" do
      agent.start_new_task
      agent.start_new_task
      session_data = agent.to_session_data(status: :success)
      
      # Create new agent and restore
      new_agent = Clacky::Agent.new(client, config, working_dir: working_dir, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id)
      new_agent.restore_session(session_data)
      
      expect(new_agent.instance_variable_get(:@current_task_id)).to eq(2)
      expect(new_agent.instance_variable_get(:@active_task_id)).to eq(2)
      expect(new_agent.instance_variable_get(:@task_parents)).to eq(agent.instance_variable_get(:@task_parents))
    end
  end

  describe "file tracking" do
    it "tracks modified files during task execution" do
      # This would be tested in integration with actual tool execution
      # For now, we just verify the tracking mechanism exists
      expect(agent).to respond_to(:track_modified_files)
    end
  end

  describe "branching scenarios" do
    it "handles linear history" do
      agent.start_new_task  # 1
      agent.start_new_task  # 2
      agent.start_new_task  # 3
      
      expect(agent.get_child_tasks(1)).to eq([2])
      expect(agent.get_child_tasks(2)).to eq([3])
      expect(agent.get_child_tasks(3)).to be_empty
    end

    it "handles simple branch" do
      agent.start_new_task  # 1
      agent.start_new_task  # 2
      agent.switch_to_task(1)
      agent.start_new_task  # 3
      
      expect(agent.get_child_tasks(1)).to contain_exactly(2, 3)
    end

    it "handles complex branching tree" do
      agent.start_new_task  # 1
      agent.start_new_task  # 2
      agent.start_new_task  # 3
      agent.switch_to_task(2)
      agent.start_new_task  # 4
      agent.switch_to_task(1)
      agent.start_new_task  # 5
      
      expect(agent.get_child_tasks(1)).to contain_exactly(2, 5)
      expect(agent.get_child_tasks(2)).to contain_exactly(3, 4)
    end
  end
end
