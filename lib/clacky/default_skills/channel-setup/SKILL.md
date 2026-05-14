---
name: channel-setup
description: |
  Configure IM platform channels (Feishu, WeCom, Weixin, Discord, Telegram, DingTalk) for openclacky.
  Uses browser automation for navigation; guides the user to paste credentials and perform UI steps.
  Trigger on: "channel setup", "setup feishu", "setup wecom", "setup weixin", "setup wechat", "setup discord", "setup telegram", "setup dingtalk",
  "channel config", "channel status", "channel enable", "channel disable", "channel reconfigure", "channel doctor",
  "send message to weixin", "send message to feishu", "send message to wecom", "send message to discord", "send message to telegram", "send message to dingtalk".
  Subcommands: setup, status, enable <platform>, disable <platform>, reconfigure, doctor, send.
argument-hint: "setup | status | enable <platform> | disable <platform> | reconfigure | doctor | send <platform> <message>"
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
| `channel setup`, `setup feishu`, `setup wecom`, `setup weixin`, `setup wechat`, `setup discord`, `setup telegram`, `setup dingtalk` | setup |
| `channel status` | status |
| `channel enable feishu/wecom/weixin/discord/telegram/dingtalk` | enable |
| `channel disable feishu/wecom/weixin/discord/telegram/dingtalk` | disable |
| `channel reconfigure` | reconfigure |
| `channel doctor` | doctor |
| `send <message> to weixin/feishu/wecom/discord/telegram/dingtalk` | send |

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
  {"platform":"weixin","enabled":true,"running":true,"has_config":true,"has_token":true,"base_url":"https://ilinkai.weixin.qq.com","allowed_users":[]},
  {"platform":"discord","enabled":true,"running":true,"has_config":true,"has_token":true,"allowed_users":[]}
  {"platform":"telegram","enabled":true,"running":true,"has_config":true,"has_token":true,"base_url":"https://api.telegram.org","parse_mode":"Markdown","allowed_users":[]}
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
discord    ✅ yes    ✅ yes    has_token: true
telegram   ✅ yes    ✅ yes    has_token: true
dingtalk   ✅ yes    ✅ yes    client_id: ding_xxx...
─────────────────────────────────────────────────────
```

- Feishu: show `app_id` (truncated to 12 chars)
- WeCom: show `bot_id` if present
- Weixin: show `has_token: true/false` (token value is never displayed)
- Discord: show `has_token: true/false` (token value is never displayed)
- Telegram: show `has_token: true/false` (bot token is never displayed)
- DingTalk: show `client_id` (truncated to 12 chars)

If the API is unreachable or returns an empty list: "No channels configured yet. Run `/channel-setup setup` to get started."

---

## `setup`

Ask:
> Which platform would you like to connect?
>
> 1. Feishu
> 2. WeCom (Enterprise WeChat)
> 3. Weixin (Personal WeChat via iLink QR login)
> 4. Discord
> 5. Telegram (Bot API)
> 6. DingTalk

---

### Feishu setup

#### Step 1 — Try automated setup (script)

Run the setup script (full path is available in the supporting files list above):
```bash
ruby "SKILL_DIR/feishu_setup.rb"
```
**Important**: call `terminal` with `timeout: 180` — the script may wait up to 90s for a WebSocket connection in Phase 4.

**If exit code is 0:**
- The script completed successfully.
- Config is already written to `~/.clacky/channels.yml`.
- Tell the user: "✅ Feishu channel configured automatically! The channel is ready."
- **Skip Step 2 (manual fallback) and continue to Step 3.**

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
  - **Retry the script** (same command, same timeout). Repeat this login-wait-retry loop up to **3 times total**.
    - If any attempt succeeds (exit code 0), stop — setup is complete.
    - If an attempt fails with a **different** error (not a login error), break out of the loop and continue to Step 2.
    - If all 3 attempts fail with login errors, tell the user: "Automated setup was unable to detect a Feishu login after 3 attempts. Switching to guided setup..." and continue to Step 2.
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

Check for `"code":0`. On success: continue to Step 3 (below).

##### Phase 9 — done

Step 2 ends here. **Continue to Step 3.**

---

#### Step 3 — Optional: install Feishu CLI

Reach here from either Step 1 success or end of Step 2. Read `app_id` and `app_secret` from `~/.clacky/channels.yml` (under `channels.feishu`) for the install commands below.

Call `request_user_feedback`:

zh:
```json
{
  "question": "是否要安装「飞书 CLI」？装好之后 AI 可以帮你操作飞书云文档、电子表格、多维表格、知识库、日历、任务等几乎全部飞书能力，不只是聊天，而是能\"做事\"。不装也 OK。",
  "options": ["启用", "跳过"]
}
```

en:
```json
{
  "question": "Install Feishu CLI? With it, the AI can operate Feishu Docs, Sheets, Bitable, Wiki, Calendar, Tasks and almost every Feishu capability — not just chat, but actually get things done. Skipping is fine.",
  "options": ["Enable", "Skip"]
}
```

If the user picks Skip, stop — setup is complete.

If the user picks Enable, run:

```bash
lark-cli --version > /dev/null 2>&1 || npm install -g @larksuite/cli
echo -n "<APP_SECRET>" | lark-cli config init --app-id <APP_ID> --app-secret-stdin --brand feishu
npx -y skills add larksuite/cli -y -g
ruby "SKILL_DIR/import_lark_skills.rb"
lark-cli auth login --recommend
```

The last command blocks up to 10 minutes waiting for browser authorization — make sure the runner's timeout is ≥ 600s.

Once you see the authorization URL in the command's stdout, tell the user (do **not** wait for a reply — the CLI's blocking poll will return on its own when authorization completes):
- zh: "请在浏览器中打开下方链接完成授权：\n<URL>"
- en: "Open this URL in your browser to authorize:\n<URL>"

**Do not kill and restart this command** — restarting invalidates the device code and breaks the link the user already opened. The "hang" is just polling; wait it out.

When `lark-cli auth login` returns successfully, tell the user:
- zh: "✅ 飞书 CLI 已就绪。"
- en: "✅ Feishu CLI is ready."

**Stop — setup is fully complete.**

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

### Discord setup

Discord requires manual portal interaction (hCaptcha gates Application creation). The browser just navigates the user to the portal; the user clicks through and pastes the bot token + app id back.

#### Step 1 — Open the developer portal

Get the portal URL from the script and open it in the browser:

```bash
PORTAL_URL=$(ruby "SKILL_DIR/discord_setup.rb" --portal-url)
```

Open it: `browser(action="navigate", url="<PORTAL_URL>")`. If the browser tool is not configured, invoke `browser-setup` first, then retry.

#### Step 2 — Guide the user through the portal (one round-trip)

Tell the user **all** of the following in a single message, then call `request_user_feedback` to collect the values in one reply:

> In the Discord Developer Portal I just opened:
>
> 1. Click **New Application** (top-right). Name it whatever you like (e.g. "Open Clacky"), check the ToS box, click **Create**.
> 2. In the left nav click **Bot**.
> 3. Scroll down to **Privileged Gateway Intents** and turn on **MESSAGE CONTENT INTENT**, then click **Save Changes**.
> 4. Scroll up, click **Reset Token** → **Yes, do it!**. Click **Copy** to copy the bot token. (This is the only time the token is shown — don't navigate away before copying.)
> 5. In the left nav click **General Information**. Copy the **Application ID**.
>
> Paste both values back here in this format (one line):
>
> `token=YOUR_BOT_TOKEN app_id=YOUR_APPLICATION_ID`

If the user is chatting in a non-English language, append the localized label in parens after each bolded English button name (e.g. `**Bot**（机器人）`). The English label stays primary — it's what they physically click in the portal.

Use `request_user_feedback` to collect the reply. Parse with tolerant regex (`token=\S+`, `app_id=\d+`).

If the reply is malformed (missing either field), apologise briefly and ask again with the exact same format reminder. Up to 3 retries; after that, surface the original message and stop.

#### Step 3 — Validate, save, invite, wait

1. Validate the token and save credentials:
   ```bash
   ruby "SKILL_DIR/discord_setup.rb" --validate "<BOT_TOKEN>"
   ```
   On success the script prints `{"bot_id":"...","username":"..."}` and the adapter starts.

2. Generate the invite URL using the application id from Step 2:
   ```bash
   ruby "SKILL_DIR/discord_setup.rb" --invite-url "<APP_ID>"
   ```
   Open it: `browser(action="navigate", url="<INVITE_URL>")`. Tell the user:
   > Pick your server from the dropdown → **Continue** → **Authorize**. I'll detect when the bot joins.
   >
   > If the dropdown is empty, you don't have a server yet — open <https://discord.com/channels/@me>, click **Add a Server** (the **+** button on the left sidebar) → **Create My Own** → **For me and my friends** → name it → **Create**, then re-open the invite link.

3. Wait for the bot to join a guild (long-poll, 10 min timeout). Run with `timeout: 620`:
   ```bash
   ruby "SKILL_DIR/discord_setup.rb" --watch-guild
   ```
   On exit 0: "✅ Discord channel configured! Bot is in `<guild_name>`. Mention it or DM it from any channel."
   On timeout: offer to re-open the invite URL — the bot token stays valid.

### Telegram setup (Bot API)

Telegram setup is by far the simplest — no browser automation, no QR. The user creates a bot via @BotFather and pastes the token here.

#### Step 1 — Create a bot via @BotFather

Tell the user:

> Open Telegram and start a chat with **@BotFather** (https://t.me/BotFather). Send `/newbot`, choose a display name and a username ending in `bot`. BotFather will reply with an HTTP API token that looks like `123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ`. Paste the token here.
>
> Optional: if your network blocks `api.telegram.org`, also tell me the base URL of your self-hosted Bot API server (e.g. `https://my-tg-proxy.example.com`). Otherwise leave it blank.

Wait for the user's reply. Parse the token (matches `^\d+:[\w-]{30,}$`).

#### Step 2 — Save credentials and validate

Call the server API. It calls `getMe` against the Bot API to validate the token before persisting:

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels/telegram \
  -H "Content-Type: application/json" \
  -d '{"bot_token":"<TOKEN>","base_url":"<BASE_URL_OR_OMIT>"}'
```

- `200 { "ok": true }` — token validated and saved. The adapter starts long-polling immediately.
- `422 { "ok": false, "error": "..." }` — show the error (commonly "Unauthorized" → wrong token) and offer to retry.

On success:

> ✅ Telegram channel configured. Open your bot in Telegram and send any message to start chatting.
> 
> **For group chats**: You must disable Privacy Mode in @BotFather first (`/mybots → Bot Settings → Group Privacy → Turn off`), then remove and re-add the bot to the group. Otherwise the bot cannot receive any messages — including @-mentions.

#### Notes

- **Group chats — Privacy Mode (IMPORTANT)**: By default Telegram enables Privacy Mode for all bots, which means the bot **cannot receive any group messages, including @-mentions**. To use the bot in a group you MUST disable Privacy Mode first:
  1. Open @BotFather → `/mybots` → select your bot → `Bot Settings` → `Group Privacy` → **Turn off**
  2. **Remove the bot from the group and re-add it** — the permission change does not apply to groups the bot is already in.
  After that, the bot will respond whenever it is @-mentioned or directly replied to.
- **Self-hosted Bot API**: set `base_url` when `api.telegram.org` is unreachable. See https://github.com/tdlib/telegram-bot-api for the official self-hosted server.
- **`allowed_users`**: restrict which Telegram user IDs the bot will respond to. Find a user's numeric ID by messaging @userinfobot.

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

### DingTalk setup

#### Step 1 — Get QR code

```bash
ruby "SKILL_DIR/dingtalk_setup.rb" --print-qr
```

Parse the last line starting with `{` to get `qr_url` and `device_code`. On non-0 exit, show the error and abort.

#### Step 2 — Show QR and wait

Show `qr_url` to the user, ask them to scan with the DingTalk mobile app and tap "Create New Robot", then call `request_user_feedback`.

#### Step 3 — Poll for authorization

```bash
ruby "SKILL_DIR/dingtalk_setup.rb" --poll "<device_code>"
```

- **0** → "✅ DingTalk channel configured! Find your robot in DingTalk and send it a message." Stop.
- **2** → not scanned yet. Ask user to confirm, then re-poll. If output contains `WAITING_TIMEOUT` or `expired`, restart from Step 1.
- **1** → show the error and abort.

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
   - Discord: `bot_token` present and non-empty in `channels.yml`
   - Telegram: `bot_token` present and non-empty
3. **Feishu credentials** (if enabled) — run the token API call, check `code=0`.
4. **Weixin token** (if enabled) — call `GET /api/channels` and check `has_token: true` for the weixin entry.
5. **Telegram credentials** (if enabled) — call `getMe` against the Bot API:
   ```bash
   BOT_TOKEN=$(ruby -ryaml -e 'puts (YAML.load_file(File.expand_path("~/.clacky/channels.yml"))["channels"]["telegram"]["bot_token"] rescue "")')
   BASE_URL=$(ruby -ryaml -e 'puts (YAML.load_file(File.expand_path("~/.clacky/channels.yml"))["channels"]["telegram"]["base_url"] || "https://api.telegram.org" rescue "https://api.telegram.org")')
   curl -s "$BASE_URL/bot$BOT_TOKEN/getMe" | grep -q '"ok":true' && echo "✅ Telegram OK" || echo "❌ Telegram credentials rejected by getMe"
   ```
6. **WeCom credentials** (if enabled) — search today's log:
   ```bash
   grep -iE "wecom adapter loop started|WeCom authentication failed|WeCom WS error response|WecomAdapter" \
     ~/.clacky/logger/clacky-$(date +%Y-%m-%d).log
   ```
   - `WeCom authentication failed` or non-zero errcode → ❌ "WeCom credentials incorrect"
   - `adapter loop started` with no auth error → ✅
6. **Discord credentials** (if enabled) — call `GET /api/channels` and check `has_token: true`. Search today's log:
   ```bash
   grep -iE "DiscordAdapter|discord-gateway|/users/@me failed" \
     ~/.clacky/logger/clacky-$(date +%Y-%m-%d).log
   ```
   - `/users/@me failed` → ❌ "Discord token invalid or revoked — re-run setup"
   - `authenticated as` with no error → ✅
7. **DingTalk credentials** (if enabled) — search today's log:
   ```bash
   grep -iE "dingtalk-ws|DingTalk.*error|stream.*error" \
     ~/.clacky/logger/clacky-$(date +%Y-%m-%d).log
   ```
   - `WebSocket connected` → ✅
   - `Stream endpoint error` or `token error` → ❌ "DingTalk credentials invalid — re-run setup"

---

## `send`

Proactively send a message to a user via an IM channel adapter.

### Parse the request

Extract two things from the user's instruction:
- **platform** — one of `weixin`, `feishu`, `wecom`, `discord`, `telegram`, `dingtalk`
- **message** — the text content to send

If the platform cannot be inferred, ask the user to clarify.

### Step 1 — Resolve target user (optional)

If the user specified a `user_id`, use it directly.

Otherwise, list known users first:

```bash
curl -s http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels/<platform>/users
```

- If the list is **empty**: tell the user "No known users for `<platform>`. The target user must send at least one message to the bot before proactive messaging is possible." Stop here.
- If there is **exactly one** user: use it silently.
- If there are **multiple** users: show the list and ask which one to send to, unless the user already specified one.

### Step 2 — Send the message

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels/<platform>/send \
  -H "Content-Type: application/json" \
  -d '{"message": "<message>", "user_id": "<user_id>"}'
```

**Response handling:**

| HTTP status | Meaning | Action |
|---|---|---|
| `200 { ok: true }` | Delivered | Tell user: "✅ Message sent to `<platform>`." |
| `400` platform not running | Adapter is stopped | Tell user the platform is not running and suggest `channel enable <platform>`. |
| `400` no context_token | Token missing | Explain: "The bot has no active session token for this user. Ask the user to send any message to the bot first, then retry." |
| `503` no known users | Nobody has messaged the bot | Same guidance as empty user list above. |
| Other error | Unexpected | Show the error message from the response body. |

### Constraints & notes

- **Weixin (iLink protocol)**: Every outbound message requires a `context_token` that is obtained from the most recent inbound message from that user. The token is cached in memory and reset on server restart. If the server was restarted since the user last wrote, the token is gone and the send will fail — the user must message the bot again.
- **Feishu / WeCom / Discord / Telegram**: No per-message token required. As long as the adapter is running and the `user_id` / `chat_id` (or Discord channel/user id) is valid, the message will be delivered. For Telegram specifically, the `user_id` must be a Telegram chat_id that the bot can write to — the user must have sent at least one message to the bot first.
- This feature is intended for **proactive notifications** (e.g. task completion, reminders). It is not a replacement for the normal reply flow triggered by inbound messages.

---

## Security

- Always mask secrets in output (last 4 chars only).
- Config file must be `chmod 600`.
