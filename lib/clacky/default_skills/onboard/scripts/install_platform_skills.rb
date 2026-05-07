#!/usr/bin/env ruby
# frozen_string_literal: true

# Install platform skills into ~/.clacky/skills/.
#
# Fetches the skill list from GET /api/v1/skills on the openclacky platform
# (public, no auth), then downloads and installs each skill's zip package
# in parallel (5 workers, 30s total timeout).
#
# Called by onboard skill: `ruby install_platform_skills.rb --recommended`
#
# Output:
#   - Diagnostics → STDERR
#   - Last line of STDOUT → JSON: {"installed":N,"attempted":N,"skipped_existing":N}
#   - Exit code: always 0

require 'uri'
require 'net/http'
require 'json'
require 'optparse'
require 'timeout'

# Reuse the downloader/extractor/installer from the skill-add skill.
# Physical relocation to lib/clacky/ is deferred until a third caller appears.
require_relative '../../skill-add/scripts/install_from_zip'

class PlatformSkillsInstaller
  PRIMARY_HOST     = ENV.fetch('CLACKY_LICENSE_SERVER', 'https://www.openclacky.com')
  FALLBACK_HOST    = 'https://openclacky.up.railway.app'
  API_HOSTS        = ENV['CLACKY_LICENSE_SERVER'] ? [PRIMARY_HOST] : [PRIMARY_HOST, FALLBACK_HOST]
  API_OPEN_TIMEOUT = 5
  API_READ_TIMEOUT = 10
  CONCURRENCY      = 5

  def initialize(options)
    @query_params      = build_query_params(options)
    @target_dir        = File.join(Dir.home, '.clacky', 'skills')
    @per_skill_timeout = 10
    @total_timeout     = 30

    @installed         = 0
    @skipped_existing  = 0
    @attempted         = 0
    @errors            = []
    @mutex             = Mutex.new
  end

  def run
    skills = fetch_skill_list
    if skills.nil? || skills.empty?
      emit_summary
      return
    end

    install_concurrently(skills)
  ensure
    emit_summary
  end

  # --- Internals -------------------------------------------------------------

  # Build the query-parameter hash that mirrors the platform API spec.
  private def build_query_params(options)
    params = {}
    params['recommended'] = 'true' if options[:recommended]
    params['category'] = options[:category] if options[:category]
    params
  end

  # /api/v1/skills[?...]. Empty query when no filters.
  private def api_path
    qs = URI.encode_www_form(@query_params)
    qs.empty? ? '/api/v1/skills' : "/api/v1/skills?#{qs}"
  end

  # Returns an array of skill hashes, or nil on total failure.
  private def fetch_skill_list
    API_HOSTS.each do |host|
      begin
        uri = URI.parse(host + api_path)
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

  # Install skills in parallel, bounded by CONCURRENCY and @total_timeout.
  # Workers pull from a shared queue and self-check the deadline, so the
  # global timeout is enforced without killing threads mid-download (which
  # would leak temp dirs). Whatever finishes before the deadline stays
  # installed; the rest is recovered on the next onboard run via skip_if_exists.
  private def install_concurrently(skills)
    queue = Queue.new
    skills.each { |s| queue << s }

    deadline    = Time.now + @total_timeout
    worker_pool = [CONCURRENCY, skills.size].min

    workers = Array.new(worker_pool) do
      Thread.new do
        loop do
          break if Time.now >= deadline
          skill = queue.pop(true) rescue nil    # non-blocking pop
          break if skill.nil?
          install_one(skill)
        end
      end
    end

    workers.each(&:join)

    # If the deadline cut us off with items still in the queue, record it.
    remaining = queue.size
    if remaining.positive?
      @mutex.synchronize do
        @errors << "overall timeout after #{@total_timeout}s " \
                   "(installed=#{@installed}, attempted=#{@attempted}, remaining=#{remaining})"
      end
    end
  end

  # Install one skill entry (hash from the API payload).
  # Bounded by @per_skill_timeout; any failure is swallowed into @errors.
  # Thread-safe: all shared state writes go through @mutex.
  private def install_one(skill)
    name         = skill['name'].to_s
    download_url = skill['download_url'].to_s

    @mutex.synchronize { @attempted += 1 }

    if name.empty? || download_url.empty?
      @mutex.synchronize do
        @errors << "skill payload missing name or download_url: #{skill.inspect}"
      end
      return
    end

    Timeout.timeout(@per_skill_timeout) do
      installer = ZipSkillInstaller.new(
        download_url,
        skill_name:     name,
        target_dir:     @target_dir,
        skip_if_exists: true
      )
      result = installer.perform
      @mutex.synchronize do
        @installed        += result[:installed].size
        @skipped_existing += result[:skipped].size
        @errors.concat(result[:errors]) if result[:errors].any?
      end
    end
  rescue Timeout::Error
    @mutex.synchronize { @errors << "#{name}: install timeout after #{@per_skill_timeout}s" }
  rescue StandardError => e
    @mutex.synchronize { @errors << "#{name}: #{e.class}: #{e.message}" }
  end

  # Diagnostics to stderr; single-line JSON summary to stdout.
  # The caller (onboard) should parse the LAST stdout line.
  private def emit_summary
    unless @errors.empty?
      warn '[install_platform_skills] non-fatal errors:'
      @errors.each { |e| warn "  - #{e}" }
    end
    puts JSON.generate(
      installed:        @installed,
      attempted:        @attempted,
      skipped_existing: @skipped_existing
    )
  end
end

# ── Entry point ───────────────────────────────────────────────────────────────
if __FILE__ == $0
  options = {}
  OptionParser.new do |o|
    o.on('--recommended', 'Only install recommended skills') { options[:recommended] = true }
    o.on('--category SLUG', 'Filter by category slug') { |v| options[:category] = v }
  end.parse!

  PlatformSkillsInstaller.new(options).run
end
