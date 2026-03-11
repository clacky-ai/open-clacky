---
name: channel-setup
description: |
  Configure IM platform channels (Feishu/Lark, WeCom) for open-clacky.
  Uses browser automation to complete setup automatically — no manual credential copying.
  Trigger on: "channel setup", "setup feishu", "setup wecom", "channel config",
  "channel status", "channel enable", "channel disable", "channel reconfigure", "channel doctor".
  Subcommands: setup, status, enable <platform>, disable <platform>, reconfigure, doctor.
argument-hint: "setup | status | enable <platform> | disable <platform> | reconfigure | doctor"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskFollowupQuestion
  - Glob
  - Browser
---

# Channel Setup Skill

Configure IM platform channels for open-clacky. Config is stored at `~/.clacky/channels.yml`.

## Core Rule: Never ask for credentials

All credentials (App Secret, Bot Secret, etc.) must be read directly from browser snapshots.
**Asking the user to copy, type, or provide any credential is a failure.**
If automation cannot reveal a value, say so and suggest retrying — never fall back to manual input.
**Exception**: For Feishu and WeCom, guide the user to paste credentials — do not take snapshots or screenshots to extract. Directly ask the user to reveal and paste.

## Browser Automation Principles

- Before opening any platform URL, detect Chrome availability and confirm the browser to use with the user.
- **CRITICAL**: When the user chooses "1. Use my Chrome", pass `isolated: false` on every browser tool call (open, snapshot, etc.). When the user chooses "2. Use built-in", pass `isolated: true`. Omitting this causes the wrong browser to be used.
- **When using the user's Chrome** (isolated=false): use `tab new <url>` instead of `open <url>` so the page opens in a new tab rather than replacing the current one.
- After every navigation, take a snapshot before interacting with the page.
- If a login page or QR code appears, tell the user to log in and wait for "done" before continuing.
- To read a hidden credential: take an interactive snapshot to find the reveal/eye button, click it, then read the now-visible value from the next snapshot.
- If stuck (CAPTCHA, unexpected page, dialog, cannot find a UI element, scroll fails), take a screenshot, describe the situation, and **guide the user to help** — do NOT fall back to alternative navigation (e.g., switching tabs, trying different URLs). Ask the user to perform the specific step manually and reply "done" when ready.
- Never print raw secrets — mask to last 4 characters in all output.

---

## Command Parsing

| User says | Subcommand |
|---|---|
| `channel setup`, `setup feishu`, `setup wecom` | setup |
| `channel status` | status |
| `channel enable feishu/wecom` | enable |
| `channel disable feishu/wecom` | disable |
| `channel reconfigure` | reconfigure |
| `channel doctor` | doctor |

---

## `status`

Read `~/.clacky/channels.yml` and display:

```
Channel Status
─────────────────────────────────────────────────────
Platform   Enabled   Details
feishu     ✅ yes    app_id: cli_xxx...  domain: feishu.cn
wecom      ❌ no     (not configured)
─────────────────────────────────────────────────────
```

If the file doesn't exist: "No channels configured yet. Run `/channel-setup setup` to get started."

---

## `setup`

Ask:
> Which platform would you like to connect?
>
> 1. Feishu / Lark
> 2. WeCom (Enterprise WeChat)

---

### Feishu setup

#### Phase 1 — Open Feishu Open Platform

1. Detect Chrome and confirm browser preference with the user. **Remember**: user chose 1 → pass `isolated: false`; chose 2 → pass `isolated: true` on every browser call.
2. Ask (if not clear from context):
   > Are you using Feishu (China) or Lark (International)?
   > 1. Feishu — https://open.feishu.cn
   > 2. Lark — https://open.larksuite.com
3. Navigate to `https://open.feishu.cn/app` (or `/larksuite.com/app`).
4. Take a snapshot. If a login page or QR code is shown, tell the user to log in and wait for "done".
5. Confirm the app list is visible.

#### Phase 2 — Create a new app

6. **Always create a new app** — do NOT reuse existing apps. Click "Create Enterprise Self-Built App", then create with name `Open Clacky` and description `AI assistant powered by open-clacky`.

#### Phase 3 — Get credentials

7. Navigate to the app's Credentials & Basic Info page.
8. Do NOT take snapshots or screenshots. Directly guide the user: "Click the eye icon next to App Secret to reveal it. Copy App ID and App Secret, then paste here. Reply with: App ID: xxx, App Secret: xxx" (confirm back masked to last 4 chars).

#### Phase 4 — Enable Bot capability

10. Navigate to Add App Capabilities in the left menu.
11. Find the Bot capability card and add it. Confirm any dialog.

#### Phase 5 — Add message permissions

12. Navigate to Permission Management and open the bulk import dialog.
13. **Clear the default/example content first** (select all, delete), then paste the following JSON:

```json
{
  "scopes": {
    "tenant": [
      "im:message",
      "im:message.p2p_msg:readonly",
      "im:message:send_as_bot"
    ],
    "user": []
  }
}
```

14. Confirm all three permissions appear as enabled.

#### Phase 6 — Configure event subscription

15. Navigate to Events & Callbacks.
16. Change the subscription method to **Long Connection** and save.
17. Add the event `im.message.receive_v1`.

#### Phase 7 — Publish the app

18. Navigate to Version Management & Release, create a new version (e.g. `1.0.0`), and publish.
19. Note: personal accounts publish immediately; enterprise accounts require admin approval — tell the user if this applies.

#### Phase 8 — Allowed users (optional)

20. Ask:
    > Do you want to restrict which Feishu users can send tasks to the AI?
    > Reply "skip" to allow everyone, or "yes" to configure a whitelist.
21. If "yes":
    - Tell the user to send any message to the Open Clacky bot in Feishu, then reply "done".
    - Navigate to Log Search → Event Log, find the latest `im.message.receive_v1` event, and read `sender.sender_id.open_id` (format `ou_xxx`) directly from the page.
    - Repeat for additional users if needed.

#### Phase 9 — Save config and validate

Write `~/.clacky/channels.yml` (merge with existing content, never overwrite other platforms):

```yaml
channels:
  feishu:
    enabled: true
    app_id: <from user paste>
    app_secret: <from user paste>
    domain: https://open.feishu.cn   # or https://open.larksuite.com
    # allowed_users:                 # omit if not configured
    #   - ou_xxx
```

Run `chmod 600 ~/.clacky/channels.yml`.

Validate:
```bash
curl -s -X POST "${DOMAIN}/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json" \
  -d "{\"app_id\":\"${APP_ID}\",\"app_secret\":\"${APP_SECRET}\"}"
```
Check for `"code":0`. If it fails, explain and offer to retry.

On success: "✅ Feishu channel configured. Restart `clacky server` to activate."

---

### WeCom setup

First ask: "Are you an admin of your WeCom enterprise (can log in to work.weixin.qq.com)? Reply 1 or 2."
- If using AskFollowupQuestion: pass options as `Yes — I am an enterprise admin` and `No — I am not an admin` (no leading numbers; the tool will add 1. and 2.).
- **1** → use Admin Console flow (browser automation).
- **2** → use Client flow (guide user in WeCom desktop client, then ask for Bot ID and Secret).

---

#### Admin Console flow (user has admin access)

**Principle**: Do NOT take snapshots or screenshots to inspect the UI. Directly guide the user through each step. For Bot ID and Secret, guide the user to paste them — do NOT try to extract from the page.

1. Detect Chrome and confirm browser preference with the user (if not already done). **Remember**: user chose 1 → pass `isolated: false` when calling browser; chose 2 → pass `isolated: true`.
2. Navigate directly to `https://work.weixin.qq.com/wework_admin/frame#/aiHelper/create` (use `tab new <url>` when isolated=false). Pass the same `isolated` value on every browser call.
3. Directly guide the user: "If you see a login page or QR code, log in. When the create page is visible, reply done." Wait for "done".
4. Guide the user: "Scroll to the bottom of the right panel and click 'API mode creation', then reply done." Wait for "done".
5. Guide the user: "In the scope dialog, select the top-level company node to allow all members, or select specific users/departments if you prefer. Click Confirm, then reply done." Wait for "done".
6. Guide the user: "If the Secret is not yet visible, click 'Get Secret'. When both Bot ID and Secret are visible, copy them and paste here. Reply with: Bot ID: xxx, Secret: xxx" (confirm back masked to last 4 chars).
7. Guide the user: "Click Save. In the dialog, enter name 'Open Clacky' and description 'AI assistant powered by open-clacky', click Confirm, then reply done." Wait for "done".
8. Write config and run `chmod 600 ~/.clacky/channels.yml`.

---

#### Client flow (user is not admin; cannot access admin console)

Guide the user to operate in the **WeCom desktop client** (Workbench). No browser automation needed.

1. Guide the user: "Open the WeCom desktop client → Workbench → Smart Bot → "Create Bot". Reply done when you see the creation page." Wait for "done".
2. Guide the user: "Scroll to the bottom of the page and click 'API Mode'. Reply done." Wait for "done".
3. Guide the user: "The Bot ID appears on the right side. Under 'API Configuration', find the Secret row and click 'Click to Reveal' if needed. Copy both and paste here. Reply with: Bot ID: xxx, Secret: xxx" (confirm back masked to last 4 chars).
4. Guide the user: "Fill in name 'Open Clacky' and description 'AI assistant powered by open-clacky', click Save (or Confirm), then reply done." Wait for "done".
5. Write `~/.clacky/channels.yml` and run `chmod 600 ~/.clacky/channels.yml`.

---

#### Save config (both flows)

```yaml
channels:
  wecom:
    enabled: true
    bot_id: <extracted or entered>
    secret: <extracted or entered>
```

On success: "✅ WeCom channel configured. Restart `clacky server` to activate. To use the bot: WeCom client → Workbench → Management → click the bot details → Go to use."

---

## `enable`

Read `~/.clacky/channels.yml`, set `channels.<platform>.enabled: true`, write back.

If the platform has no credentials, redirect to `setup`.

Say: "✅ `<platform>` channel enabled. Restart `clacky server` to activate."

---

## `disable`

Read `~/.clacky/channels.yml`, set `channels.<platform>.enabled: false`, write back.

Say: "❌ `<platform>` channel disabled. Restart `clacky server` to deactivate."

---

## `reconfigure`

1. Show current config (mask secrets).
2. Ask: update credentials / change allowed users / add a new platform / enable or disable a platform.
3. For credential updates, re-run the relevant setup flow (Admin Console or Client flow for WeCom).
4. Write atomically: write to `~/.clacky/channels.yml.tmp` then rename to `~/.clacky/channels.yml`.
5. Say: "Restart `clacky server` to apply changes."

---

## `doctor`

Check each item, report ✅ / ❌ with remediation:

1. **Config file** — does `~/.clacky/channels.yml` exist and is it readable?
2. **Permissions** — `stat ~/.clacky/channels.yml`, warn if not 600.
3. **Required keys** — for each enabled platform:
   - Feishu: `app_id`, `app_secret` present and non-empty
   - WeCom: `bot_id`, `secret` present and non-empty
4. **Feishu credentials** (if enabled) — run the token API call, check `code=0`.
5. **WeCom** — no REST check (verified at connect), just confirm keys are present.
6. **Server running** — `pgrep -f "clacky server"`. Channels only activate when the server is running.

---

## Security

- Always mask secrets in output (last 4 chars only).
- Config file must be `chmod 600`.
