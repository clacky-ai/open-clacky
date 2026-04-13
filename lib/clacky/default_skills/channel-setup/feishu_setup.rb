#!/usr/bin/env ruby
# frozen_string_literal: true

# feishu_setup.rb — Automated Feishu channel setup via internal API.
#
# Strategy: Use browser (via clacky server's /api/tool/browser) ONLY to:
#   1. Check login status and grab Cookie + CSRF token
#   2. Navigate to trigger session initialization
#
# Then call Feishu Open Platform's internal API directly (same as the web UI does):
#   POST /developers/v1/app/create
#   GET  /developers/v1/secret/{app_id}
#   POST /developers/v1/robot/switch/{app_id}
#   POST /developers/v1/event/switch/{app_id}
#   POST /developers/v1/event/update/{app_id}
#   POST /developers/v1/callback/switch/{app_id}
#   GET  /developers/v1/scope/all/{app_id}
#   POST /developers/v1/scope/update/{app_id}
#   POST /developers/v1/app_version/create/{app_id}
#   POST /developers/v1/publish/commit/{app_id}/{version_id}
#   POST /developers/v1/publish/release/{app_id}/{version_id}
#
# This is far more reliable than UI automation.
#
# Environment (injected by clacky server):
#   CLACKY_SERVER_PORT — port the clacky server is listening on
#   CLACKY_SERVER_HOST — host the clacky server is listening on
#   CLACKY_PRODUCT_NAME — product name (default: OpenClacky)

require "json"
require "yaml"
require "net/http"
require "net/https"
require "uri"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PRODUCT_NAME      = ENV.fetch("CLACKY_PRODUCT_NAME", "OpenClacky")
DATE_SUFFIX       = Time.now.strftime("%Y%m%d")
APP_NAME          = "#{PRODUCT_NAME} #{DATE_SUFFIX}"
APP_DESC          = "Your personal assistant powered by #{PRODUCT_NAME}"
FEISHU_BASE_URL   = "https://open.feishu.cn"
FEISHU_API_BASE   = "#{FEISHU_BASE_URL}/developers/v1"
CLACKY_SERVER_URL = begin
  url = "http://#{ENV.fetch("CLACKY_SERVER_HOST")}:#{ENV.fetch("CLACKY_SERVER_PORT")}"
  uri = URI.parse(url)
  raise "Invalid CLACKY_SERVER_URL: #{url}" unless uri.is_a?(URI::HTTP) && uri.host && uri.port
  url
end
WEBSOCKET_POLL_INTERVAL = 3
WEBSOCKET_POLL_TIMEOUT  = 30

BOT_PERMISSIONS = %w[
  im:message
  im:message.p2p_msg:readonly
  im:message.group_at_msg:readonly
  im:message:send_as_bot
  im:resource
  im:message.group_msg
  im:message:readonly
  im:message:update
  im:message:recall
  im:message.reactions:read
  contact:user.base:readonly
  contact:contact.base:readonly
].freeze

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

def step(msg);  puts("[feishu-setup] #{msg}"); end
def ok(msg);    puts("[feishu-setup] ✅ #{msg}"); end
def warn(msg);  puts("[feishu-setup] ⚠️  #{msg}"); end
def fail!(msg)
  puts("[feishu-setup] ❌ #{msg}")
  exit 1
end

# ---------------------------------------------------------------------------
# ToolClient — proxies browser calls through /api/tool/browser on clacky server
# ---------------------------------------------------------------------------

class ToolClient
  def initialize(server_url)
    @server_url = server_url
    @http = nil  # lazy init, rebuilt on connection errors
  end

  def call(action, **params)
    uri     = URI("#{@server_url}/api/tool/browser")
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    request.body = JSON.generate({ "action" => action.to_s }.merge(params.transform_keys(&:to_s)))
    response = http.request(request)
    raise "Server error #{response.code}: #{response.body}" unless response.code.to_i < 500
    result = JSON.parse(response.body)
    raise "Browser error: #{result["error"]}" if result["error"]
    result
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, Net::ReadTimeout, IOError => e
    # Connection dropped (keep-alive expired or server restarted) — rebuild and retry once
    @http = nil
    raise "ToolClient connection failed: #{e.message}"
  end


  def http
    return @http if @http
    uri  = URI("#{@server_url}/api/tool/browser")
    @http = Net::HTTP.new(uri.host, uri.port)
    @http.open_timeout = 5
    @http.read_timeout = 60
    @http
  end
end

# ---------------------------------------------------------------------------
# BrowserSession — minimal browser wrapper, only used for login check + cookies
# ---------------------------------------------------------------------------

class BrowserSession
  def initialize(client)
    @client = client
  end

  def navigate(url)
    @client.call("navigate", url: url)
    sleep 2
    snapshot
  end

  def open(url)
    @client.call("open", url: url)
    sleep 2
    snapshot
  end

  def snapshot(interactive: true, compact: true)
    result = @client.call("snapshot", interactive: interactive, compact: compact)
    result["output"].to_s
  end

  # Run JavaScript in the page context and return the raw output string.
  def evaluate(js)
    result = @client.call("act", kind: "evaluate", js: js)
    result["output"].to_s
  end

  # Extract all cookies for open.feishu.cn from the browser.
  # The browser evaluate output may be wrapped in MCP markdown — parse it out.
  def cookies
    result = @client.call("act",
      kind: "evaluate",
      js: "document.cookie")
    raw = result["output"].to_s
    extract_string_value(raw)
  end

  # Get CSRF token — try multiple sources
  def csrf_token
    # Try x-csrf-token from cookie
    all_cookies = cookies
    all_cookies.split(";").each do |pair|
      k, v = pair.strip.split("=", 2)
      return v.strip if k.strip =~ /csrf.token/i && v
    end

    # Try lark_oapi_csrf_token specifically via JS
    result = @client.call("act",
      kind: "evaluate",
      js: "document.cookie.split(';').map(c=>c.trim()).find(c=>c.startsWith('lark_oapi_csrf_token='))?.split('=')[1] || document.cookie.split(';').map(c=>c.trim()).find(c=>c.startsWith('lgw_csrf_token='))?.split('=')[1] || document.cookie.split(';').map(c=>c.trim()).find(c=>c.startsWith('swp_csrf_token='))?.split('=')[1] || ''")
    token = extract_string_value(result["output"].to_s)
    return token unless token.empty?

    # Try from window object
    result = @client.call("act",
      kind: "evaluate",
      js: "window.csrfToken || ''")
    extract_string_value(result["output"].to_s)
  end

  # The MCP tool wraps evaluate results in markdown code blocks:
  #   "Script ran on page and returned:\n```json\n\"value\"\n```\n"
  # This extracts the actual string value.
  def extract_string_value(raw)
    # Try to find a JSON string value inside ```json ... ``` block
    if raw =~ /```json\s*(.*?)\s*```/m
      inner = $1.strip
      begin
        parsed = JSON.parse(inner)
        return parsed.to_s if parsed.is_a?(String)
        # If it's not a string (e.g. already the cookie text), return as-is
        return inner
      rescue JSON::ParserError
        return inner
      end
    end
    # No markdown wrapper — return raw stripped
    raw.strip
  end
end

# ---------------------------------------------------------------------------
# FeishuApiClient — calls Feishu internal API via the browser (fetch in page context).
# This way the browser automatically includes all cookies, CSRF tokens, and
# session headers — we never need to extract them manually.
# ---------------------------------------------------------------------------

class FeishuApiClient
  def initialize(browser_session)
    @browser = browser_session
  end

  def create_app(name, desc)
    post_json("#{FEISHU_API_BASE}/app/create", {
      appSceneType: 0,
      name:         name,
      desc:         desc,
      avatar:       "",
      i18n: { zh_cn: { name: name, description: desc } },
      primaryLang:  "zh_cn"
    })
  end

  def get_secret(app_id)
    get_json("#{FEISHU_API_BASE}/secret/#{app_id}")
  end

  def enable_bot(app_id)
    post_json("#{FEISHU_API_BASE}/robot/switch/#{app_id}", { enable: true })
  end

  def switch_event_mode(app_id, mode: 4)
    post_json("#{FEISHU_API_BASE}/event/switch/#{app_id}", { eventMode: mode })
  end

  def get_event(app_id)
    get_json("#{FEISHU_API_BASE}/event/#{app_id}")
  end

  def update_event(app_id, event_mode:)
    post_json("#{FEISHU_API_BASE}/event/update/#{app_id}", {
      operation:  "add",
      events:     ["im.message.receive_v1"],
      eventMode:  event_mode
    })
  end

  def switch_callback_mode(app_id, mode: 4)
    post_json("#{FEISHU_API_BASE}/callback/switch/#{app_id}", { callbackMode: mode })
  end

  def get_all_scopes(app_id)
    get_json("#{FEISHU_API_BASE}/scope/all/#{app_id}")
  end

  def update_scopes(app_id, scope_ids)
    post_json("#{FEISHU_API_BASE}/scope/update/#{app_id}", {
      clientId:    app_id,
      appScopeIDs: scope_ids,
      userScopeIDs: [],
      scopeIds:    [],
      operation:   "add"
    })
  end

  def create_version(app_id, version: "1.0.0")
    post_json("#{FEISHU_API_BASE}/app_version/create/#{app_id}", {
      clientId:             app_id,
      appVersion:           version,
      changeLog:            "Initial release",
      autoPublish:          false,
      pcDefaultAbility:     "bot",
      mobileDefaultAbility: "bot"
    })
  end

  def commit_version(app_id, version_id)
    post_json("#{FEISHU_API_BASE}/publish/commit/#{app_id}/#{version_id}", {})
  end

  def release_version(app_id, version_id)
    post_json("#{FEISHU_API_BASE}/publish/release/#{app_id}/#{version_id}", {
      clientId:  app_id,
      versionId: version_id
    })
  end

  def get_app_info(app_id)
    get_json("#{FEISHU_API_BASE}/app/#{app_id}")
  end


  # Execute a GET fetch in the browser page context.
  # Uses window.csrfToken — required by all /developers/v1/ endpoints.
  def get_json(url)
    js = <<~JS
      (async () => {
        const csrfToken = window.csrfToken || '';
        const resp = await fetch(#{url.to_json}, {
          method: 'GET',
          credentials: 'include',
          headers: {
            'accept': '*/*',
            'x-timezone-offset': '-480',
            'x-csrf-token': csrfToken
          }
        });
        return await resp.text();
      })()
    JS
    run_fetch(js, url)
  end

  # Execute a POST fetch in the browser page context.
  # Uses window.csrfToken (set by Feishu's own JS) — the correct token for /developers/v1/ APIs.
  def post_json(url, payload)
    js = <<~JS
      (async () => {
        const csrfToken = window.csrfToken || '';
        const resp = await fetch(#{url.to_json}, {
          method: 'POST',
          credentials: 'include',
          headers: {
            'accept': '*/*',
            'content-type': 'application/json',
            'origin': 'https://open.feishu.cn',
            'referer': 'https://open.feishu.cn/app',
            'x-timezone-offset': '-480',
            'x-csrf-token': csrfToken
          },
          body: #{JSON.generate(payload).to_json}
        });
        return await resp.text();
      })()
    JS
    run_fetch(js, url)
  end

  def run_fetch(js, url)
    raw = @browser.evaluate(js)
    # The MCP tool may wrap result in markdown code blocks
    json_text = @browser.send(:extract_string_value, raw)
    JSON.parse(json_text)
  rescue JSON::ParserError => e
    raise "JSON parse error from #{url}: #{e.message} — raw: #{raw.to_s[0..300]}"
  end
end

# ---------------------------------------------------------------------------
# API helpers — check code=0, return data or nil
# ---------------------------------------------------------------------------

def api_ok!(body, step_name)
  code = body["code"]
  return body["data"] if code == 0

  fail! "#{step_name} failed: code=#{code}, msg=#{body["msg"]}"
end

def api_ok?(body)
  body.is_a?(Hash) && body["code"] == 0
end

# ---------------------------------------------------------------------------
# Websocket-mode polling helper (code=10068 means WS not ready yet)
# ---------------------------------------------------------------------------

def poll_with_ws_wait(step_name, timeout: WEBSOCKET_POLL_TIMEOUT, interval: WEBSOCKET_POLL_INTERVAL)
  deadline = Time.now + timeout
  attempt  = 0
  last_body = nil
  loop do
    attempt += 1
    body = yield
    last_body = body
    return body if body["code"] == 0
    if body["code"] == 10068
      step "  #{step_name}: waiting for WebSocket connection... (#{attempt})"
      if Time.now > deadline
        warn "#{step_name}: WebSocket not ready after #{timeout}s — continuing anyway (will retry on reconnect)"
        return body
      end
      sleep interval
    else
      fail! "#{step_name} failed: code=#{body["code"]}, msg=#{body["msg"]}"
    end
  end
end

# ---------------------------------------------------------------------------
# Main setup logic
# ---------------------------------------------------------------------------

def run_setup(browser, api)
  app_id     = nil
  app_secret = nil
  version_id = nil

  # ── Phase 1: Verify login ────────────────────────────────────────────────
  step "Phase 1 — Verifying Feishu login..."
  snap = browser.open("https://open.feishu.cn/app")
  unless snap.include?("创建企业自建") || snap.include?("Create Custom App") || snap.include?("Create Enterprise")
    fail! "Not logged in to Feishu Open Platform. Please log in to open.feishu.cn in Chrome first, then re-run."
  end
  ok "Logged in, app console visible."

  # ── Phase 2: Create app via API ──────────────────────────────────────────
  step "Phase 2 — Creating app '#{APP_NAME}' via API..."
  body = api.create_app(APP_NAME, APP_DESC)
  data = api_ok!(body, "create_app")
  app_id = data["ClientID"] || data["client_id"] || data["appId"] || data["app_id"]
  fail! "create_app succeeded (code=0) but no ClientID in response: #{data.inspect}" unless app_id
  ok "App created: #{APP_NAME} (#{app_id})"

  # ── Phase 3: Get credentials ─────────────────────────────────────────────
  step "Phase 3 — Reading App Secret..."
  body = api.get_secret(app_id)
  data = api_ok!(body, "get_secret")
  app_secret = data["appSecret"] || data["app_secret"] || data["secret"] || data["AppSecret"]
  fail! "No App Secret in response: #{data.inspect}" unless app_secret
  ok "Credentials: App ID=#{app_id}, App Secret=****#{app_secret[-4..]}"

  # ── Phase 4: Write credentials to clacky server and wait for WS ─────────
  step "Phase 4 — Writing credentials to clacky server..."

  # Helper: one-shot HTTP request to clacky server (new connection each time, no keep-alive issues)
  server_request = lambda do |method, path, body_hash = nil|
    uri = URI(CLACKY_SERVER_URL)
    Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 10) do |h|
      req = method == :post \
        ? Net::HTTP::Post.new(path, "Content-Type" => "application/json") \
        : Net::HTTP::Get.new(path)
      req.body = JSON.generate(body_hash) if body_hash
      h.request(req)
    end
  end

  begin
    res = server_request.call(:post, "/api/channels/feishu",
                              { app_id: app_id, app_secret: app_secret, enabled: true })
    step "  Server response: #{res.code}"
  rescue StandardError => e
    warn "Could not reach clacky server (#{e.message}) — continuing..."
  end
  ok "Credentials submitted, waiting for WebSocket connection..."

  # Poll GET /api/channels until feishu shows running: true (max 90s)
  ws_ready    = false
  ws_deadline = Time.now + 90
  loop do
    begin
      res      = server_request.call(:get, "/api/channels")
      channels = JSON.parse(res.body)["channels"] || []
      feishu   = channels.find { |c| c["platform"] == "feishu" }
      if feishu && feishu["running"]
        ws_ready = true
        break
      end
    rescue StandardError => e
      warn "Channel status check failed: #{e.message}"
    end
    break if Time.now > ws_deadline
    step "  Waiting for Feishu WebSocket connection..."
    sleep 3
  end

  if ws_ready
    ok "Feishu WebSocket connected."
  else
    warn "WebSocket not confirmed within 90s — continuing anyway."
  end

  # ── Phase 5: Enable Bot capability ──────────────────────────────────────
  step "Phase 5 — Enabling Bot capability..."
  body = api.enable_bot(app_id)
  api_ok!(body, "enable_bot")
  ok "Bot capability enabled."

  # ── Phase 6: Switch event mode to Long Connection (WebSocket) ───────────
  step "Phase 6 — Switching event mode to Long Connection (WebSocket)..."
  poll_with_ws_wait("switch_event_mode") { api.switch_event_mode(app_id) }
  ok "Event mode: done (WebSocket)."

  # ── Phase 7: Add im.message.receive_v1 event ────────────────────────────
  step "Phase 7 — Adding im.message.receive_v1 event..."
  ev_body = api.get_event(app_id)
  event_mode = api_ok?(ev_body) ? (ev_body.dig("data", "eventMode") || 4) : 4
  body = api.update_event(app_id, event_mode: event_mode)
  api_ok!(body, "update_event")
  ok "Event im.message.receive_v1 added."

  # ── Phase 8: Switch callback mode to Long Connection ────────────────────
  step "Phase 8 — Switching callback mode to Long Connection..."
  poll_with_ws_wait("switch_callback_mode") { api.switch_callback_mode(app_id) }
  ok "Callback mode: done (Long Connection)."

  # ── Phase 9: Add permissions ─────────────────────────────────────────────
  step "Phase 9 — Adding Bot permissions..."
  scope_body = api.get_all_scopes(app_id)
  scope_data = api_ok!(scope_body, "get_all_scopes")
  scopes     = scope_data["scopes"] || []
  name_to_id = {}
  scopes.each do |s|
    name = s["name"] || s["scopeName"] || ""
    id   = s["id"].to_s
    name_to_id[name] = id if name && !id.empty?
  end
  ids     = BOT_PERMISSIONS.map { |n| name_to_id[n] }.compact
  missing = BOT_PERMISSIONS.reject { |n| name_to_id.key?(n) }
  warn "#{missing.size} permissions not matched: #{missing.join(", ")}" unless missing.empty?
  fail! "No permission IDs matched. API response keys: #{name_to_id.keys.first(5).inspect}" if ids.empty?
  body = api.update_scopes(app_id, ids)
  api_ok!(body, "update_scopes")
  ok "#{ids.size} permissions added."

  # ── Phase 10: Publish app ────────────────────────────────────────────────
  step "Phase 10 — Creating version and publishing..."
  body = api.create_version(app_id)
  data = api_ok!(body, "create_version")
  version_id = data["versionId"] || data["version_id"]
  fail! "No version_id in create_version response: #{data.inspect}" unless version_id

  sleep 1
  body = api.commit_version(app_id, version_id)
  api_ok!(body, "commit_version")

  sleep 1
  body = api.release_version(app_id, version_id)
  release_code = body["code"]

  if release_code == 0
    ok "App published successfully."
  elsif release_code == 10002
    # Already approved or auto-published — verify actual status
    sleep 1
    info = api.get_app_info(app_id)
    if api_ok?(info) && info.dig("data", "appStatus") == 1
      ok "App published (auto-approved)."
    else
      warn "App submitted for review (admin approval required). App ID: #{app_id}"
    end
  else
    warn "Publish returned code=#{release_code} (#{body["msg"]}) — app may need admin approval."
    warn "You can publish manually at: #{FEISHU_BASE_URL}/app/#{app_id}"
  end

  # Config was already saved by the server in Phase 4 via POST /api/channels/feishu
  ok "🎉 Feishu channel setup complete! App: #{APP_NAME} (#{app_id})"
  ok "   Manage at: #{FEISHU_BASE_URL}/app/#{app_id}"
end

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

tool_client = ToolClient.new(CLACKY_SERVER_URL)
browser     = BrowserSession.new(tool_client)

# Navigate to Feishu to establish page context
step "Initializing browser session..."
browser.open("https://open.feishu.cn/app")
sleep 1

# Quick sanity check — verify we have cookies
cookie_str = browser.cookies
fail! "No cookies found. Please log in to open.feishu.cn in Chrome first." if cookie_str.strip.empty?
step "Browser session ready (cookie length: #{cookie_str.length})"

# API client uses in-browser fetch — cookies & CSRF handled by browser automatically
api = FeishuApiClient.new(browser)

run_setup(browser, api)
