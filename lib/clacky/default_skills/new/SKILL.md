---
name: new
description: Create a new project to start development quickly
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

### 1. Check Directory Before Starting
Before running the setup script, check if current directory is empty:
- Use glob tool to check if directory has files: `glob("*", base_path: ".")`
- If directory is NOT empty, ask user for confirmation: "Current directory is not empty. Continue anyway? (y/n)"
- If user declines, abort and suggest creating project in an empty directory

### 2. Run Setup Script
Execute the create_rails_project.sh script in current directory:
```bash
<clacky_skills_path>/new/scripts/create_rails_project.sh
```

The script will automatically:

**Step 1: Clone Template**
- Clone rails-template-7x-starter to a temporary directory
- Move all files to current directory
- Delete template's .git directory
- Initialize new git repository with initial commit

**Step 2: Check Environment**
- Run rails_env_checker.sh to verify dependencies:
  - Ruby >= 3.0.0 (must be pre-installed)
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

### 3. Start Development Server
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
- Ruby not installed → Error message, user must install Ruby 3.x manually
- Node.js < 22 → Script installs automatically (macOS/Ubuntu)
- PostgreSQL missing → Script installs automatically (macOS/Ubuntu)
- bin/setup fails → Show error, suggest running `./bin/setup` manually
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
7. Starting development server with run_project...
8. ✨ Server running! Visit http://localhost:3000
