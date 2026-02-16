# Time Machine Design Documentation

## Overview

Time Machine is a feature that allows users to navigate through the agent's task execution history, providing undo/redo capabilities and branch exploration. Users can access it via ESC key or `/undo` command to view an interactive menu of past tasks.

## Core Data Structure Design

### Task History Graph

The Time Machine uses a minimal tree-based data structure to track task relationships:

**Three Core State Variables:**
1. **task_parents** (Hash): Maps each task_id to its parent_id
   - Forms a tree structure where each task points to its predecessor
   - Root tasks have parent_id = 0
   - Enables traversal in both directions (parent→children, child→parent)

2. **current_task_id** (Integer): The latest created task ID
   - Always increments when new tasks are created
   - Never decreases, even during undo operations
   - Represents the "tip" of the execution timeline

3. **active_task_id** (Integer): The current active position in history
   - Can move backward/forward during undo/redo
   - Determines which messages are visible to the LLM
   - When active_task_id < current_task_id, we're viewing "past" state

### Task Metadata Structure

Each task in the history contains:
- **task_id**: Unique identifier (auto-incrementing integer)
- **summary**: Brief description (first 80 chars of user's message)
- **status**: One of three states
  - `:past` - Task is before the current active position
  - `:current` - Task is the active position (marked with `→`)
  - `:future` - Task exists but is after active position (marked with `↯`)
- **has_branches**: Boolean indicating if multiple children exist (marked with `⎇`)

## Snapshot Strategy

### File State Preservation

**Complete AFTER-State Snapshots:**
- After each successful task execution, all modified files are saved
- Storage location: `~/.clacky/snapshots/{session_id}/task-{id}/`
- Each file is stored with its full relative path from working directory
- Only files modified during that task are snapshotted

**Why AFTER-state instead of BEFORE-state:**
- Simpler restoration logic (just copy files back)
- No need to track "what changed" - the snapshot IS the state
- Easier to verify correctness (snapshot = expected state)

**File Restoration Process:**
- When switching to a task, iterate through all its snapshotted files
- Copy each file from snapshot directory to working directory
- File permissions and timestamps are preserved

### Message Filtering

**Active Messages Concept:**
- Messages array contains ALL messages (past, current, future)
- `active_messages()` method filters out "future" messages
- LLM only sees messages with `task_id <= active_task_id`
- This creates the illusion of time travel without data deletion

**Why Keep All Messages:**
- Enables redo operations (future messages preserved)
- Allows branch switching (alternative futures available)
- Simplifies session serialization (single source of truth)

## Session Persistence

### State Serialization

Time Machine state is saved under `:time_machine` key in session data:
- task_parents hash (complete tree structure)
- current_task_id (latest task number)
- active_task_id (current viewing position)

**Restoration Guarantees:**
- Complete task tree is rebuilt
- Active position is restored
- Snapshot files remain available across sessions
- User can continue undo/redo from where they left off

## Critical Test Scenarios

### 1. Basic Undo/Redo Flow

**Test Focus:**
- Sequential task creation increments task IDs correctly
- Undo moves active_task_id backward (current_task_id unchanged)
- Redo moves active_task_id forward
- File snapshots are correctly restored at each step
- Cannot undo beyond root task (task_id = 0)
- Cannot redo beyond current_task_id

**Edge Cases:**
- Undoing at root task should fail gracefully
- Redoing when already at tip should fail gracefully
- Multiple consecutive undos should work correctly

### 2. Branching Scenarios

**Test Focus:**
- After undo, creating new task creates a branch
- New branch starts from active_task_id, not current_task_id
- Original future branch is preserved (for potential redo)
- Parent task is marked with `has_branches: true`
- Child tasks list should include both branches

**Branch Navigation:**
- Switching between branches restores correct file states
- Each branch maintains independent history
- Message filtering correctly shows only relevant messages

### 3. Message Filtering and Task IDs

**Test Focus:**
- Every message is tagged with task_id (user, assistant, tool results)
- Active messages only include those with task_id <= active_task_id
- LLM never sees "future" messages during undo state
- After redo, future messages become visible again
- New tasks created after undo get fresh task IDs (not reused)

**Message Consistency:**
- Tool results are associated with correct task
- Multi-turn conversations maintain task association
- Error messages don't break task ID tagging

### 4. File Snapshot Integrity

**Test Focus:**
- Only modified files are snapshotted (not entire project)
- File content is exactly preserved (byte-for-byte)
- Nested directory structures are correctly recreated
- Multiple files in single task are all snapshotted
- Snapshot directory naming prevents collisions

**Restoration Accuracy:**
- After undo + file restore, file content matches expected state
- Subsequent task execution works with restored files
- Binary files are handled correctly (not corrupted)

### 5. Session Persistence and Recovery

**Test Focus:**
- Save session, restart, restore session preserves Time Machine state
- Task tree structure is fully rebuilt
- Active position is correctly restored
- Snapshot files are accessible after restart
- Undo/redo operations work identically after restore

**Persistence Edge Cases:**
- Empty task history (new session)
- Session with complex branching
- Session saved while in "undo" state (active_task_id < current_task_id)

### 6. AI Tool Integration

**Test Focus:**
- Tools are correctly registered in tool registry
- AI can invoke undo_task, redo_task, list_tasks
- Agent parameter is correctly injected (similar to TodoManager pattern)
- Tool execution returns success/failure messages
- Tools respect permission modes (confirm_all, auto_approve, etc.)

**Tool Interaction:**
- AI calling undo_task modifies agent state correctly
- Subsequent AI responses use filtered messages
- Tool results are included in task history
- Multiple tool calls in sequence work correctly

### 7. UI and User Interaction

**Test Focus:**
- ESC key triggers time machine menu
- `/undo` command works identically to ESC
- Menu displays correct task list with status indicators
- Visual markers: `→` current, `↯` future, `⎇` branches
- User selection triggers correct task switch
- Menu updates after undo/redo operations

**User Experience:**
- Task summaries are readable (truncated to 80 chars)
- Menu is responsive with large task histories
- Cancel/exit returns to normal operation
- Error messages are clear and actionable

### 8. Integration with Existing Features

**Test Focus:**
- Works with message compression (no dependency on tool_calls)
- Compatible with session serialization
- Doesn't interfere with cost tracking
- Works with both UI modes (UI1 and UI2)
- Subagent forking doesn't inherit Time Machine state

**Feature Compatibility:**
- Todo manager works normally during undo state
- Web search tools work correctly
- File tools (write, edit) trigger snapshots
- Shell commands can be undone via file snapshots

## Design Principles

### Minimal Invasiveness
- Only 3 new instance variables in Agent class
- No changes to core message structure (only adds task_id field)
- Existing tools unaware of Time Machine existence
- No performance impact when not in use

### Data Integrity
- Never delete messages or snapshots (immutable history)
- File restoration is idempotent (can redo multiple times)
- Task IDs never reused (prevents confusion)
- Snapshot isolation (each task has independent directory)

### User Control
- Explicit user action required (ESC or /undo)
- Clear visual feedback on current position
- Cannot accidentally lose work (future preserved)
- Can explore branches without commitment

### Developer Friendly
- Simple tree data structure (easy to reason about)
- Comprehensive test coverage (55 test cases)
- Clear separation of concerns (module-based design)
- Well-documented edge cases

## Future Enhancement Possibilities

### Potential Improvements
- Automatic snapshot garbage collection (old sessions)
- Diff view between task states
- Named checkpoints (user-defined bookmarks)
- Merge branches functionality
- Export task history as replay script
- Snapshot compression for large files

### Scalability Considerations
- Large file handling (incremental snapshots)
- Long session histories (pagination in UI)
- Multiple simultaneous branches (better visualization)
- Remote collaboration (shared task history)
