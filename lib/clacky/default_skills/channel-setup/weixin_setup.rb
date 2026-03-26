#!/usr/bin/env ruby
# frozen_string_literal: true

# weixin_setup.rb — Automated Weixin (WeChat iLink) channel setup.
#
# Modes:
#   --fetch-qr          Output JSON {qrcode_url, qrcode_id} then exit — used by Agent/browser flow
#   --qrcode-id <id>    Skip QR fetch, use existing qrcode_id, long-poll until confirmed, then save
#   (default)           Full flow: fetch QR, display ASCII/URL, long-poll, save
#
# Environment (injected by clacky server when run via Skill):
#   CLACKY_SERVER_PORT — port clacky server listens on (default: 7070)
#   CLACKY_SERVER_HOST — host (default: 127.0.0.1)

require "json"
require "net/http"
require "net/https"
require "uri"
require "base64"
require "securerandom"
require "cgi"
require "shellwords"
require "openssl"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

ILINK_BASE_URL    = "https://ilinkai.weixin.qq.com"
BOT_TYPE          = "3"
QR_POLL_TIMEOUT_S = 37   # slightly above server's 35s long-poll
LOGIN_DEADLINE_S  = 5 * 60

CLACKY_SERVER_URL = begin
  host = ENV.fetch("CLACKY_SERVER_HOST", "127.0.0.1")
  port = ENV.fetch("CLACKY_SERVER_PORT", "7070")
  "http://#{host}:#{port}"
end

# ---------------------------------------------------------------------------
# Mode parsing
# ---------------------------------------------------------------------------

FETCH_QR_MODE = ARGV.include?("--fetch-qr")
QRCODE_ID_IDX = ARGV.index("--qrcode-id")
GIVEN_QRCODE_ID = QRCODE_ID_IDX ? ARGV[QRCODE_ID_IDX + 1] : nil

# ---------------------------------------------------------------------------
# Logging (suppress in --fetch-qr mode so stdout is clean JSON)
# ---------------------------------------------------------------------------

def step(msg); $stderr.puts("[weixin-setup] #{msg}") unless FETCH_QR_MODE; end
def ok(msg);   $stderr.puts("[weixin-setup] ✅ #{msg}") unless FETCH_QR_MODE; end

# In fetch-qr mode, write to stderr so stdout stays clean JSON
def log(msg)
  if FETCH_QR_MODE
    $stderr.puts("[weixin-setup] #{msg}")
  else
    $stderr.puts("[weixin-setup] #{msg}")
  end
end

def fail!(msg)
  if FETCH_QR_MODE
    $stdout.puts(JSON.generate({ error: msg }))
  else
    $stderr.puts("[weixin-setup] ❌ #{msg}")
  end
  exit 1
end

# ---------------------------------------------------------------------------
# iLink HTTP helpers
# ---------------------------------------------------------------------------

def random_wechat_uin
  uint32 = SecureRandom.random_bytes(4).unpack1("N")
  Base64.strict_encode64(uint32.to_s)
end

def ilink_get(path, extra_headers: {}, timeout: 15)
  uri = URI("#{ILINK_BASE_URL}/#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
  http.read_timeout = timeout
  http.open_timeout = 10

  req = Net::HTTP::Get.new(uri.request_uri)
  req["AuthorizationType"] = "ilink_bot_token"
  req["X-WECHAT-UIN"]      = random_wechat_uin
  extra_headers.each { |k, v| req[k] = v }

  res = http.request(req)
  fail!("HTTP #{res.code} from #{path}: #{res.body.slice(0, 200)}") unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
rescue Net::ReadTimeout, Net::OpenTimeout
  nil  # caller handles timeout
rescue => e
  fail!("iLink request failed (#{path}): #{e.message}")
end

# ---------------------------------------------------------------------------
# QR code display (non-fetch-qr mode only)
# ---------------------------------------------------------------------------

def display_qr(qrcode_url)
  displayed = false

  # 1. Try ASCII via qrencode CLI
  if system("which qrencode > /dev/null 2>&1")
    ascii = `qrencode -t ANSIUTF8 -o - #{Shellwords.shellescape(qrcode_url)} 2>/dev/null`
    if $?.success? && !ascii.empty?
      puts ascii
      displayed = true
    end
  end

  # 2. Generate PNG and open in Preview
  unless displayed
    tmp_path = "/tmp/clacky-weixin-qr-#{Process.pid}.png"
    if system("which qrencode > /dev/null 2>&1") &&
       system("qrencode", "-o", tmp_path, qrcode_url, exception: false)
      step("QR code saved to: #{tmp_path}")
      system("open", tmp_path, exception: false) if RUBY_PLATFORM.include?("darwin")
      displayed = true
    end
  end

  # 3. Last resort: print URL
  unless displayed
    $stderr.puts("[weixin-setup] Open this URL with WeChat to login:")
    puts "  #{qrcode_url}"
  end
end

# ---------------------------------------------------------------------------
# Clacky server — save credentials
# ---------------------------------------------------------------------------

def save_to_server(token:, base_url:)
  uri  = URI("#{CLACKY_SERVER_URL}/api/channels/weixin")
  body = JSON.generate({ token: token, base_url: base_url })

  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = 15
  http.open_timeout = 5

  req = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
  req.body = body

  res  = http.request(req)
  data = JSON.parse(res.body) rescue {}

  unless res.is_a?(Net::HTTPSuccess) && data["ok"]
    fail!("Failed to save Weixin config: #{data["error"] || res.body.slice(0, 200)}")
  end

  ok("Credentials saved via clacky server")
rescue => e
  fail!("Could not reach clacky server: #{e.message}")
end

# ---------------------------------------------------------------------------
# Long-poll loop (shared by all modes)
# ---------------------------------------------------------------------------

def poll_until_confirmed(qrcode)
  deadline     = Time.now + LOGIN_DEADLINE_S
  scanned_once = false

  loop do
    fail!("Login timed out. Please run setup again.") if Time.now > deadline

    resp = ilink_get(
      "ilink/bot/get_qrcode_status?qrcode=#{CGI.escape(qrcode)}",
      extra_headers: { "iLink-App-ClientVersion" => "1" },
      timeout: QR_POLL_TIMEOUT_S
    )

    next if resp.nil?  # read timeout = server-side long-poll ended, retry

    case resp["status"]
    when "wait"
      # still waiting
    when "scaned"
      unless scanned_once
        $stderr.puts("[weixin-setup] WeChat scanned! Please confirm in the app...")
        scanned_once = true
      end
    when "confirmed"
      token    = resp["bot_token"].to_s.strip
      base_url = resp["baseurl"].to_s.strip
      base_url = ILINK_BASE_URL if base_url.empty?
      fail!("Login confirmed but no token received") if token.empty?
      return { token: token, base_url: base_url }
    when "expired"
      fail!("QR code expired. Please run setup again.")
    else
      $stderr.puts("[weixin-setup] Unknown status: #{resp["status"]}, continuing...")
    end
  end
end

# ===========================================================================
# Main
# ===========================================================================

# ---------------------------------------------------------------------------
# Mode 1: --fetch-qr  →  output JSON to stdout, exit
# ---------------------------------------------------------------------------

if FETCH_QR_MODE
  $stderr.puts("[weixin-setup] Fetching QR code from iLink...")
  qr_resp = ilink_get("ilink/bot/get_bot_qrcode?bot_type=#{CGI.escape(BOT_TYPE)}")
  fail!("No qrcode in response: #{qr_resp.inspect}") unless qr_resp&.dig("qrcode")

  qrcode     = qr_resp["qrcode"]
  # qrcode_img_content is the URL encoded in the QR (not a base64 image)
  qrcode_url = qr_resp["qrcode_img_content"].to_s.strip
  qrcode_url = "https://liteapp.weixin.qq.com/q/#{qrcode}" if qrcode_url.empty? || !qrcode_url.start_with?("http")

  $stdout.puts(JSON.generate({ qrcode_id: qrcode, qrcode_url: qrcode_url }))
  exit 0
end

# ---------------------------------------------------------------------------
# Mode 2: --qrcode-id <id>  →  skip fetch, poll with existing id, save
# ---------------------------------------------------------------------------

if GIVEN_QRCODE_ID
  $stderr.puts("[weixin-setup] Using existing QR session: #{GIVEN_QRCODE_ID}")
  $stderr.puts("[weixin-setup] Waiting for scan confirmation...")
  result = poll_until_confirmed(GIVEN_QRCODE_ID)
  $stderr.puts("[weixin-setup] Confirmed! Saving credentials...")
  save_to_server(token: result[:token], base_url: result[:base_url])
  $stderr.puts("[weixin-setup] ✅ Weixin channel configured!")
  exit 0
end

# ---------------------------------------------------------------------------
# Mode 3: default — full flow (terminal: ASCII QR + long-poll)
# ---------------------------------------------------------------------------

$stderr.puts("[weixin-setup] Fetching QR code from iLink...")
qr_resp = ilink_get("ilink/bot/get_bot_qrcode?bot_type=#{CGI.escape(BOT_TYPE)}")
fail!("No qrcode in response: #{qr_resp.inspect}") unless qr_resp&.dig("qrcode")

qrcode     = qr_resp["qrcode"]
qrcode_url = qr_resp["qrcode_img_content"].to_s.strip
qrcode_url = "https://liteapp.weixin.qq.com/q/#{qrcode}" if qrcode_url.empty? || !qrcode_url.start_with?("http")

puts
puts "━" * 60
puts "  Scan the QR code below with WeChat, then confirm in the app."
puts "━" * 60
display_qr(qrcode_url)
puts

$stderr.puts("[weixin-setup] Waiting for scan... (timeout: #{LOGIN_DEADLINE_S / 60} minutes)")
result = poll_until_confirmed(qrcode)

$stderr.puts("[weixin-setup] Login confirmed! Saving credentials...")
save_to_server(token: result[:token], base_url: result[:base_url])

puts
puts "━" * 60
puts "[weixin-setup] ✅ Weixin channel configured!"
puts "   The adapter will start receiving messages immediately."
puts "━" * 60
puts

exit 0
