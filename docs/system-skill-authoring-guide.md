# System Skill Authoring Guide

Guidelines for writing built-in (system-level) skills under `lib/clacky/default_skills/`.

---

## 1. Communicating with the Clacky server

Always use environment variables — never hardcode the port.

```bash
curl -s http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/xxx
```

`http_server.rb` injects `CLACKY_SERVER_HOST` and `CLACKY_SERVER_PORT` at startup.

---

## 2. Read state via API, not config files

Skills must not read local config files directly.

- ❌ `cat ~/.clacky/browser.yml`
- ✅ `curl http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/browser/status`

Exception: lightweight `enable` / `disable` operations may read/write yml directly (see `channel-manager`).

---

## 3. Running supporting scripts

If a skill includes supporting scripts, instruct the AI to run them directly using the full path — **do not describe how to discover the path**. The LLM context already contains the full paths of all files in the skill directory (injected via supporting files at invoke time).

Write it simply as:

```
Run the setup script:
ruby SKILL_DIR/scripts/feishu_setup.rb
```

or for Python:

```
python3 SKILL_DIR/scripts/setup.py
```

No `Gem.find_files`, no `find` fallback, no path-discovery logic needed.
