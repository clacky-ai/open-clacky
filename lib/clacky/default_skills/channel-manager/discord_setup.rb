#!/usr/bin/env ruby
# frozen_string_literal: true

# discord_setup.rb — Discord channel setup helper.
#
# Discord's developer portal requires manual interaction (hCaptcha + private API), so the
# Agent uses the browser only as a container — it navigates to the portal and the user
# creates the App manually, then pastes back the bot token and application id. This
# script handles everything a shell can do: emit the portal URL, validate the token
# against /users/@me, save to the clacky server, generate the OAuth2 invite URL, and
# poll until the bot is in at least one guild.
#
# Modes:
#   --portal-url                Print the Discord developer portal URL (stdout, single line)
#   --validate <token>          Validate bot_token via /users/@me, then POST to server
#   --invite-url <client_id>    Print the OAuth2 invite URL (stdout, single line)
#   --watch-guild               Long-poll /users/@me/guilds via the saved token
#                               until at least one guild appears (or timeout)
#   --bot-info <token>          Print {id, username} JSON for an unsaved token
#
# Environment:
#   CLACKY_SERVER_HOST  default 127.0.0.1
#   CLACKY_SERVER_PORT  default 7070

require "json"
require "net/http"
require "net/https"
require "uri"
require "openssl"
require "cgi"
require "yaml"

DISCORD_API_BASE      = "https://discord.com/api/v10"
DISCORD_OAUTH_BASE    = "https://discord.com/oauth2/authorize"
DISCORD_PORTAL_URL    = "https://discord.com/developers/applications"
DEFAULT_BOT_PERMS     = "274877990912"
DEFAULT_BOT_SCOPES    = "bot applications.commands"
WATCH_GUILD_DEADLINE  = 10 * 60
WATCH_GUILD_INTERVAL  = 3
USER_AGENT            = "DiscordBot (https://github.com/clackyai/openclacky, 1.0)"

CLACKY_SERVER_URL = begin
  host = ENV.fetch("CLACKY_SERVER_HOST", "127.0.0.1")
  port = ENV.fetch("CLACKY_SERVER_PORT", "7070")
  "http://#{host}:#{port}"
end

def step(msg);  $stderr.puts("[discord-setup] #{msg}"); end
def ok(msg);    $stderr.puts("[discord-setup] #{msg}"); end
def warn!(msg); $stderr.puts("[discord-setup] #{msg}"); end

def fail!(msg, json: false)
  if json
    $stdout.puts(JSON.generate({ error: msg }))
  else
    $stderr.puts("[discord-setup] #{msg}")
  end
  exit 1
end

def discord_get(path, bot_token:, timeout: 15)
  uri  = URI("#{DISCORD_API_BASE}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
  http.read_timeout = timeout
  http.open_timeout = 10

  req = Net::HTTP::Get.new(uri.request_uri)
  req["Authorization"] = "Bot #{bot_token}"
  req["User-Agent"]    = USER_AGENT
  req["Accept"]        = "application/json"

  res    = http.request(req)
  body   = res.body.to_s
  parsed = (JSON.parse(body) rescue nil)

  unless res.is_a?(Net::HTTPSuccess)
    msg = parsed.is_a?(Hash) ? (parsed["message"] || body.slice(0, 200)) : body.slice(0, 200)
    raise "Discord HTTP #{res.code} #{path}: #{msg}"
  end
  parsed
end

def saved_bot_token
  yml_path = File.expand_path("~/.clacky/channels.yml")
  return nil unless File.exist?(yml_path)
  data = YAML.safe_load_file(yml_path, permitted_classes: [Symbol], aliases: true) rescue nil
  data&.dig("channels", "discord", "bot_token") || data&.dig(:channels, :discord, :bot_token)
end

def save_to_server(bot_token:)
  uri  = URI("#{CLACKY_SERVER_URL}/api/channels/discord")
  body = JSON.generate({ bot_token: bot_token })

  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = 30
  http.open_timeout = 5

  req = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
  req.body = body

  res  = http.request(req)
  data = JSON.parse(res.body) rescue {}

  unless res.is_a?(Net::HTTPSuccess) && data["ok"]
    fail!("Failed to save Discord config: #{data["error"] || res.body.slice(0, 200)}")
  end
end

mode_idx = ARGV.index { |a| a.start_with?("--") }
mode     = mode_idx ? ARGV[mode_idx] : nil
arg      = mode_idx ? ARGV[mode_idx + 1] : nil

case mode
when "--portal-url"
  $stdout.puts(DISCORD_PORTAL_URL)
  exit 0

when "--validate"
  fail!("--validate requires <bot_token>") if arg.to_s.strip.empty?
  bot_token = arg.strip
  step("Validating bot token against Discord API...")
  begin
    me = discord_get("/users/@me", bot_token: bot_token)
  rescue => e
    fail!("Token validation failed: #{e.message}")
  end

  bot_id   = me["id"].to_s
  username = me["username"].to_s
  fail!("Empty bot id from /users/@me") if bot_id.empty?

  ok("Authenticated as #{username} (id=#{bot_id})")
  step("Saving credentials via clacky server...")
  save_to_server(bot_token: bot_token)
  ok("Discord channel configured")

  $stdout.puts(JSON.generate({ bot_id: bot_id, username: username }))
  exit 0

when "--bot-info"
  fail!("--bot-info requires <bot_token>", json: true) if arg.to_s.strip.empty?
  begin
    me = discord_get("/users/@me", bot_token: arg.strip)
  rescue => e
    fail!(e.message, json: true)
  end
  $stdout.puts(JSON.generate({ bot_id: me["id"], username: me["username"] }))
  exit 0

when "--invite-url"
  fail!("--invite-url requires <client_id>") if arg.to_s.strip.empty?
  client_id = arg.strip
  url = "#{DISCORD_OAUTH_BASE}?client_id=#{CGI.escape(client_id)}" \
        "&permissions=#{DEFAULT_BOT_PERMS}" \
        "&scope=#{CGI.escape(DEFAULT_BOT_SCOPES)}"
  $stdout.puts(url)
  exit 0

when "--watch-guild"
  bot_token = saved_bot_token
  fail!("No saved bot_token in ~/.clacky/channels.yml — run --validate first") if bot_token.to_s.empty?

  step("Waiting for the bot to be added to a guild (timeout: #{WATCH_GUILD_DEADLINE / 60} min)...")
  deadline = Time.now + WATCH_GUILD_DEADLINE

  loop do
    fail!("Timed out waiting for the bot to join a guild. Open the invite URL again to retry.") if Time.now > deadline

    begin
      guilds = discord_get("/users/@me/guilds", bot_token: bot_token)
    rescue => e
      warn!("Poll error (will retry): #{e.message}")
      sleep WATCH_GUILD_INTERVAL
      next
    end

    if guilds.is_a?(Array) && !guilds.empty?
      g = guilds.first
      ok("Bot added to guild: #{g["name"]} (id=#{g["id"]})")
      $stdout.puts(JSON.generate({ guild_id: g["id"], guild_name: g["name"], total: guilds.length }))
      exit 0
    end

    sleep WATCH_GUILD_INTERVAL
  end

else
  $stderr.puts(<<~USAGE)
    Usage:
      ruby discord_setup.rb --portal-url
      ruby discord_setup.rb --validate <bot_token>
      ruby discord_setup.rb --bot-info <bot_token>
      ruby discord_setup.rb --invite-url <client_id>
      ruby discord_setup.rb --watch-guild
  USAGE
  exit 1
end
