---
name: skill-add
description: 'Install skills from a zip URL. Use this skill whenever the user wants to install a skill from a zip link, or uses commands like /skill-add with a URL. Trigger on phrases like: install skill, install from zip, skill from zip, skill from url, add skill from zip, 安装skill, 从zip安装skill.'
disable-model-invocation: false
user-invocable: true
---

# Skill Add — Zip Installer

Installs a skill from a zip URL using the bundled `install_from_zip.rb` script.

## Finding the Script

The script lives inside this skill's directory, in one of two locations:
- Global: `~/.clacky/skills/skill-add/scripts/`
- Project-level: `.clacky/skills/skill-add/scripts/`

Locate it at runtime with:
```bash
ruby "$(find ~/.clacky/skills/skill-add .clacky/skills/skill-add -name 'install_from_zip.rb' 2>/dev/null | head -1)" <zip_url> <slug>
```

---

## How to Install

When the user provides a `.zip` URL, run:

```bash
ruby "$(find ~/.clacky/skills/skill-add .clacky/skills/skill-add -name 'install_from_zip.rb' 2>/dev/null | head -1)" <zip_url> <slug>
```

- `<zip_url>` — the download URL provided by the user
- `<slug>` — the skill's directory name; if not provided, infer it from the URL filename by stripping version suffixes (e.g. `canvas-design-1.2.0.zip` → `canvas-design`)

The script handles everything automatically:
- Downloads the zip (follows HTTP redirects)
- Extracts and locates all `SKILL.md` files inside
- Copies skill directories to `.clacky/skills/` in the current project (overwrites existing)
- Reports installed skills with their descriptions

**Do NOT manually download or unzip — the script handles everything.**

## Example

```
/skill-add https://store.clacky.ai/skills/canvas-design-1.2.0.zip
```

```bash
ruby "$(find ~/.clacky/skills/skill-add .clacky/skills/skill-add -name 'install_from_zip.rb' 2>/dev/null | head -1)" \
  "https://store.clacky.ai/skills/canvas-design-1.2.0.zip" \
  "canvas-design"
```

## Notes

- Skills install to `.clacky/skills/` in the current project
- Project-level skills override global skills (`~/.clacky/skills/`)
- If the user doesn't provide a URL, ask them for the zip URL — this skill only supports zip installs
