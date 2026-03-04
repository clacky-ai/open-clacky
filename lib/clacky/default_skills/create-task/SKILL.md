---
name: create-task
description: Create a scheduled automated task. User describes what they want to automate, agent creates the task prompt file and optional cron schedule.
disable-model-invocation: false
user-invocable: true
---

# Create Task Skill

## When to Use
Invoke this skill when a user wants to:
- Automate something on a schedule (e.g. "send a daily report", "remind me every Monday", "check prices every hour")
- Create a task that runs automatically ("set up a scheduled task for me")
- Use the command `/create-task`

## Task & Schedule Storage Format

### Task file: `~/.clacky/tasks/<name>.md`
Plain text prompt file. When the task fires, the Agent reads this file as its input prompt and executes it autonomously.

Example content of `~/.clacky/tasks/daily_report.md`:
```
Check today's GitHub PR list, summarize the status of each PR, and save a daily report to ~/reports/daily_<date>.md
```

### Schedule file: `~/.clacky/schedules.yml`
YAML list. Each entry has:
```yaml
- name: daily_report         # unique name, matches task name
  task: daily_report         # references ~/.clacky/tasks/daily_report.md
  cron: "0 9 * * 1-5"       # 5-field cron: minute hour day month weekday
  enabled: true
```

Cron field order: `minute hour day-of-month month day-of-week`
- `0 9 * * 1-5`  → 09:00 every weekday
- `0 9 * * *`    → 09:00 every day
- `0 */2 * * *`  → every 2 hours
- `*/30 * * * *` → every 30 minutes

## Process

### Step 1: Understand the user's intent
Ask clarifying questions if needed:
- What should the task DO? (what action, what goal)
- How often / when should it run? (if scheduling is needed)
- Any specific working directory or context?

### Step 2: Generate a task name
- Lowercase, alphanumeric + underscores only
- Short and descriptive, e.g. `daily_standup`, `price_monitor`, `weekly_report`

### Step 3: Write the task prompt file
Use the `write` tool to create `~/.clacky/tasks/<name>.md`.

The prompt content should be:
- Clear and self-contained (the agent running it has no prior context)
- Written as a direct instruction to an AI agent
- Include any relevant details the user provided (URLs, file paths, output format, etc.)

Example:
```
write(
  path: "~/.clacky/tasks/daily_standup.md",
  content: "Check today's work progress:\n1. Review recent git commits\n2. List open TODOs\n3. Generate a standup summary and print it to the terminal"
)
```

### Step 4: Write the schedule (if user wants it automated)
Read the existing `~/.clacky/schedules.yml` first (if it exists), then append the new entry and write the whole file back.

Use the `write` tool. Example full file:
```yaml
- name: daily_standup
  task: daily_standup
  cron: "0 9 * * 1-5"
  enabled: true
```

If `schedules.yml` already has entries, preserve them and append the new one.

### Step 5: Confirm to the user
Reply with a clear summary:
```
✅ Task created successfully!

📋 Name: daily_standup
📄 File: ~/.clacky/tasks/daily_standup.md
⏰ Schedule: Every weekday at 09:00 (cron: 0 9 * * 1-5)

Task prompt:
> Check today's work progress...

The task will run automatically at the next scheduled time.
You can also click ▶ in the sidebar to run it immediately.
```

## Notes
- If the user only wants a task without a schedule (run manually), skip Step 4
- Always expand `~` to the actual home path when writing files
- Task name must be sanitized: only `[a-z0-9_-]`, no spaces
- The cron scheduler checks every minute; `clacky server` must be running for auto-execution
