# UI2 Architecture

## Core Principle
**Strict Layering**: UI layer must NOT directly access Agent layer. Use callbacks for communication.

## Component Hierarchy
```
UIController (single external interface)
  ├── LayoutManager (layout coordination)
  │   ├── OutputArea (output display)
  │   ├── InputArea (user input)
  │   ├── TodoArea (task list)
  │   └── InlineInput (confirmation prompt)
  └── Callbacks (external communication)
      ├── on_input -> CLI handles input
      ├── on_interrupt -> CLI handles interruption
      └── on_mode_toggle -> CLI handles mode change
```

## Data Flow

### Agent → UI: One-way calls
```ruby
# Agent calls UI to display
@ui&.show_tool_call(...)
@ui&.append_output(...)
@ui&.show_token_usage(...)
```

### UI → Agent: Via callbacks
```ruby
# ❌ Wrong: UI directly calls Agent
agent.run(input)

# ✅ Correct: Via callback
ui_controller.on_input { |input| agent.run(input) }
```

## Common Mistakes

### ❌ Directly accessing Agent in UI components
```ruby
# Bad example
def toggle_mode
  @agent.config.mode = "auto_approve"  # ❌ Violates separation
end
```

### ✅ Notify via callback
```ruby
# Good example
def toggle_mode
  @mode_toggle_callback&.call("auto_approve")  # ✅ Proper separation
end
```

### ❌ Using puts for logging
```ruby
puts "Debug info"  # ❌ Breaks UI rendering
```

### ✅ Use UIController.log
```ruby
ui_controller.log("Debug info")  # ✅ Displays in output area
ui_controller.log("Warning", level: :warning)
ui_controller.log("Error", level: :error)
```

## Logging System

Use `ui_controller.log(message, level: :info)` to display debug information in the output area without breaking rendering.

**Available log levels:**
- `:debug` - Gray dimmed text
- `:info` - Normal text with info symbol
- `:warning` - Yellow warning text
- `:error` - Red error text

**Example:**
```ruby
# In UIController or components with access to UIController
@ui_controller.log("Tool execution started", level: :debug)
@ui_controller.log("Cache hit", level: :info)
@ui_controller.log("Retry attempt 3/10", level: :warning)
@ui_controller.log("Network failed", level: :error)
```

## Rendering Flow

### Fixed Areas
- **InputArea**: Fixed at bottom (hidden when InlineInput is active via `paused?`)
- **TodoArea**: Fixed above InputArea

### Scrolling Area
- **OutputArea**: Natural scrolling, all content appended here

### Thread Safety
- All rendering protected by `@render_mutex`
- Never call render methods outside LayoutManager

## Key Methods

### Display Methods (Agent → UI)
- `append_output(content)` - Add content to output area
- `update_sessionbar(tasks:, cost:)` - Update session bar
- `show_token_usage(token_data)` - Display token statistics
- `show_tool_call(name, args)` - Display tool execution
- `request_confirmation(message)` - Blocking user confirmation

### Callback Registration (CLI sets these)
- `on_input { |text, images| ... }` - Handle user input
- `on_interrupt { |input_was_empty:| ... }` - Handle Ctrl+C
- `on_mode_toggle { |new_mode| ... }` - Handle Shift+Tab

### Logging (Use instead of puts)
- `log(message, level: :info)` - Display debug/info in output

## Best Practices

1. **Never bypass UIController** - All UI updates go through UIController
2. **Use callbacks for upward communication** - UI notifies CLI/Agent via callbacks
3. **Log via UIController** - Never use `puts` or `print` directly
4. **Check paused state** - Don't render InputArea when InlineInput is active
5. **Trust the render flow** - Let LayoutManager handle rendering coordination
