---
name: cron-task-creator
description: 'Create, manage, and run scheduled automated tasks (cron jobs) in Clacky. Use this skill whenever the user wants to create a new automated task or cron job, set up recurring automation, schedule something to run daily/weekly/hourly, view all scheduled tasks, edit an existing task prompt or cron schedule, enable or disable a task, delete a task, check task run history or logs, or run a task immediately via the WebUI. Trigger on phrases like 定时任务, 自动化任务, 每天自动, 创建任务, cron, 定时执行, scheduled task, automate this, run every day, set up automation, edit my task, list my tasks, what tasks do I have, disable task, run task now, task history, etc.'
disable-model-invocation: false
user-invocable: true
---

# Cron Task Creator

A skill for creating, managing, and running scheduled automated tasks in Clacky.

## Architecture Overview

```
Storage:
  ~/.clacky/tasks/<name>.md      # Task prompt file (self-contained AI instruction)
  ~/.clacky/schedules.yml        # All scheduled plans (YAML list)
  ~/.clacky/logger/clacky-*.log  # Execution logs (daily rotation)

API Base: http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}

Cron-Tasks API (unified — manages task file + schedule together):
  GET    /api/cron-tasks              → list all cron tasks with schedule info
  POST   /api/cron-tasks              → create task + schedule {name, content, cron, enabled?}
  PATCH  /api/cron-tasks/:name        → update {content?, cron?, enabled?}
  DELETE /api/cron-tasks/:name        → delete task file + schedule
  POST   /api/cron-tasks/:name/run    → execute immediately (creates a new session)
```

## Cron Expression Quick Reference

| Expression       | Meaning                    |
|-----------------|---------------------------|
| `0 9 * * 1-5`  | Weekdays at 09:00         |
| `0 9 * * *`    | Every day at 09:00        |
| `0 */2 * * *`  | Every 2 hours             |
| `*/30 * * * *` | Every 30 minutes          |
| `0 19 * * *`   | Every day at 19:00        |
| `0 8 * * 1`    | Every Monday at 08:00     |
| `0 0 1 * *`    | First day of every month  |

Field order: `minute hour day-of-month month day-of-week`

---

## Operations

### 1. LIST — Show all tasks

```bash
curl -s http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks
```

Display each task: name, cron schedule, enabled status, content preview.

If no tasks exist, inform the user and offer to create one or show templates.

**Key tip**: Remind the user that the Clacky WebUI Task Panel (sidebar → Tasks) also shows all tasks and supports direct management.

---

### 2. CREATE — New task

**Step 1: Gather required info** (only ask for what's missing)
- What should the task DO? (goal, behavior, output format)
- How often should it run? (or is it manual-only without a schedule?)
- Any specific parameters? (URLs, file paths, output location, language)

**Step 2: Generate task name**
- Rule: only `[a-z0-9_-]`, lowercase, no spaces
- Examples: `daily_report`, `price_monitor`, `weekly_summary`

**Step 3: Write the task prompt**

The prompt must be:
- **Self-contained**: the agent running it has zero prior context — include everything needed
- **Written as direct instructions** to an AI agent (imperative, not conversational)
- **Detailed**: include URLs, file paths, output format, language, expected output location

Good task prompt example:
```
You are a price monitoring assistant. Complete the following task:

## Goal
Check the current BTC price on CoinGecko, compare with yesterday's price, and log an alert if the change exceeds 5%.

## Steps
1. Fetch https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true
2. Parse the JSON response to get current price and 24h change
3. If |change| > 5%, write an alert to ~/price_alerts/alert_YYYY-MM-DD.txt
4. Print the current price and change percentage

Execute immediately.
```

**Step 4: Create via API**

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks \
  -H "Content-Type: application/json" \
  -d '{
    "name": "task_name",
    "content": "task prompt content...",
    "cron": "0 9 * * *",
    "enabled": true
  }'
```

**Step 5: Confirm creation**

```
✅ Task created successfully!

📋 Task name: daily_standup
⏰ Schedule: Weekdays at 09:00 (cron: 0 9 * * 1-5)

View and manage this task in the Clacky WebUI → Tasks panel. Click ▶ Run to execute immediately.
```

---

### 3. EDIT — Modify an existing task

**Step 1**: Identify the task (if unclear, LIST first and ask)

**Step 2**: Show current state via LIST or ask user to confirm

**Step 3**: Update via API

```bash
# Update content only
curl -s -X PATCH http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks/task_name \
  -H "Content-Type: application/json" \
  -d '{"content": "new prompt content..."}'

# Update cron schedule only
curl -s -X PATCH http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks/task_name \
  -H "Content-Type: application/json" \
  -d '{"cron": "0 8 * * 1-5"}'

# Update both
curl -s -X PATCH http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks/task_name \
  -H "Content-Type: application/json" \
  -d '{"content": "...", "cron": "0 8 * * 1-5"}'
```

**Step 4**: Confirm changes

```
✅ Task updated!
📋 daily_standup
  Schedule: 0 9 * * 1-5 → 0 8 * * 1-5 (now weekdays at 08:00)
```

---

### 4. ENABLE / DISABLE — Toggle a task

```bash
# Disable
curl -s -X PATCH http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks/task_name \
  -H "Content-Type: application/json" \
  -d '{"enabled": false}'

# Enable
curl -s -X PATCH http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks/task_name \
  -H "Content-Type: application/json" \
  -d '{"enabled": true}'
```

Confirm:
```
✅ daily_standup has been disabled.
   To re-enable: say "enable daily_standup"
```

---

### 5. DELETE — Remove a task

Always confirm before deleting (unless the user has explicitly said to delete):

```
⚠️ Are you sure you want to delete daily_standup? This cannot be undone.
```

```bash
curl -s -X DELETE http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks/task_name
```

---

### 6. HISTORY — View run history

Read the daily log files directly:

```bash
grep "task_name" ~/.clacky/logger/clacky-$(date +%Y-%m-%d).log | tail -20
```

Or search across recent days:
```bash
grep -h "task_name" ~/.clacky/logger/clacky-*.log | tail -30
```

Display format:
```
📊 Run History: ai_news_x_daily

Mar 10  19:00  ❌ Failed  — JSON::ParserError: unexpected end of input
Mar 09  19:00  ✅ Success — took 1m 42s
Mar 08  19:00  ✅ Success — took 2m 10s
```

---

### 7. RUN NOW — Execute immediately

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks/task_name/run
```

This creates a new session. Tell the user:
```
▶️ Task started in a new session.
   View it in the Clacky WebUI → Sessions panel.
```

---

### 8. TEMPLATES — Browse common task templates

When user says "what templates are there" or "what can I automate":

```
📚 Common Task Templates — pick one to get started:

1. 📰 AI News Digest       — Daily fetch of AI news from X/RSS, generate Markdown report
2. 💰 Price Monitor        — Check crypto/stock prices on a schedule, log alerts on anomalies
3. 📊 Weekly Work Summary  — Every Monday, summarize last week's work into a report
4. 🌤 Weather Reminder     — Fetch weather every morning and save to file
5. 🔍 Competitor Monitor   — Periodically scrape competitor sites for changes
6. 📝 Journal Prompt       — Evening reminder to journal with daily reflection questions
7. 🔗 Link Health Check    — Periodically verify specified URLs are accessible
8. 📂 File Backup          — Regularly back up a specified directory to another location

Tell me which one interests you, or describe your own use case!
```

---

## Important Notes

- Task names: only `[a-z0-9_-]`, no spaces, no uppercase
- Task prompt files must be **self-contained** — the executing agent has no prior memory
- Clacky server must be running for cron to trigger automatically (checked every minute)
- The WebUI Task Panel is the preferred interface for managing tasks — always remind the user to check it after changes
