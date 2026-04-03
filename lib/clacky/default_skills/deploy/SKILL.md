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

Execute the deployment script directly via the shell tool.
Do **not** add any AI reasoning steps between phases — the script handles all
logic internally and is fully automated.

### Step 1 — Run the deploy script

```bash
bundle exec ruby <absolute-path-to-this-skill>/scripts/rails_deploy.rb
```

The script path is shown in the Supporting Files section below.

The script runs three phases automatically:

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
| `null` / `OFF` / `CANCELLED` | Open payment page, poll for confirmation |

Payment polling: open `https://app.clacky.ai/dashboard/openclacky-project/<id>`
in browser, poll `GET /openclacky/v1/deploy/payment` every 10 s for up to 60 s.

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

### Step 2 — Report result

After the script exits:

**On success** — print the final URL and dashboard link from script output.
Do not add extra commentary beyond what the script already printed.

**On failure** — show the error message from the script.
If build logs were printed, summarise the most likely cause in one sentence.
Suggest next steps (e.g. fix the error shown, then re-run `/deploy`).

---

## Important constraints

- **Never** modify source files before deploying.
- **Never** commit or push changes as part of this skill.
- **Never** prompt the user for Railway credentials — those come from the
  Clacky platform (`platform_token` is returned by `create-task`).
- If `railway` CLI is not installed, hard-fail with install instructions:
  `npm install -g @railway/cli`
