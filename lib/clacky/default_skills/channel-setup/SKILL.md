---
name: channel-setup
description: |
  Configure IM platform channels (Feishu/Lark, WeCom) for open-clacky.
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
---

# Channel Setup Skill

You are configuring IM platform channels for open-clacky.

Config is stored at `~/.clacky/channels.yml`.

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

Interactive wizard — one question at a time, confirm each answer before moving on.

**Step 1 — Choose platform**

Ask:
> Which platform would you like to connect?
>
> 1. Feishu / Lark
> 2. WeCom (Enterprise WeChat)

---

### Feishu setup

**2a. App ID**

Ask with inline instructions:

> **How to get your App ID:**
> 1. Open https://open.feishu.cn/app (Lark: https://open.larksuite.com/app)
> 2. Click an existing app, or click **"Create Enterprise Self-Built App"**
> 3. Go to **Credentials & Basic Info** in the left menu
> 4. Copy the **App ID** (format: `cli_xxxxxxxxxx`)
>
> Enter your App ID:

**2b. App Secret**

Ask:
> On the same page, click the eye icon next to **App Secret** to reveal it.
>
> Enter your App Secret:

Confirm back (mask to last 4 chars).

**2c. Complete app configuration**

Tell the user to finish these steps in Feishu Open Platform, then reply "done":

> Please complete these steps in your Feishu app, then reply "done":
>
> **A — Enable Bot capability**
> - Left menu → "Add App Capabilities" → find "Bot" → "+ Add"
>
> **B — Add permissions**
> - Left menu → "Permission Management" → "Enable Permissions" → "Messages & Groups"
> - Enable: `im:message`, `im:message:send_as_bot`, `im:message.p2p_msg:readonly`
>
> **C — Event subscription**
> - Left menu → "Events & Callbacks" → click pencil next to "Subscription Method" → select "Long Connection" → save
> - Click "Add Event" → add `im.message.receive_v1`
>
> **D — Publish the app**
> - Left menu → "Version Management & Release" → "Create Version" → fill version number → Save → Publish
> - Personal accounts: takes effect immediately. Enterprise accounts: requires admin approval.

**2d. Domain**

Ask:
> Which version are you using?
>
> 1. Feishu (China) — open.feishu.cn
> 2. Lark (International) — open.larksuite.com

**2e. Allowed User IDs (optional)**

Ask:
> You can restrict which users can trigger the AI. To find your Open ID:
> 1. After publishing, open the Feishu app — you'll get a notification from Developer Assistant, click "Open App"
> 2. Send any message to the bot (e.g. "hello")
> 3. In Feishu Open Platform → your app → "Log Search" → "Event Log"
> 4. Find `im.message.receive_v1` → expand → copy `sender.sender_id.open_id` (format: `ou_xxx...`)
>
> Enter allowed Open IDs (comma-separated), or "skip" to allow all users:

**Step 3 — Confirm and save**

Show a summary table (mask secrets), ask user to type "confirm" to save.

Write `~/.clacky/channels.yml` and run `chmod 600 ~/.clacky/channels.yml`.

Validate credentials:
```bash
curl -s -X POST "${DOMAIN}/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json" \
  -d "{\"app_id\":\"${APP_ID}\",\"app_secret\":\"${APP_SECRET}\"}"
```
Check for `"code":0`. If it fails, explain and offer to re-enter.

On success: "✅ Feishu channel configured! Restart `clacky server` to activate."

Config format:
```yaml
channels:
  feishu:
    enabled: true
    app_id: cli_xxx
    app_secret: xxx
    domain: https://open.feishu.cn
    allowed_users:
      - ou_xxx
```

Omit `allowed_users` if skipped.

---

### WeCom setup

**2a. Bot ID**

Ask:
> **How to create a WeCom API bot:**
> 1. WeCom client → Workbench → Smart Bot → "Create Bot"
> 2. Scroll to the bottom → click "API Mode"
> 3. Select "Long Connection", fill in name & description → confirm
> 4. The **Bot ID** appears on the right side of the page — copy it
>
> Enter your Bot ID:

**2b. Secret**

Ask:
> On the same page under "API Configuration", find the **Secret** row → "Click to Reveal" → copy.
>
> Enter your Secret:

Confirm back (mask to last 4 chars).

**Step 3 — Confirm and save**

Show summary, ask "confirm" to save.

Write `~/.clacky/channels.yml` and run `chmod 600 ~/.clacky/channels.yml`.

On success: "✅ WeCom channel configured! Restart `clacky server` to activate."

Config format:
```yaml
channels:
  wecom:
    enabled: true
    bot_id: xxx
    secret: xxx
```

---

## `enable`

Read `~/.clacky/channels.yml`, set `channels.<platform>.enabled: true`, write back.

If the platform has no credentials, redirect to `setup`.

Say: "✅ `<platform>` channel enabled. Restart `clacky server` to activate."

---

## `disable`

Read `~/.clacky/channels.yml`, set `channels.<platform>.enabled: false`, write back.

Say: "✅ `<platform>` channel disabled. Restart `clacky server` to deactivate."

---

## `reconfigure`

1. Show current config (mask secrets)
2. Offer options: update credentials / change allowed users / add a new platform / enable or disable a platform
3. Collect new values using the same step-by-step flow as `setup`
4. Write atomically: write to `~/.clacky/channels.yml.tmp` then `mv` to `~/.clacky/channels.yml`
5. Say: "Restart `clacky server` to apply changes."

---

## `doctor`

Check each item, report ✅ / ❌ with remediation:

1. **Config file** — does `~/.clacky/channels.yml` exist and is it readable?
2. **Permissions** — `stat ~/.clacky/channels.yml`, warn if not 600
3. **Required keys** — for each enabled platform:
   - Feishu: `app_id`, `app_secret` present and non-empty
   - WeCom: `bot_id`, `secret` present and non-empty
4. **Feishu credentials** (if enabled) — run the token API call, check `code=0`
5. **WeCom** — no REST check (verified at connect), just confirm keys are present
6. **Server running** — `pgrep -f "clacky server"`. Channels are active when the server is running.

---

## Security

- Always mask secrets in output (last 4 chars only)
- Config file should be `chmod 600`
