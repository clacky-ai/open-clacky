---
name: browser-setup
description: |
  Configure the browser tool for Clacky. Guides the user through Chrome or Edge setup,
  verifies the connection, and writes ~/.clacky/browser.yml.
  Supports macOS, Linux, and WSL (Windows Chrome/Edge via remote debugging).
  Trigger on: "browser setup", "setup browser", "配置浏览器", "browser config",
  "browser doctor".
  Subcommands: setup, doctor.
argument-hint: "setup | doctor"
allowed-tools:
  - Bash
  - Read
  - Write
  - browser
---

# Browser Setup Skill

Configure the browser tool for Clacky. Config is stored at `~/.clacky/browser.yml`.

## Command Parsing

| User says | Subcommand |
|---|---|
| `browser setup`, `配置浏览器`, `setup browser` | setup |
| `browser doctor` | doctor |

If no subcommand is clear, default to `setup`.

---

## `setup`

### Step 1 — Ensure chrome-devtools-mcp is installed

Check if already installed:
```bash
chrome-devtools-mcp --version 2>/dev/null
```

If found and exits 0 → skip to Step 2.

If missing, run the bundled installer (handles Node.js + chrome-devtools-mcp + CN/global mirrors automatically):
```bash
bash ~/.clacky/scripts/install_browser.sh
```

If the script exits non-zero or `~/.clacky/scripts/install_browser.sh` doesn't exist, stop and tell the user:

> ❌ Failed to install chrome-devtools-mcp automatically.
> Please run manually:
> ```
> npm install -g chrome-devtools-mcp@latest
> ```
> (Requires Node.js 20+. If Node.js is missing, install it first, then retry.)
> Let me know when done.

### Step 2 — Try to connect to the browser

Immediately attempt to connect — do **not** ask the user anything first:

```
browser(action="act", kind="evaluate", js="navigator.userAgentData?.brands?.find(b => b.brand === 'Google Chrome' || b.brand === 'Microsoft Edge')?.version || navigator.userAgent.match(/Chrome\/([\d]+)/)?.[1] || 'unknown'")
```

**If connection succeeds** → parse the browser version and jump to Step 3.

**If connection fails** → inspect the error message from the evaluate result to diagnose:

**Case A — error contains `"timed out"`**: The MCP daemon failed to start — Chrome or Edge is not running or remote debugging is not enabled. Try to open the page for the user:

```bash
open "chrome://inspect/#remote-debugging"
```

Tell the user:

> I've opened `chrome://inspect/#remote-debugging` in your browser.
> Please click **"Allow remote debugging for this browser instance"** and let me know when done.

If `open` fails (e.g. on WSL or Linux), fall back to:

> Please open this URL in Chrome or Edge:
> `chrome://inspect/#remote-debugging`
> Then click **"Allow remote debugging for this browser instance"** and let me know when done.
>
> On WSL: launch your browser from PowerShell with remote debugging enabled:
> - Edge: `Start-Process msedge --ArgumentList "--remote-debugging-port=9222"`
> - Chrome: `Start-Process chrome --ArgumentList "--remote-debugging-port=9222"`

Wait for the user to confirm, then retry the connection once. If still failing, stop:

> ❌ Could not connect to the browser. Please make sure Chrome or Edge is open and remote debugging is enabled, then run `/browser-setup` again.

**Case B — error contains `"Chrome MCP error:"`**: The MCP daemon is alive but the browser's CDP connection is broken — this is a known issue after long sessions. Tell the user:

> The browser's remote debugging connection is unstable.
> Please restart your browser and let me know when done.

Wait for the user to confirm, then retry once. If still failing, stop with the same error message as Case A.

### Step 3 — Check browser version

Parse the version number from Step 2 (works for both Chrome and Edge, both are Chromium-based):
- version >= 146 → proceed
- version 144–145 → warn but proceed:
  > ⚠️ Your browser version is vXXX. Version 146+ is recommended. Continuing anyway...
- version < 144 or unknown → stop:
  > ❌ Browser vXXX is too old. Please upgrade Chrome or Edge to v146+, then let me know and I'll retry.

### Step 4 — Save config and start daemon

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/browser/configure \
  -H "Content-Type: application/json" \
  -d '{"chrome_version":"<VERSION>"}'
```

This writes `~/.clacky/browser.yml` and hot-reloads the daemon in one step.
If this fails (server not running), skip silently — the daemon will start lazily on next use.

### Step 5 — Done

> ✅ Browser configured.
>
> Chrome/Edge v<VERSION> is connected and ready to use.

---

## `doctor`

Run a diagnostic check and report each item:

```
Browser Doctor
──────────────
[✅/❌] Config file              (~/.clacky/browser.yml)
[✅/❌] Node.js 20+              (node --version)
[✅/❌] chrome-devtools-mcp      (chrome-devtools-mcp --version)
[✅/❌] Chrome connection        (browser status)
[✅/❌] Chrome version           (≥146 best, ≥144 OK)
```

For any ❌ item, show the fix inline.

Steps:
1. Check `~/.clacky/browser.yml`:
   - File missing → ❌ Not configured. Stop and suggest running `/browser-setup`.
   - File exists, `enabled: false` → ⏸ Configured but disabled. Suggest running `/browser-setup` to re-enable.
   - File exists, `enabled: true` → ✅ Continue.
2. Run `node --version` via Bash.
3. Run `chrome-devtools-mcp --version` via Bash; if missing, suggest `npm install -g chrome-devtools-mcp`.
4. Run `browser(action="status")`:
   - If failed, inspect the error message to distinguish the cause:
     - error contains `"timed out"` → MCP daemon failed to start; Chrome not running or remote debugging not enabled. Fix: open `chrome://inspect/#remote-debugging`, click **"Allow remote debugging for this browser instance"**.
     - error contains `"Chrome MCP error:"` → daemon alive but CDP connection broken after long session. Fix: restart Chrome.
5. If step 4 succeeded, run evaluate to get Chrome version.

Report all results together at the end.
