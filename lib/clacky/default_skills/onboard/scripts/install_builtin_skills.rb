#!/usr/bin/env ruby
# frozen_string_literal: true

require 'uri'
require 'net/http'
require 'json'

require_relative '../../skill-add/scripts/install_from_zip'

class BuiltinSkillsInstaller
  PRIMARY_HOST     = ENV.fetch('CLACKY_LICENSE_SERVER', 'https://www.openclacky.com')
  FALLBACK_HOST    = 'https://openclacky.up.railway.app'
  API_HOSTS        = ENV['CLACKY_LICENSE_SERVER'] ? [PRIMARY_HOST] : [PRIMARY_HOST, FALLBACK_HOST]
  API_PATH         = '/api/v1/skills/builtin'
  API_OPEN_TIMEOUT = 5
  API_READ_TIMEOUT = 10

  def initialize
    @target_dir       = File.join(Dir.home, '.clacky', 'skills')
    @installed        = 0
    @skipped_existing = 0
    @attempted        = 0
    @errors           = []
    # i18n metadata harvested from the platform response for skills that were
    # actually installed on this run. Pushed back to the local clacky server
    # at the end so SkillLoader can persist them to ~/.clacky/skills/builtin_skills.json
    # for zh-locale display overlays — mirrors how brand_skills.json is fed.
    @meta             = []
  end

  def run
    skills = fetch_skill_list
    if skills.nil? || skills.empty?
      emit_summary
      return
    end

    skills.each { |skill| install_one(skill) }
    push_meta_to_server
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
      skip_if_exists: true
    ).perform
    @installed        += result[:installed].size
    @skipped_existing += result[:skipped].size
    @errors.concat(result[:errors]) if result[:errors].any?

    # Capture i18n metadata for every skill the platform listed (whether newly
    # installed or skipped because the directory already existed). This keeps
    # builtin_skills.json in sync with the on-disk skills/ directory across
    # repeat onboard runs.
    @meta << {
      'name'           => name,
      'description'    => skill['description'].to_s,
      'name_zh'        => skill['name_zh'].to_s,
      'description_zh' => skill['description_zh'].to_s,
    }
  rescue StandardError => e
    @errors << "#{name}: #{e.class}: #{e.message}"
  end

  # POST harvested i18n meta to the local clacky HTTP server, which persists it
  # via SkillLoader.record_installed_builtin_skill. Best-effort — failure here
  # only means the zh display overlay is missing on this machine; the skills
  # themselves are installed and functional.
  private def push_meta_to_server
    return if @meta.empty?

    host = ENV['CLACKY_SERVER_HOST'].to_s
    port = ENV['CLACKY_SERVER_PORT'].to_s
    if host.empty? || port.empty?
      @errors << 'push_meta: CLACKY_SERVER_HOST/CLACKY_SERVER_PORT not set, skipping'
      return
    end

    uri = URI.parse("http://#{host}:#{port}/api/onboard/builtin-skills-meta")
    Net::HTTP.start(uri.host, uri.port,
                    open_timeout: API_OPEN_TIMEOUT,
                    read_timeout: API_READ_TIMEOUT) do |http|
      req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
      req.body = JSON.generate(meta: @meta)
      response = http.request(req)
      unless response.code.to_i == 200
        @errors << "push_meta: HTTP #{response.code}"
      end
    end
  rescue StandardError => e
    @errors << "push_meta: #{e.class}: #{e.message}"
  end

  private def emit_summary
    unless @errors.empty?
      warn '[install_builtin_skills] non-fatal errors:'
      @errors.each { |e| warn "  - #{e}" }
    end
    puts JSON.generate(
      installed:        @installed,
      attempted:        @attempted,
      skipped_existing: @skipped_existing
    )
  end
end

BuiltinSkillsInstaller.new.run if __FILE__ == $0
