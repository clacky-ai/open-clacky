---
name: new
description: Create a new project to start development quickly
agent: coding
disable-model-invocation: false
user-invocable: true
---

# Create New Project

## Usage
When user wants to create a new Rails project:
- "help me create a new Rails project"
- "I want to start a new Rails project"
- "/new"

## Process Steps

### 0. Ask Project Type and Requirement
Before doing anything, use `request_user_feedback` to ask the user two things:

```
project_type: "demo" or "production"
requirement: one-sentence description of what they want to build
```

Card content:
- Title: "🚀 New Project"
- Two options for project type:
  - **⚡ Demo** — no database, AI builds freely, quick prototype
  - **🏗️ Production** — real app, ready to deploy, full Rails setup
- One text input: "Describe your project in one sentence"
- Confirm button: "Let's go!"

**Based on user's choice:**
- If **Demo**: do NOT follow the Rails setup steps below. Instead, freely build a simple HTML/CSS/JS (or React) prototype directly in the working directory based on their requirement. Use your creativity.
- If **Production**: continue with steps 1–3 below (full Rails flow).

### 1. Check Directory Before Starting
Before running the setup script, check if current directory is empty:
- Use glob tool to check if directory has files: `glob("*", base_path: ".")`
- If directory is NOT empty, ask user for confirmation: "Current directory is not empty. Continue anyway? (y/n)"
- If user declines, abort and suggest creating project in an empty directory

### 2. Run Setup Script
Execute the `create_rails_project.sh` script (see Supporting Files below) in current directory.
Use the exact absolute path shown in the Supporting Files section:
```bash
<absolute path to create_rails_project.sh from Supporting Files>
```

The script will automatically:

**Step 1: Clone Template**
- Clone rails-template-7x-starter to a temporary directory
- Move all files to current directory
- Delete template's .git directory
- Initialize new git repository with initial commit

**Step 2: Check Environment**
- Run rails_env_checker.sh to verify dependencies:
  - Ruby >= 3.3.0 (auto-installed via mise if missing or too old — supports CN mirrors)
  - Node.js >= 22.0.0 (will install automatically if missing on macOS/Ubuntu)
  - PostgreSQL (will install automatically if missing on macOS/Ubuntu)
- Script automatically installs missing dependencies without prompting

**Step 3: Install Project Dependencies**
- Run ./bin/setup to:
  - Install Ruby gems (bundle install)
  - Install npm packages (npm install)
  - Copy configuration files
  - Setup database (db:prepare)
  
**Step 4: Project Setup Complete**
- Script completes successfully
- Project is ready to run

### 3. Cloud Project Init
After the setup script completes, initialize the cloud project binding.

**Goal**: Create a cloud project on the Clacky platform, then inject the returned
`categorized_config` (auth/email/llm/stripe credentials) into the local development
environment so the app can use platform services out of the box.

#### 3.1 Check existing binding
Check if `.clacky/openclacky.yml` already exists:
```bash
ls .clacky/openclacky.yml 2>/dev/null && cat .clacky/openclacky.yml || echo "NOT_FOUND"
```

If it exists, ask the user:
```
A cloud project binding already exists:
  Project: <project_name> (<project_id>)

Do you want to reuse this binding? (y/n)
```
- **Yes** → skip to step 3.5 (files already written, no need to re-create)
- **No** → continue to 3.2

#### 3.2 Run the cloud project init script
Use the `cloud_project_init.sh` script from Supporting Files.
Run it with safe_shell from the project directory (no arguments needed — it auto-reads `~/.clacky/clacky_cloud.yml`):

```bash
bash <absolute_path_to_cloud_project_init.sh>
```

The script outputs a single JSON line. Capture the full output.

**If the output contains `"success":false`** → soft-fail:
```
⚠️  Cloud project creation failed: <error value from JSON>
    Skipping cloud init. You can link a project later with /deploy.
```
Then skip to Step 4.

**If the output contains `"success":true`** → parse the JSON and extract:
- `project_id` — the cloud project UUID
- `project_name` — the project name
- `categorized_config` — nested object with auth/email/llm/stripe keys

The `categorized_config` looks like:
```json
{
  "auth":   { "CLACKY_AUTH_CLIENT_ID": "...", "CLACKY_AUTH_CLIENT_SECRET": "...", "CLACKY_AUTH_HOST": "..." },
  "email":  { "CLACKY_EMAIL_API_KEY": "...", "CLACKY_EMAIL_SMTP_ADDRESS": "...", "CLACKY_EMAIL_SMTP_DOMAIN": "...", "CLACKY_EMAIL_SMTP_PORT": 25, "CLACKY_EMAIL_SMTP_USERNAME": "..." },
  "llm":    { "CLACKY_LLM_API_KEY": "...", "CLACKY_LLM_BASE_URL": "..." },
  "stripe": { "CLACKY_STRIPE_PUBLISHABLE_KEY": "...", "CLACKY_STRIPE_SECRET_KEY": "...", "CLACKY_STRIPE_WEBHOOK_SECRET": "..." }
}
```

#### 3.3 Write `.clacky/openclacky.yml`
Create the directory and write the binding file (no sensitive data — safe to commit):
```bash
mkdir -p .clacky
```
Then use the `write` tool to create `.clacky/openclacky.yml`:
```yaml
# .clacky/openclacky.yml
# Committed to git. No sensitive data. Shared across team.
project_id: "<project_id from JSON>"
project_name: "<project_name from JSON>"
```

#### 3.4 Update `config/application.yml`
Read the current `config/application.yml` first, then **prepend** a clearly-marked block at the very top of the file.
Use the `write` tool to rewrite the file with the cloud config block inserted before the existing content:
```yaml
# --- Auto-generated by clacky /new (Cloud project: <project_name>) ---
CLACKY_AUTH_CLIENT_ID: "<value>"
CLACKY_AUTH_CLIENT_SECRET: "<value>"
CLACKY_AUTH_HOST: "<value>"
CLACKY_EMAIL_API_KEY: "<value>"
CLACKY_EMAIL_SMTP_ADDRESS: "<value>"
CLACKY_EMAIL_SMTP_DOMAIN: "<value>"
CLACKY_EMAIL_SMTP_PORT: "<value>"
CLACKY_EMAIL_SMTP_USERNAME: "<value>"
CLACKY_LLM_API_KEY: "<value>"
CLACKY_LLM_BASE_URL: "<value>"
CLACKY_STRIPE_PUBLISHABLE_KEY: "<value>"
CLACKY_STRIPE_SECRET_KEY: "<value>"
CLACKY_STRIPE_WEBHOOK_SECRET: "<value>"

# --- (original content below) ---
<original file content>
```
Only include keys present in the JSON response.

#### 3.5 Git commit
Commit the cloud project binding file.
Note: `config/application.yml` is gitignored (it contains secrets) — do NOT try to add it.
```bash
git add .clacky/openclacky.yml
git commit -m "Initialize cloud project binding"
```

Print a success summary:
```
✅ Cloud project initialized!
   Project: <project_name> (<project_id>)
   Config written to: config/application.yml
```

### 4. Start Development Server
After the script completes, use the run_project tool to start the server:
```
run_project(action: "start")
```

**Important**: If run_project executes without errors, the server has started successfully. 

Then inform the user and ask what to develop next:
```
✨ Rails project created successfully!

The development server is now running at: http://localhost:3000

You can open your browser and visit the URL to see the application.

What would you like to develop next?
```

## Error Handling
- Directory not empty → Ask user confirmation, abort if declined
- Git clone fails → Check network connection, verify repository URL
- Ruby < 3.3 or missing → **Automatically installs Ruby 3.3 via mise** (with CN mirror support); exits with instructions if mise install fails
- Node.js < 22 → Script installs automatically (macOS/Ubuntu)
- PostgreSQL missing → Script installs automatically (macOS/Ubuntu)
- bin/setup fails → Show error, suggest running `./bin/setup` manually
- Cloud project creation fails → Soft-fail with warning, continue to start server
- workspace_key missing → Ask user interactively; skip cloud init if user declines
- run_project fails → Check logs with `run_project(action: "output")` and verify database status

## Example Interaction
User: "/new"

Response:
1. Checking if current directory is empty...
2. Running create_rails_project.sh in current directory
3. Cloning Rails template from GitHub...
4. Checking environment dependencies...
5. Installing project dependencies...
6. Project setup complete!
7. Initializing cloud project binding...
8. ✅ Cloud project created and config injected into config/application.yml!
9. Starting development server with run_project...
10. ✨ Server running! Visit http://localhost:3000
