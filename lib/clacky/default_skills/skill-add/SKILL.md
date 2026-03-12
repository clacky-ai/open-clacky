---
name: skill-add
description: Install skills from a zip URL or create new skills interactively
disable-model-invocation: false
user-invocable: true
---

# Skill Add — Installation & Creation

A skill management tool that installs skills from a zip URL or creates new skills interactively.

## ⚠️ Usage Instructions

- **Zip URL** (e.g. from Public Store): Call `ruby <skill_directory>/scripts/install_from_zip.rb <url> <slug>` via safe_shell
- **Text description or no arguments**: Handle interactively via conversation, create files with write tool

## Usage Modes

### 1. Install from Zip URL (Public Store)
```
/skill-add Install the "my-skill" skill from https://example.com/my-skill-1.0.0.zip
```

**When the URL ends with `.zip`, execute the `install_from_zip.rb` script:**

Use the **Skill Directory** path shown below, and call:
```bash
ruby <skill_directory>/scripts/install_from_zip.rb <zip_url> <slug>
```
Pass the skill's `slug` as the second argument so the installed directory gets the correct name.

The script will automatically:
- Download the zip archive from the URL (follows HTTP redirects)
- Extract the archive to a temporary directory
- Find all skill directories containing SKILL.md files
- Copy them to `.clacky/skills/` in the current project (overwrites existing)
- Report installed skills with descriptions
- Clean up temporary files

**Do NOT manually download or unzip files - the script handles everything.**

### 2. Interactive Creation Mode
```
/skill-add Brief description of what the skill should do
/skill-add Create a skill for database migrations
```

**Process:**
1. Understand the skill requirement from user's description
2. Ask clarifying questions:
   - What is the main purpose?
   - What inputs/parameters are needed?
   - Should it have helper scripts?
   - Any specific commands or tools needed?
3. Design the skill structure:
   - Skill name (kebab-case)
   - Description
   - Usage instructions
   - Step-by-step process
   - Optional: Create helper scripts in `scripts/` subdirectory
4. Create the skill in `.clacky/skills/{skill-name}/`
5. Show summary of created files

**Example Interaction:**
```
User: /skill-add Create a skill for API testing with curl

Agent: I'll help you create an API testing skill. Let me ask a few questions:

Q1: What's the main purpose of this skill?
User: Test REST APIs quickly with different HTTP methods

Agent: Great! A few more questions:
Q2: Should it support authentication (API keys, tokens)?
User: Yes, Bearer tokens

Q3: Should it have pre-configured examples?
User: Yes, for common patterns like GET, POST, PUT, DELETE

Agent: Perfect! Creating skill...

Created files:
✓ .clacky/skills/api-tester/SKILL.md
✓ .clacky/skills/api-tester/scripts/test_endpoint.sh
✓ .clacky/skills/api-tester/scripts/examples.json

You can now use: /api-tester
```

### 3. Quick Start (No Arguments)
```
/skill-add
```

**Process:**
- Ask user what they want to create
- Offer suggestions based on common patterns:
  - Command runner
  - Code analyzer
  - File processor
  - Data transformer
  - Custom workflow
- Guide them through creation with focused questions
- Create the skill with best practices

## Implementation Guidelines

### For Zip URL Installation (Public Store)

Detect a zip URL when the argument contains `.zip` (case-insensitive).
Use the `install_from_zip.rb` script (available in Supporting Files):

```bash
ruby <skill_directory>/scripts/install_from_zip.rb <zip_url> <slug>
```
Pass the skill slug as the second argument (e.g. `ui-ux-pro-max`) so the installed directory gets the correct name.

The Skill Directory path is shown at the bottom of this document.

**Do NOT manually download or extract files - let the script handle everything.**

### For Interactive Creation

When user provides a description or no arguments:

1. **Parse Intent**: Understand what the user wants to create from their description

2. **Gather Requirements**: Ask 3-5 focused questions through conversation:
   - What should we call this skill? (suggest a name based on description)
   - What inputs/arguments does it need?
   - What are the main steps it should perform?
   - Should it have helper scripts? (bash/ruby/python)
   - Any specific tools or commands to use?

3. **Design Structure**: Based on answers, design the SKILL.md content with:
   - Valid YAML frontmatter (name, description, etc.)
   - Clear usage instructions
   - Step-by-step process
   - Examples
   - Scripts if needed

4. **Create Files** using write tool:
   - `.clacky/skills/{skill-name}/SKILL.md`
   - `.clacky/skills/{skill-name}/scripts/` (if needed)
   - Helper scripts with proper permissions

5. **Confirm**: Show what was created and how to use it

## Skill Structure

### Minimal SKILL.md
```markdown
---
name: hello-world
description: Simple greeting skill
disable-model-invocation: false
user-invocable: true
---

# Hello World Skill

## Usage
Say "hello" or `/hello-world`

## Process Steps
### 1. Greet the user
### 2. Offer assistance
```

### Full-Featured Skill
```markdown
---
name: db-migrate
description: Database migration helper with rollback support
disable-model-invocation: false
user-invocable: true
---

# Database Migration Helper

## Usage
`/db-migrate [action] [options]`

Actions:
- create - Create new migration
- up - Run pending migrations
- down - Rollback last migration
- status - Show migration status

## Process Steps

### 1. Determine Action
Parse the command arguments to identify the action.

### 2. Execute Action
Run the appropriate migration script from scripts/ directory.

### 3. Report Results
Show migration status and any errors.
```

## Best Practices

1. **Clear Naming**: Use kebab-case for skill names (e.g., `api-tester`, `code-formatter`)
2. **Good Descriptions**: Write concise, actionable descriptions
3. **Structured Steps**: Break down process into clear, numbered steps
4. **Helper Scripts**: Use scripts/ directory for complex logic
5. **Examples**: Always include usage examples
6. **Documentation**: Explain all parameters and options

## Notes

- Skills are installed to `.clacky/skills/` in the current project directory
- Project skills (`.clacky/skills/`) override global skills (`~/.clacky/skills/`)
- Skill names must be lowercase with hyphens only
- SKILL.md must have valid YAML frontmatter
- Scripts should be executable (chmod +x)
- Test skills after creation with `/skill-name`
