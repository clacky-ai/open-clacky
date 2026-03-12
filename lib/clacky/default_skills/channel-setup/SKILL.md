---
name: channel-setup
description: |
  Configure IM platform channels (Feishu, WeCom) for open-clacky.
  Uses browser automation for navigation; guides the user to paste credentials and perform UI steps.
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

## Browser Automation Principles

- **Always use built-in browser**: Pass `isolated: true` on every browser tool call. Do NOT ask the user to choose — use the built-in browser only.
- Use `open <url>` for navigation.
- AI navigates; user performs form fills, clicks, and pastes when instructed.
- If a login page or QR code appears, tell the user to log in and wait for "done" before continuing.
- If stuck (CAPTCHA, unexpected page, dialog, cannot find a UI element), **guide the user to help** — ask the user to perform the specific step manually and reply "done" when ready.

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
> 1. Feishu
> 2. WeCom (Enterprise WeChat)

---

### Feishu setup

#### Phase 1 — Open Feishu Open Platform

1. Navigate: `open https://open.feishu.cn/app`. Pass `isolated: true`.
2. Take a snapshot. If a login page or QR code is shown, tell the user to log in and wait for "done".
3. Confirm the app list is visible.

#### Phase 2 — Create a new app

6. **Always create a new app** — do NOT reuse existing apps. Guide the user: "Click 'Create Enterprise Self-Built App', fill in name (e.g. Open Clacky) and description (e.g. AI assistant powered by open-clacky), then submit. Reply done." Wait for "done".

#### Phase 3 — Enable Bot capability

7. Feishu opens Add App Capabilities by default after creating an app. Guide the user: "Find the Bot capability card and click the Add button next to it, then reply done." Wait for "done".

#### Phase 4 — Get credentials

8. Navigate to Credentials & Basic Info in the left menu.
9. Guide the user: "Copy App ID and App Secret, then paste here. Reply with: App ID: xxx, App Secret: xxx" Wait for "done".

#### Phase 5 — Add message permissions

10. Navigate to Permission Management and open the bulk import dialog.
11. Guide the user: "In the bulk import dialog, clear the existing example first (select all, delete), then paste the following JSON. Reply done." Wait for "done". Do NOT try to clear or edit via browser — user does it.

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

#### Phase 6 — Configure event subscription (Long Connection)

**CRITICAL**: Feishu requires the long connection to be established *before* you can save the event config. The platform shows "No application connection detected, ensure long connection is established before saving" until `clacky server` is running and connected. Do NOT try to save until the connection is established.

12. **Apply config and establish connection** — Run `curl -X POST http://localhost:7070/api/channels/feishu -H "Content-Type: application/json" -d '{"app_id":"...","app_secret":"...","domain":"..."}'`. The server hot-reloads the Feishu adapter and establishes the WebSocket.
13. **Wait for connection** — Wait until the log shows `[feishu-ws] WebSocket connected ✅`.
14. **Navigate to Events & Callbacks** — Then guide the user: "Select 'Long Connection' mode. Click Save. Then click Add Event, type `im.message.receive_v1` in the search box, select it, click Add. Reply done." Wait for "done".

#### Phase 7 — Publish the app

15. Navigate to Version Management & Release. Then guide the user: "Create a new version, fill in version (e.g. 1.0.0) and update description (e.g. Initial release for Open Clacky), then publish. Reply done." Wait for "done".

#### Phase 8 — Finalize config and validate

Config was applied in step 12 (via API).

Validate:
```bash
curl -s -X POST "${DOMAIN}/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json" \
  -d "{\"app_id\":\"${APP_ID}\",\"app_secret\":\"${APP_SECRET}\"}"
```
Check for `"code":0`. If it fails, explain and offer to retry.

On success: "✅ Feishu channel configured. The channel is already active."

---

### WeCom setup

1. Navigate: `open https://work.weixin.qq.com/wework_admin/frame#/aiHelper/create`. Pass `isolated: true`.
2. Take a snapshot. If a login page or QR code is shown, tell the user to log in and wait for "done".
3. Steps 3–7: Do NOT take snapshots or screenshots. Guide the user: "Scroll to the bottom of the right panel and click 'API mode creation'. Reply done." Wait for "done".
4. Guide the user: "Click 'Add' next to 'Visible Range'. In the scope dialog, select the top-level company node (or specific users/departments). Click Confirm. Reply done." Wait for "done".
5. Guide the user: "If Secret is not visible, click 'Get Secret'. Copy Bot ID and Secret **before** clicking Save — do NOT click 'Get Secret' again after copying (it invalidates the previous secret). Paste here. Reply with: Bot ID: xxx, Secret: xxx" Wait for "done".
6. Guide the user: "Click Save. In the dialog, enter name (e.g. Open Clacky) and description (e.g. AI assistant powered by open-clacky). Click Confirm. Click Save again. Reply done." Wait for "done".
7. **Apply config and hot-reload** — Parse credentials from step 5. Trim leading/trailing whitespace from bot_id and secret. Run `curl -X POST http://localhost:7070/api/channels/wecom -H "Content-Type: application/json" -d '{"bot_id":"...","secret":"..."}'`. Ensure bot_id (starts with `aib`) and secret (longer string) are not swapped.

On success: "✅ WeCom channel configured."

On success: "✅ WeCom channel configured. To use the bot: WeCom client → Contacts → select Smart Bot to see the newly created bot.".

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
