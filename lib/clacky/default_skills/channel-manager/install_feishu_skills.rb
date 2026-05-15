# frozen_string_literal: true

require 'uri'
require 'net/http'
require 'json'

require_relative '../skill-add/scripts/install_from_zip'

# Install Feishu-related skills from the openclacky platform.
#
# Calls GET /api/v1/skills/feishu — same payload shape as /api/v1/skills/builtin:
#   { "skills": [{ "name": "lark-doc", "download_url": "https://..." }, ...] }
#
# Each skill is installed sequentially via ZipSkillInstaller into ~/.clacky/skills/<name>/.
#
# Usage:
#   ruby install_feishu_skills.rb
#
# Output:
#   Diagnostics  → STDERR
#   Last line    → JSON: {"installed":N,"attempted":N}
#   Exit code    → always 0

class FeishuSkillsInstaller
  PRIMARY_HOST     = ENV.fetch('CLACKY_LICENSE_SERVER', 'https://www.openclacky.com')
  FALLBACK_HOST    = 'https://openclacky.up.railway.app'
  API_HOSTS        = ENV['CLACKY_LICENSE_SERVER'] ? [PRIMARY_HOST] : [PRIMARY_HOST, FALLBACK_HOST]
  API_PATH         = '/api/v1/skills/feishu'
  API_OPEN_TIMEOUT = 5
  API_READ_TIMEOUT = 10

  def initialize
    @target_dir = File.join(Dir.home, '.clacky', 'skills')
    @installed  = 0
    @attempted  = 0
    @errors     = []
  end

  def run
    skills = fetch_skill_list
    if skills.nil? || skills.empty?
      emit_summary
      return
    end

    skills.each { |skill| install_one(skill) }
  ensure
    emit_summary
  end

  private def fetch_skill_list
    API_HOSTS.each do |host|
      begin
        uri = URI.parse(host + API_PATH)
        Net::HTTP.start(uri.host, uri.port,
                        use_ssl:      uri.scheme == 'https',
                        open_timeout: API_OPEN_TIMEOUT,
                        read_timeout: API_READ_TIMEOUT) do |http|
          response = http.request(Net::HTTP::Get.new(uri.request_uri))
          if response.code.to_i == 200
            payload = JSON.parse(response.body)
            return Array(payload['skills'])
          else
            @errors << "API #{host}: HTTP #{response.code}"
          end
        end
      rescue StandardError => e
        @errors << "API #{host}: #{e.class}: #{e.message}"
      end
    end
    nil
  end

  private def install_one(skill)
    name         = skill['name'].to_s
    download_url = skill['download_url'].to_s
    @attempted  += 1

    if name.empty? || download_url.empty?
      @errors << "skill payload missing name or download_url: #{skill.inspect}"
      return
    end

    result = ZipSkillInstaller.new(
      download_url,
      skill_name:     name,
      target_dir:     @target_dir,
      skip_if_exists: false
    ).perform
    @installed += result[:installed].size
    @errors.concat(result[:errors]) if result[:errors].any?
  rescue StandardError => e
    @errors << "#{name}: #{e.class}: #{e.message}"
  end

  private def emit_summary
    unless @errors.empty?
      warn '[install-feishu-skills] non-fatal errors:'
      @errors.each { |e| warn "  - #{e}" }
    end
    puts JSON.generate(installed: @installed, attempted: @attempted)
  end
end

FeishuSkillsInstaller.new.run if __FILE__ == $0
