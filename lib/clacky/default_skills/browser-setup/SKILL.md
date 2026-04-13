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

**Core Strategy**: Progressive validation with clear next steps at each failure point.

### Step 1 — Ensure Node.js is installed

Check Node.js version:
```bash
node --version 2>/dev/null
```

Parse the version. If Node.js is missing or version < 20:

Run the bundled installer to automatically install Node.js:
```bash
bash ~/.clacky/scripts/install_browser.sh
```

If the script exits 0 → Node.js is now installed. Proceed to Step 2.

If the script exits non-zero or doesn't exist:

> ❌ Node.js 20+ is required for browser automation.
>
> Please install Node.js from: https://nodejs.org
>
> Let me know when done and I'll continue.

Wait for user confirmation, then retry this step once. If still failing, stop.

### Step 2 — Ensure chrome-devtools-mcp is installed

Check if installed:
```bash
chrome-devtools-mcp --version 2>/dev/null
```

If found and exits 0 → skip to Step 3.

If missing, run the bundled installer:
```bash
bash ~/.clacky/scripts/install_browser.sh
```

If the script exits non-zero or doesn't exist:

> ❌ Failed to install chrome-devtools-mcp automatically.
>
> Please run manually:
> ```
> npm install -g chrome-devtools-mcp@latest
> ```
>
> Let me know when done.

Wait for user confirmation, then verify installation:
```bash
chrome-devtools-mcp --version 2>/dev/null
```

If still missing after user confirms, stop with error message.

### Step 3 — Verify Chrome/Edge is running with remote debugging

**CRITICAL**: Do NOT attempt `browser()` calls yet. First check if the browser is reachable using the API:

```bash
curl -s http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/browser/status
```

This returns JSON with `daemon_running` and `enabled` status. **Ignore the result for now** — we just need to see if the Clacky server is running.

Now attempt a browser connection to detect Chrome:

```bash
browser(action="status")
```

**If this succeeds** → Chrome is running and reachable. Proceed to Step 4.

**If this fails** → The error message will indicate the specific issue. Parse it carefully:

#### Case A: "Chrome/Edge is not running or remote debugging is not enabled"

This is the most common case. The system can't find Chrome's DevToolsActivePort file or the port is not reachable.

**Action**: Guide the user to enable remote debugging.

**On macOS**:
```bash
open "chrome://inspect/#remote-debugging" 2>/dev/null || echo "Please open chrome://inspect/#remote-debugging manually"
```

Then tell the user:

> I've tried to open the remote debugging page in Chrome.
>
> Please follow these steps:
> 1. Make sure **Chrome or Edge is open**
> 2. Visit: `chrome://inspect/#remote-debugging` (or `edge://inspect/#remote-debugging`)
> 3. Click **"Allow remote debugging for this browser instance"**
> 4. You should see a brief connection message appear
>
> Let me know when done ✅

**On Linux (non-WSL)**:

> Please follow these steps:
> 1. Make sure **Chrome or Edge is open**
> 2. Visit: `chrome://inspect/#remote-debugging`
> 3. Click **"Allow remote debugging for this browser instance"**
>
> Let me know when done ✅

**On WSL**:

> Please follow these steps:
> 1. Open **Edge** on Windows
> 2. Visit: `edge://inspect/#remote-debugging`
> 3. Click **"Allow remote debugging for this browser instance"**
>
> Let me know when done ✅

**After user confirms**, retry the connection **once**:
```bash
browser(action="status")
```

If still failing:

> ❌ Still unable to connect to Chrome.
>
> Please make sure:
> - Chrome/Edge is running
> - You clicked "Allow remote debugging" in chrome://inspect/#remote-debugging
> - No firewall is blocking localhost connections
>
> Run `/browser-setup doctor` to diagnose the issue in detail.

Stop here and suggest running doctor.

#### Case B: Other errors (MCP handshake timeout, daemon crash, etc.)

For any other error message, show it to the user and suggest:

> ❌ Browser connection failed: <error message>
>
> This may be a temporary issue. Please try:
> 1. Restart your browser
> 2. Run `/browser-setup` again
>
> If the problem persists, run `/browser-setup doctor` for detailed diagnostics.

### Step 4 — Get and verify browser version

Now that connection is established, get the version:

```bash
browser(action="act", kind="evaluate", js="navigator.userAgentData?.brands?.find(b => b.brand === 'Google Chrome' || b.brand === 'Microsoft Edge')?.version || navigator.userAgent.match(/Chrome\/(\d+)/)?.[1] || 'unknown'")
```

Parse the version number:
- **version >= 146** → Excellent, proceed
- **version 144-145** → Show warning but proceed:
  > ⚠️ Your browser version is v${VERSION}. Version 146+ is recommended for best compatibility.
  > Continuing anyway...
- **version < 144 or "unknown"** → Stop:
  > ❌ Browser version v${VERSION} is too old. Please upgrade Chrome or Edge to v146+ from:
  > - Chrome: https://www.google.com/chrome/
  > - Edge: https://www.microsoft.com/edge
  >
  > After upgrading, run `/browser-setup` again.

### Step 5 — Save configuration via API

Call the API to save the configuration:

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/browser/configure \
  -H "Content-Type: application/json" \
  -d "{\"chrome_version\":\"${VERSION}\"}"
```

If this fails (HTTP error or empty response), show a warning:

> ⚠️ Failed to save configuration via API. You may need to run `/browser-setup` again after restarting Clacky.

### Step 6 — Done

> ✅ Browser setup complete!
>
> **Chrome/Edge v${VERSION}** is connected and ready to use.
>
> You can now use browser automation features. Try asking me to:
> - "Open google.com in the browser"
> - "Take a screenshot"
> - "Fill out a form on this page"

---

## `doctor`

**Core Strategy**: Diagnose don't fix. Check each component and report status.

This is a **diagnostic tool**, not a repair tool. It will check each component and tell you what's wrong, but won't automatically fix things.

### Diagnostic Steps

Run all checks **before** showing results. Then show a summary report.

#### 1. Check Config File

```bash
test -f ~/.clacky/browser.yml && cat ~/.clacky/browser.yml
```

Parse the result:
- **File missing** → ❌ Not configured
- **File exists, `enabled: false`** → ⏸️ Disabled
- **File exists, `enabled: true`** → ✅ Enabled

#### 2. Check Node.js

```bash
node --version 2>/dev/null
```

- **Not found** → ❌ Node.js not installed
- **Version < 20** → ❌ Node.js too old (need 20+)
- **Version >= 20** → ✅ Node.js OK

#### 3. Check chrome-devtools-mcp

```bash
chrome-devtools-mcp --version 2>/dev/null
```

- **Not found** → ❌ Not installed
- **Found** → ✅ Installed (version: ...)

#### 4. Check Clacky Server

```bash
curl -s -f http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/browser/status
```

- **Failed** → ❌ Server not responding
- **Success** → Parse JSON and show `daemon_running` status

#### 5. Check Chrome Connection

Only run this if steps 1-4 are OK.

```bash
browser(action="status")
```

- **Success** → ✅ Connected. Also get the tab count from the result.
- **Failed** → ❌ Not connected. Parse the error message to determine cause.

#### 6. Check Chrome Version

Only run this if step 5 succeeded.

```bash
browser(action="act", kind="evaluate", js="navigator.userAgent.match(/Chrome\/(\d+)/)?.[1] || 'unknown'")
```

- **version >= 146** → ✅ Excellent
- **version 144-145** → ⚠️ Acceptable but upgrade recommended
- **version < 144 or unknown** → ❌ Too old

### Report Format

Show results in a clean table:

```
Browser Doctor — Diagnostic Report
═══════════════════════════════════════════════════════════════

Configuration
  [✅] Config file found (~/.clacky/browser.yml)
  [✅] Browser tool enabled

Dependencies
  [✅] Node.js v22.1.0
  [✅] chrome-devtools-mcp installed (v1.2.3)

Connection
  [✅] Clacky server running
  [✅] MCP daemon running
  [✅] Chrome connected (3 tabs open)
  [✅] Chrome v146

═══════════════════════════════════════════════════════════════
✅ All systems operational!
```

If there are any ❌ or ⚠️ items, show them first in a **Problems Found** section, followed by specific **Recommended Actions**:

```
Browser Doctor — Diagnostic Report
═══════════════════════════════════════════════════════════════

⚠️ Problems Found
  [❌] Chrome not connected
       Error: Chrome/Edge is not running or remote debugging is not enabled
  [❌] Chrome version v142 is too old

───────────────────────────────────────────────────────────────

Configuration
  [✅] Config file found
  [✅] Browser tool enabled

Dependencies
  [✅] Node.js v22.1.0
  [✅] chrome-devtools-mcp installed

Connection
  [✅] Clacky server running
  [❌] Chrome not connected

═══════════════════════════════════════════════════════════════

🔧 Recommended Actions

1. Enable remote debugging:
   - Open Chrome and visit: chrome://inspect/#remote-debugging
   - Click "Allow remote debugging for this browser instance"

2. Upgrade your browser:
   - Chrome v142 is too old (need v146+)
   - Download latest version: https://www.google.com/chrome/

After fixing these issues, run `/browser-setup` again to verify.
```

### Common Diagnostic Scenarios

**Scenario 1: Config not found**
```
[❌] Config file not found

🔧 Fix: Run `/browser-setup` to configure the browser tool.
```

**Scenario 2: Chrome not running**
```
[❌] Chrome not connected
     Error: Chrome/Edge is not running or remote debugging is not enabled

🔧 Fix:
  1. Open Chrome or Edge
  2. Visit: chrome://inspect/#remote-debugging
  3. Click "Allow remote debugging"
```

**Scenario 3: MCP not installed**
```
[❌] chrome-devtools-mcp not installed

🔧 Fix: Run `npm install -g chrome-devtools-mcp@latest`
      (or run `/browser-setup` to install automatically)
```

**Scenario 4: Everything OK**
```
✅ All systems operational!

The browser tool is ready to use.
```
