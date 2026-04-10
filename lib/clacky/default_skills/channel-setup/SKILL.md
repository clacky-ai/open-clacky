---
name: channel-setup
description: |
  Configure IM platform channels (Feishu, WeCom, Weixin) for openclacky.
  Uses browser automation for navigation; guides the user to paste credentials and perform UI steps.
  Trigger on: "channel setup", "setup feishu", "setup wecom", "setup weixin", "setup wechat", "channel config",
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

Configure IM platform channels for openclacky.

---

## Command Parsing

| User says | Subcommand |
|---|---|
| `channel setup`, `setup feishu`, `setup wecom`, `setup weixin`, `setup wechat` | setup |
| `channel status` | status |
| `channel enable feishu/wecom/weixin` | enable |
| `channel disable feishu/wecom/weixin` | disable |
| `channel reconfigure` | reconfigure |
| `channel doctor` | doctor |

---

## `status`

Call the server API:

```bash
curl -s http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels
```

Response shape (example):
```json
{"channels":[
  {"platform":"feishu","enabled":true,"running":true,"has_config":true,"app_id":"cli_xxx","domain":"https://open.feishu.cn","allowed_users":[]},
  {"platform":"wecom","enabled":false,"running":false,"has_config":false,"bot_id":""},
  {"platform":"weixin","enabled":true,"running":true,"has_config":true,"has_token":true,"base_url":"https://ilinkai.weixin.qq.com","allowed_users":[]}
]}
```

Display the result:

```
Channel Status
─────────────────────────────────────────────────────
Platform   Enabled   Running   Details
feishu     ✅ yes    ✅ yes    app_id: cli_xxx...
wecom      ❌ no     ❌ no     (not configured)
weixin     ✅ yes    ✅ yes    has_token: true
─────────────────────────────────────────────────────
```

- Feishu: show `app_id` (truncated to 12 chars)
- WeCom: show `bot_id` if present
- Weixin: show `has_token: true/false` (token value is never displayed)

If the API is unreachable or returns an empty list: "No channels configured yet. Run `/channel-setup setup` to get started."

---

## `setup`

Ask:
> Which platform would you like to connect?
>
> 1. Feishu
> 2. WeCom (Enterprise WeChat)
> 3. Weixin (Personal WeChat via iLink QR login)

---

### Feishu setup

#### Step 1 — Try automated setup (script)

Run the setup script (full path is available in the supporting files list above):
```bash
ruby "SKILL_DIR/feishu_setup.rb"
```
**Important**: call `safe_shell` with `timeout: 180` — the script may wait up to 90s for a WebSocket connection in Phase 4.

**If exit code is 0:**
- The script completed successfully.
- Config is already written to `~/.clacky/channels.yml`.
- Tell the user: "✅ Feishu channel configured automatically! The channel is ready."
- **Stop here — do not proceed to manual steps.**

**If exit code is non-0:**
- Check stdout for the error message.
- **If the error contains "Browser not configured" or "browser tool":**
  - Tell the user: "The browser tool is not configured yet. Let me help you set it up first..."
  - Invoke the `browser-setup` skill: `invoke_skill("browser-setup", "setup")`.
  - After browser-setup completes, tell the user: "Browser is ready! Let me retry the Feishu setup..."
  - **Retry the script** (same command, same timeout). If it succeeds this time, stop. If it fails again, check the new error and proceed accordingly.
- **If the error contains "No cookies found" or "Please log in":**
  - Open Feishu login page using browser tool:
    ```
    browser(action="navigate", url="https://open.feishu.cn/app")
    ```
  - Tell the user: "I've opened Feishu in your browser. Please log in, then reply 'done'."
  - Wait for "done".
  - **Retry the script** (same command, same timeout). If it succeeds this time, stop. If it fails again with a different error, continue to Step 2.
- **Otherwise (non-login, non-browser error):**
  - Tell the user: "Automated setup encountered an issue: `<error message>`. Switching to guided setup..."
  - Continue to Step 2 (manual flow) below.

---

#### Step 2 — Manual guided setup (fallback)

Only reach here if the automated script failed.

##### Phase 1 — Open Feishu Open Platform

1. Navigate: `open https://open.feishu.cn/app`. Pass `isolated: true`.
2. If a login page or QR code is shown, tell the user to log in and wait for "done".
3. Confirm the app list is visible.

##### Phase 2 — Create a new app

4. **Always create a new app** — do NOT reuse existing apps. Guide the user: "Click 'Create Enterprise Self-Built App', fill in name (e.g. Open Clacky) and description (e.g. AI assistant powered by openclacky), then submit. Reply done." Wait for "done".

##### Phase 3 — Enable Bot capability

5. Feishu opens Add App Capabilities by default after creating an app. Guide the user: "Find the Bot capability card and click the Add button next to it, then reply done." Wait for "done".

##### Phase 4 — Get credentials

6. Navigate to Credentials & Basic Info in the left menu.
7. Guide the user: "Copy App ID and App Secret, then paste here. Reply with: App ID: xxx, App Secret: xxx" Wait for the reply. Parse `app_id` and `app_secret`.

##### Phase 5 — Add message permissions

8. Navigate to Permission Management and open the bulk import dialog.
9. Guide the user: "In the bulk import dialog, clear the existing example first (select all, delete), then paste the following JSON. Reply done." Wait for "done". Do NOT try to clear or edit via browser — user does it.

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

##### Phase 6 — Configure event subscription (Long Connection)

**CRITICAL**: Feishu requires the long connection to be established *before* you can save the event config. The platform shows "No application connection detected" until `clacky server` is running and connected.

10. **Apply config and establish connection** — Run:
    ```bash
    curl -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels/feishu \
      -H "Content-Type: application/json" \
      -d '{"app_id":"<APP_ID>","app_secret":"<APP_SECRET>","domain":"https://open.feishu.cn"}'
    ```
    **CRITICAL: This curl call is the ONLY way to save credentials. NEVER write `~/.clacky/channels.yml` or any file under `~/.clacky/channels/` directly. The server API handles persistence and hot-reload.**
11. **Wait for connection** — Poll until log shows `[feishu-ws] WebSocket connected ✅`:
    ```bash
    for i in $(seq 1 20); do
      grep -q "\[feishu-ws\] WebSocket connected" ~/.clacky/logger/clacky-$(date +%Y-%m-%d).log 2>/dev/null && echo "CONNECTED" && break
      sleep 1
    done
    ```
12. **Configure events** — Guide the user: "In Events & Callbacks, select 'Long Connection' mode. Click Save. Then click Add Event, search `im.message.receive_v1`, select it, click Add. Reply done." Wait for "done".

##### Phase 7 — Publish the app

13. Navigate to Version Management & Release. Guide the user: "Create a new version (e.g. 1.0.0, note: Initial release for Open Clacky) and publish it. Reply done." Wait for "done".

##### Phase 8 — Validate

```bash
curl -s -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json" \
  -d '{"app_id":"<APP_ID>","app_secret":"<APP_SECRET>"}'
```

Check for `"code":0`. On success: "✅ Feishu channel configured."

---

### WeCom setup

1. Navigate: `open https://work.weixin.qq.com/wework_admin/frame#/aiHelper/create`. Pass `isolated: true`.
2. If a login page or QR code is shown, tell the user to log in and wait for "done".
3. Guide the user: "Scroll to the bottom of the right panel and click 'API mode creation'. Reply done." Wait for "done".
4. Guide the user: "Click 'Add' next to 'Visible Range'. Select the top-level company node. Click Confirm. Reply done." Wait for "done".
5. Guide the user: "If Secret is not visible, click 'Get Secret'. Copy Bot ID and Secret **before** clicking Save. Paste here. Reply with: Bot ID: xxx, Secret: xxx" Wait for "done".
6. Guide the user: "Click Save. Enter name (e.g. Open Clacky) and description. Click Confirm. Click Save again. Reply done." Wait for "done".
7. Parse credentials. Trim whitespace. Ensure bot_id (starts with `aib`) and secret are not swapped. Run:
   ```bash
   curl -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels/wecom \
     -H "Content-Type: application/json" \
     -d '{"bot_id":"<BOT_ID>","secret":"<SECRET>"}'
   ```

On success: "✅ WeCom channel configured. WeCom client → Contacts → Smart Bot to find it."

---

### Weixin setup (Personal WeChat via iLink QR login)

Weixin uses a QR code login — no app_id/app_secret needed. The token from the QR scan is saved directly in `channels.yml`.

#### Step 1 — Fetch QR code

Run the script in `--fetch-qr` mode to get the QR URL without blocking:

```bash
QR_JSON=$(ruby "SKILL_DIR/weixin_setup.rb" --fetch-qr 2>/dev/null)
echo "$QR_JSON"
```

Parse the JSON output:
- `qrcode_url` — the URL to open in browser (this IS the QR code content)
- `qrcode_id`  — the session ID needed for polling

If the output contains `"error"`, show it and stop.

#### Step 2 — Show QR code to user (browser or manual fallback)

Build the local QR page URL (include current Unix timestamp as `since` to detect new logins only):
```
http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/weixin-qr.html?url=<URL-encoded qrcode_url>&since=<current_unix_timestamp>
```

**Try browser first** — attempt to open the QR page using the browser tool:
```
browser(action="navigate", url="<qr_page_url>")
```

**If browser succeeds:** Tell the user:
> I've opened the WeChat QR code in your browser. Please scan it with WeChat, then confirm in the app.

**If browser fails (not configured or unavailable):** Fall back to manual — tell the user:
> Please open the following link in your browser to scan the WeChat QR code:
>
> `http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/weixin-qr.html?url=<URL-encoded qrcode_url>`
>
> Scan the QR code with WeChat, confirm in the app, then reply "done".

The page renders a proper scannable QR code image. Do NOT open the raw `qrcode_url` directly — that page shows "请使用微信扫码打开" with no actual QR image.

#### Step 3 — Wait for scan and save credentials

Once the browser shows the QR page, immediately run the polling script in the background:

```bash
ruby "SKILL_DIR/weixin_setup.rb" --qrcode-id "$QRCODE_ID"
```

Where `$QRCODE_ID` is the `qrcode_id` from Step 2's JSON output.

Run this command with `timeout: 60`. If it doesn't succeed, **retry up to 3 times with the same `$QRCODE_ID`** — the QR code stays valid for 5 minutes. Only stop retrying if:
- Exit code is 0 → success
- Output contains "expired" → QR expired, offer to restart from Step 1
- Output contains "timed out" → offer to restart from Step 1
- 3 retries exhausted → show error and offer to restart from Step 1

Tell the user while waiting:
> Waiting for you to scan the QR code and confirm in WeChat... (this may take a moment)

**If exit code is 0:** "✅ Weixin channel configured! You can now message your bot on WeChat."

**If exit code is non-0 or times out:** Show the error and offer to retry from Step 2.

---

## `enable`

Call the server API to re-enable the platform (this reads from disk, sets enabled, saves, and hot-reloads):

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels/<platform> \
  -H "Content-Type: application/json" \
  -d '{"enabled": true}'
```

If the platform has no credentials (404 or error), redirect to `setup`.

Say: "✅ `<platform>` channel enabled."

---

## `disable`

Call the server API to disable the platform:

```bash
curl -s -X DELETE http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels/<platform>
```

Say: "❌ `<platform>` channel disabled."

---

## `reconfigure`

1. Show current config via `GET /api/channels` (mask secrets — show last 4 chars only).
2. Ask: update credentials / change allowed users / add a new platform / enable or disable a platform.
3. For credential updates, re-run the relevant setup flow (which calls `POST /api/channels/<platform>`).
4. **NEVER write `~/.clacky/channels.yml` directly** — always use the server API.
5. Say: "Channel reconfigured."

---

## `doctor`

Check each item, report ✅ / ❌ with remediation:

1. **Config file** — does `~/.clacky/channels.yml` exist and is it readable?
2. **Required keys** — for each enabled platform:
   - Feishu: `app_id`, `app_secret` present and non-empty
   - WeCom: `bot_id`, `secret` present and non-empty
   - Weixin: `token` present and non-empty in `channels.yml`
3. **Feishu credentials** (if enabled) — run the token API call, check `code=0`.
4. **Weixin token** (if enabled) — call `GET /api/channels` and check `has_token: true` for the weixin entry.
5. **WeCom credentials** (if enabled) — search today's log:
   ```bash
   grep -iE "wecom adapter loop started|WeCom authentication failed|WeCom WS error response|WecomAdapter" \
     ~/.clacky/logger/clacky-$(date +%Y-%m-%d).log
   ```
   - `WeCom authentication failed` or non-zero errcode → ❌ "WeCom credentials incorrect"
   - `adapter loop started` with no auth error → ✅

---

## Security

- Always mask secrets in output (last 4 chars only).
- Config file must be `chmod 600`.
