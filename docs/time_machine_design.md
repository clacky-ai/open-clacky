# Time Machine Design

## Overview

Time Machine allows users to undo/redo tasks in the Agent, restoring both file modifications and conversation messages.

**Core Strategy: Reuse trash_manager infrastructure** - extend it to support task-based organization instead of creating new backup systems.

## Core Concepts

### Task Definition

A **Task** = one complete execution of `run_autonomous_loop`:
- User input
- Multiple React cycles (think-act-observe)  
- All file modifications during execution
- All messages generated during execution

### Key Design Decision: Extend trash_manager

Instead of creating a new backup system, we **extend the existing trash_manager**:

**Current trash_manager behavior:**
```
~/.clacky/trash/{project_hash}/
  {timestamp}_{filename}
  {timestamp}_{filename}.metadata.json
```

**Extended behavior for time machine:**
```
~/.clacky/trash/{project_hash}/
  task-{task_id}_{timestamp}_{filename}
  task-{task_id}_{timestamp}_{filename}.metadata.json
```

**Benefits:**
- ✅ Reuse existing directory structure
- ✅ Reuse existing metadata format
- ✅ Reuse list/restore/empty logic
- ✅ No duplicate code
- ✅ Unified trash management

## Design Principles

### 1. Task ID Based Message Management

Each message tagged with `task_id`:

```ruby
@messages = [
  { role: 'user', content: '...', task_id: 1 },
  { role: 'assistant', content: [...], task_id: 1 },
  { role: 'user', content: [...], task_id: 1 },
  ...
]

@current_task_id = 3  # Currently executing task
@active_task_id = 3   # Active up to this task (changes on undo/redo)
```

### 2. File Backup via Extended trash_manager

**Before write/edit operations:**
```ruby
# Agent hooks into write/edit tools
def before_file_modify(path)
  if File.exist?(path)
    # Backup to trash with task prefix
    trash_manager.backup_for_task(
      path: path,
      task_id: @current_task_id,
      operation: 'write' # or 'edit'
    )
  end
end
```

**trash_manager creates:**
```
task-5_20240214120530_app.rb
task-5_20240214120530_app.rb.metadata.json
```

**Metadata includes:**
```json
{
  "original_path": "/path/to/app.rb",
  "deleted_at": "2024-02-14T12:05:30+08:00",
  "task_id": 5,
  "operation": "write",
  "file_size": 1234,
  "file_type": "rb"
}
```

### 3. Minimal Session Storage

Session file only stores lightweight indexes:

```ruby
session_data = {
  messages: [...],  # with task_id in each message
  current_task_id: 5,
  active_task_id: 3,  # Currently at task 3 (undone from 5)
  # No file content! All in trash directory
}
```

## Implementation Plan

### Phase 1: Extend trash_manager

**Add to `TrashDirectory` class:**
```ruby
# Backup file for a specific task
def backup_for_task(path:, task_id:, operation:)
  # Generate: task-{id}_{timestamp}_{filename}
end

# List files for a specific task
def list_task_files(task_id)
  # Find all task-{id}_* files
end

# Restore all files for a task
def restore_task(task_id)
  # Restore all task-{id}_* files
end
```

**Add to `TrashManager` tool:**
```ruby
# New actions
when 'list_task'
  list_task_files(task_id)
when 'restore_task'  
  restore_task(task_id)
```

### Phase 2: Integrate into Agent

**Hook file operations:**
```ruby
module ToolExecutor
  def execute_tool(tool, params)
    # Before file modification
    if ['write', 'edit'].include?(tool.tool_name)
      backup_file_for_current_task(params[:path])
    end
    
    # Execute tool
    result = tool.execute(**params)
    
    result
  end
end

private def backup_file_for_current_task(path)
  return unless File.exist?(path)
  
  trash_dir = TrashDirectory.new(Dir.pwd)
  trash_dir.backup_for_task(
    path: path,
    task_id: @current_task_id,
    operation: current_tool_name
  )
end
```

**Add task_id to messages:**
```ruby
def observe(tool_result)
  @messages << {
    role: 'user',
    content: [tool_result],
    task_id: @current_task_id
  }
end
```

**Implement undo/redo:**
```ruby
def undo_last_task
  return false if @active_task_id == 0
  
  # Restore files from trash
  trash_dir = TrashDirectory.new(Dir.pwd)
  trash_dir.restore_task(@active_task_id)
  
  # Roll back messages
  @active_task_id -= 1
  
  true
end

def redo_last_task
  return false if @active_task_id >= @current_task_id
  
  @active_task_id += 1
  
  # Re-apply changes by restoring from trash "after" state
  # (Need to store both before/after states)
  
  true
end
```

### Phase 3: New Tools

**Create `UndoTask` tool:**
```ruby
class UndoTask < Base
  self.tool_name = "undo_task"
  self.tool_description = "Undo the last task, restoring files and rolling back conversation"
  
  def execute
    agent.undo_last_task
  end
end
```

**Create `RedoTask` tool:**
```ruby
class RedoTask < Base
  self.tool_name = "redo_task"
  self.tool_description = "Redo a previously undone task"
  
  def execute
    agent.redo_last_task
  end
end
```

**Create `ListTasks` tool:**
```ruby
class ListTasks < Base
  self.tool_name = "list_tasks"
  self.tool_description = "List all tasks with their file modifications"
  
  def execute
    # Show task history with undo/redo positions
  end
end
```

## Workflow Example

```
Task 1: Create app.rb
→ No backup (file doesn't exist)
→ Create app.rb
→ Messages: [M1, M2, M3] with task_id: 1

Task 2: Edit app.rb
→ Backup: task-2_timestamp_app.rb (original content)
→ Modify app.rb
→ Messages: [..., M4, M5, M6] with task_id: 2

[User: "undo"]
→ undo_last_task()
→ trash_manager.restore_task(2)  # Restore app.rb from backup
→ @active_task_id = 1
→ Active messages: [M1, M2, M3]  # M4-M6 hidden

[User: "redo"]
→ redo_last_task()
→ Need to re-apply task 2 changes
→ @active_task_id = 2
→ Active messages: [M1, M2, M3, M4, M5, M6]
```

## Technical Challenges

### Challenge 1: Redo Implementation

**Problem:** After undo, how to redo?

**Solution:** Store both before AND after states:
```
task-2_timestamp_app.rb.before
task-2_timestamp_app.rb.after
```

Or simpler: Store operation parameters in metadata
```json
{
  "operation": "edit",
  "tool_params": {
    "old_string": "...",
    "new_string": "...",
    "replace_all": false
  }
}
```

For redo: Re-execute the tool with saved params.

### Challenge 2: Clean up old backups

Extend trash_manager's `empty` action:
```ruby
# Delete task backups older than N days
trash_manager(action: "empty", days_old: 7)
```

## Implementation Checklist

- [ ] Extend `TrashDirectory` class with task methods
- [ ] Extend `TrashManager` tool with task actions  
- [ ] Add `@current_task_id` and `@active_task_id` to Agent
- [ ] Add task_id field to message structure
- [ ] Hook write/edit tools to backup files
- [ ] Implement `undo_last_task` method
- [ ] Implement `redo_last_task` method
- [ ] Create `UndoTask` tool
- [ ] Create `RedoTask` tool
- [ ] Create `ListTasks` tool
- [ ] Update SessionSerializer to save task IDs
- [ ] Write tests
- [ ] Update .clackyrules with time machine usage

## Future Enhancements

- **Selective undo**: Undo specific task by ID (not just last)
- **Diff view**: Show what changed in each task
- **Compression**: Compress old task backups
- **Branch history**: Support multiple undo/redo branches
