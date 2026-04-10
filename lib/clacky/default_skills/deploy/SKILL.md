---
name: deploy
description: Deploy Rails applications to Railway PaaS
agent: coding
fork_agent: true
---

# Railway Deployment for Rails

Deploy a Rails application to the Clacky cloud platform (Railway backend).

## When to invoke

Trigger this skill when the user says:
- "deploy", "/deploy", "deploy my app", "push to production"
- "部署", "上线", "发布"

---

## How to run

### Step 1 — Tell the user deployment has started

**Before running the script**, output a message to the user so they know work is underway:

```
🚀 Starting deployment... This usually takes 2-4 minutes.
Checking project binding → subscription → building → migrating → health check
```

This is important because `safe_shell` does not stream output — the user sees
nothing until the command finishes. The pre-run message reassures them.

### Step 2 — Run the deploy script

```bash
bundle exec ruby <absolute-path-to-this-skill>/scripts/rails_deploy.rb
```

**Timeout**: set to at least 600 seconds (10 minutes).

The script prints each step as it runs. When it finishes it prints one of:

```
[DEPLOY] RESULT: SUCCESS (2m 34s)
[DEPLOY] RESULT: FAILED (45s) — <error message>
```

### Step 3 — Show the full output to the user

After the script exits, **always show the complete stdout output** to the user
in a code block or verbatim. The output contains step-by-step logs they need
to see. Do NOT summarise silently — show everything, then add your summary.

### On success
After showing the output, report the deployed URL and any useful links.

### On failure
After showing the output, show the error message and summarise the most
likely cause in one sentence. Suggest next steps (e.g. fix the error shown,
then re-run `/deploy`).

---

## What the script does internally

The script runs three phases automatically. Do **not** add any AI reasoning
steps between phases — the script handles all logic internally.

**Phase 0 — Cloud project binding**
1. Reads `.clacky/openclacky.yml` for `project_id`
   - If file is missing → runs inline cloud project creation flow
     (reuses `new/scripts/cloud_project_init.sh`), writes the file, continues
   - If `project_id` is blank → hard-fail (corrupted file)
2. Reads `~/.clacky/platform.yml` for `workspace_key`
   - If missing/empty → hard-fail with guidance to obtain key offline
3. Calls `GET /openclacky/v1/projects/:id` to verify the project exists
   - 404 → runs inline cloud project creation flow, continues
   - Other error → hard-fail

**Phase 1 — Subscription check**

| `subscription.status` | Action |
|------------------------|--------|
| `PAID` | ✅ Continue |
| `FREEZE` | ⚠️ Warn, continue |
| `SUSPENDED` | ❌ Hard-fail |
| `null` / `OFF` / `CANCELLED` | Open payment page, poll for activation |

Payment polling: open `https://app.clacky.ai/dashboard/openclacky-project/<id>`
in browser, poll `GET /openclacky/v1/deploy/payment` every 10 s for up to 180 s.

**Phase 2 — Deployment (8 steps)**

| Step | Action |
|------|--------|
| 1 | `POST /deploy/create-task` → get `platform_token`, `platform_project_id`, `deploy_task_id` |
| 2 | `railway link --project <id> --environment production` |
| 3 | Inject env vars: Rails defaults + Figaro `config/application.yml` production block + `categorized_config` |
| 4 | Poll `GET /deploy/services` until DB middleware is `SUCCESS` → inject `DATABASE_URL` reference; call `POST /deploy/bind-domain` |
| 5 | `railway up --service <name> --detach` → notify backend `"deploying"` |
| 6 | Poll `GET /deploy/status` every 5 s (max 300 s) until `SUCCESS` or failure |
| 7 | `railway run bundle exec rails db:migrate`; seed if first deployment |
| 8 | HTTP health check on deployed URL; notify backend `"success"` |

All `railway` commands receive `RAILWAY_TOKEN` via Ruby `ENV` hash — no
`clackycli` wrapper is needed.

---

## Important constraints

- **Never** modify source files before deploying.
- **Never** commit or push changes as part of this skill.
- **Never** prompt the user for Railway credentials — those come from the
  Clacky platform (`platform_token` is returned by `create-task`).
- If `railway` CLI is not installed, hard-fail with install instructions:
  `npm install -g @railway/cli`
