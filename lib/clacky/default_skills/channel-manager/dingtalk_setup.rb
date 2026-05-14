#!/usr/bin/env ruby
# frozen_string_literal: true

# dingtalk_setup.rb — DingTalk channel setup via Device Flow (QR scan).
#
# Modes:
#   --print-qr            Phase 1+2: call init/begin, print QR URL as JSON, exit immediately.
#   --poll <device_code>  Phase 3+4+5: poll until SUCCESS, save credentials, wait for WS.
#
# Environment:
#   CLACKY_SERVER_PORT, CLACKY_SERVER_HOST — clacky server coordinates

require "json"
require "net/http"
require "net/https"
require "uri"

DINGTALK_REG_BASE  = "https://oapi.dingtalk.com"
# Registration source ID assigned by DingTalk (not a brand string — do not rebrand).
DINGTALK_REG_SOURCE = "DING_DWS_CLAW"
POLL_INTERVAL = 3
POLL_TIMEOUT  = 300

CLACKY_SERVER_URL = begin
  url = "http://#{ENV.fetch("CLACKY_SERVER_HOST")}:#{ENV.fetch("CLACKY_SERVER_PORT")}"
  uri = URI.parse(url)
  raise "Invalid CLACKY_SERVER_URL: #{url}" unless uri.is_a?(URI::HTTP) && uri.host && uri.port
  url
end

def step(msg);  puts("[dingtalk-setup] #{msg}"); end
def ok(msg);    puts("[dingtalk-setup] ✅ #{msg}"); end
def warn(msg);  puts("[dingtalk-setup] ⚠️  #{msg}"); end
def fail!(msg)
  puts("[dingtalk-setup] ❌ #{msg}")
  exit 1
end

def post_json(url, payload)
  uri  = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  req = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
  req.body = JSON.generate(payload)
  resp = http.request(req)
  data = JSON.parse(resp.body)
  fail! "API error (#{resp.code}): #{data["errmsg"] || resp.body}" if data["errcode"] && data["errcode"] != 0
  data
rescue JSON::ParserError => e
  fail! "JSON parse error from #{url}: #{e.message}"
end

def server_post(path, body)
  uri = URI(CLACKY_SERVER_URL)
  Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 10) do |h|
    req = Net::HTTP::Post.new(path, "Content-Type" => "application/json")
    req.body = JSON.generate(body)
    h.request(req)
  end
end

def server_get(path)
  uri = URI(CLACKY_SERVER_URL)
  Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 10) do |h|
    h.request(Net::HTTP::Get.new(path))
  end
end

# ── Mode: --print-qr ─────────────────────────────────────────────────────────
# Call init + begin, print JSON with qr_url / device_code / expires_in, exit 0.
def mode_print_qr
  step "Phase 1 — Starting DingTalk Device Flow registration..."

  init_data = post_json("#{DINGTALK_REG_BASE}/app/registration/init",
                        { source: DINGTALK_REG_SOURCE })
  nonce = init_data["nonce"].to_s.strip
  fail! "Missing nonce in init response" if nonce.empty?

  begin_data   = post_json("#{DINGTALK_REG_BASE}/app/registration/begin", { nonce: nonce })
  device_code  = begin_data["device_code"].to_s.strip
  qr_url       = begin_data["verification_uri_complete"].to_s.strip
  expires_in   = (begin_data["expires_in"] || POLL_TIMEOUT).to_i

  fail! "Missing device_code in begin response"  if device_code.empty?
  fail! "Missing verification_uri_complete"       if qr_url.empty?

  ok "Device Flow started. QR expires in #{expires_in}s."
  puts JSON.generate({ qr_url: qr_url, device_code: device_code, expires_in: expires_in })
end

# ── Mode: --poll <device_code> ────────────────────────────────────────────────
# Poll until SUCCESS or a terminal state. Exits with:
#   0  — SUCCESS: credentials saved and adapter started
#   2  — WAITING: user hasn't scanned yet (Agent should ask user to scan and retry)
#   1  — terminal failure (expired, fail, or server error)
def mode_poll(device_code, expires_in: POLL_TIMEOUT, interval: POLL_INTERVAL)
  step "Phase 3 — Checking DingTalk authorization..."

  client_id     = nil
  client_secret = nil
  deadline      = Time.now + expires_in

  loop do
    if Time.now > deadline
      puts "[dingtalk-setup] WAITING_TIMEOUT"
      exit 2
    end

    poll_data = post_json("#{DINGTALK_REG_BASE}/app/registration/poll",
                          { device_code: device_code })
    status = poll_data["status"].to_s.upcase

    case status
    when "WAITING"
      puts "[dingtalk-setup] WAITING"
      exit 2
    when "SUCCESS"
      client_id     = poll_data["client_id"].to_s.strip
      client_secret = poll_data["client_secret"].to_s.strip
      fail! "Authorization succeeded but missing client credentials" if client_id.empty? || client_secret.empty?
      ok "Authorization complete! client_id=#{client_id}"
      break
    when "EXPIRED"
      fail! "Authorization QR code expired. Please re-run."
    when "FAIL"
      fail! "Authorization failed: #{poll_data["fail_reason"] || "unknown reason"}"
    else
      warn "Unknown status=#{status}, retrying..."
      sleep interval
    end
  end

  # ── Phase 4: Save credentials to clacky server ─────────────────────────────
  step "Phase 4 — Saving credentials to clacky server..."

  begin
    res = server_post("/api/channels/dingtalk",
                      { client_id: client_id, client_secret: client_secret, enabled: true })
    if res.code.to_i == 200
      ok "Credentials saved, DingTalk Stream adapter starting..."
    else
      body = JSON.parse(res.body) rescue { "error" => res.body }
      fail! "Server rejected credentials: #{body["error"] || res.body}"
    end
  rescue StandardError => e
    fail! "Could not reach clacky server: #{e.message}"
  end

  # ── Phase 5: Wait for Stream Mode WebSocket to connect ─────────────────────
  step "Phase 5 — Waiting for DingTalk Stream connection..."

  ws_ready    = false
  ws_deadline = Time.now + 30

  loop do
    break if Time.now > ws_deadline
    begin
      res      = server_get("/api/channels")
      channels = JSON.parse(res.body)["channels"] || []
      dingtalk = channels.find { |c| c["platform"] == "dingtalk" }
      if dingtalk&.fetch("running", false)
        ws_ready = true
        break
      end
    rescue StandardError => e
      warn "Channel status check failed: #{e.message}"
    end
    sleep 2
  end

  if ws_ready
    ok "DingTalk Stream WebSocket connected."
  else
    warn "Stream connection not confirmed within 30s — it may still be starting."
  end

  ok "🎉 DingTalk channel setup complete! Search for your robot in DingTalk to start chatting."
  ok "   client_id: #{client_id}"
end

# ── Entry point ───────────────────────────────────────────────────────────────
case ARGV[0]
when "--print-qr"
  mode_print_qr
when "--poll"
  device_code = ARGV[1].to_s.strip
  fail! "Usage: dingtalk_setup.rb --poll <device_code>" if device_code.empty?
  mode_poll(device_code)
else
  fail! "Usage: dingtalk_setup.rb --print-qr | --poll <device_code>"
end
