# frozen_string_literal: true

require "yaml"
require "fileutils"
require "digest"
require "openssl"
require "securerandom"
require "json"
require "time"
require "socket"

module Clacky
  # BrandConfig manages white-label branding for the OpenClacky gem.
  #
  # Brand information is stored separately in ~/.clacky/brand.yml to avoid
  # polluting the main config.yml. When no brand_name is configured, the
  # gem behaves exactly like the standard OpenClacky experience.
  #
  # brand.yml structure:
  #   brand_name: "JohnAI"
  #   distribution_name: "JohnAI Distribution"
  #   product_name: "JohnAI Pro"
  #   logo_url: "https://example.com/logo.png"
  #   support_contact: "support@johnai.com"
  #   license_key: "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4"
  #   license_activated_at: "2025-03-01T00:00:00Z"
  #   license_expires_at: "2026-03-01T00:00:00Z"
  #   license_last_heartbeat: "2025-03-05T00:00:00Z"
  #   device_id: "abc123def456..."
  class BrandConfig
    CONFIG_DIR  = File.join(Dir.home, ".clacky")
    BRAND_FILE  = File.join(CONFIG_DIR, "brand.yml")

    # OpenClacky Cloud API base URL
    API_BASE_URL = "https://openclacky.com"

    # How often to send a heartbeat (seconds) — once per day
    HEARTBEAT_INTERVAL = 86_400

    # Grace period for offline heartbeat failures (3 days)
    HEARTBEAT_GRACE_PERIOD = 3 * 86_400

    attr_reader :brand_name, :license_key, :license_activated_at,
                :license_expires_at, :license_last_heartbeat, :device_id,
                :brand_command, :distribution_name, :product_name,
                :logo_url, :support_contact

    def initialize(attrs = {})
      @brand_name              = attrs["brand_name"]
      @brand_command           = attrs["brand_command"]
      @distribution_name       = attrs["distribution_name"]
      @product_name            = attrs["product_name"]
      @logo_url                = attrs["logo_url"]
      @support_contact         = attrs["support_contact"]
      @license_key             = attrs["license_key"]
      @license_activated_at    = parse_time(attrs["license_activated_at"])
      @license_expires_at      = parse_time(attrs["license_expires_at"])
      @license_last_heartbeat  = parse_time(attrs["license_last_heartbeat"])
      @device_id               = attrs["device_id"]
    end

    # Load brand configuration from ~/.clacky/brand.yml.
    # Returns an empty BrandConfig (no brand) if the file does not exist.
    def self.load
      return new({}) unless File.exist?(BRAND_FILE)

      data = YAML.safe_load(File.read(BRAND_FILE)) || {}
      new(data)
    rescue StandardError
      new({})
    end

    # Returns true when this installation has a brand name configured.
    def branded?
      !@brand_name.nil? && !@brand_name.strip.empty?
    end

    # Returns true when a license key has been stored (post-activation).
    def activated?
      !@license_key.nil? && !@license_key.strip.empty?
    end

    # Returns true when the license has passed its expiry date.
    def expired?
      return false if @license_expires_at.nil?

      Time.now.utc > @license_expires_at
    end

    # Returns true when a heartbeat should be sent (interval elapsed).
    def heartbeat_due?
      return true if @license_last_heartbeat.nil?

      (Time.now.utc - @license_last_heartbeat) >= HEARTBEAT_INTERVAL
    end

    # Returns true when the grace period for missed heartbeats has expired.
    def grace_period_exceeded?
      return false if @license_last_heartbeat.nil?

      (Time.now.utc - @license_last_heartbeat) >= HEARTBEAT_GRACE_PERIOD
    end

    # Save current state to ~/.clacky/brand.yml
    def save
      FileUtils.mkdir_p(CONFIG_DIR)
      File.write(BRAND_FILE, to_yaml)
      FileUtils.chmod(0o600, BRAND_FILE)
    end

    # Activate the license against the OpenClacky Cloud API using HMAC proof.
    # Returns a result hash: { success: bool, message: String, data: Hash }
    def activate!(license_key)
      @license_key = license_key.strip
      @device_id ||= generate_device_id

      user_id  = parse_user_id_from_key(@license_key)
      key_hash = Digest::SHA256.hexdigest(@license_key)
      ts       = Time.now.utc.to_i.to_s
      nonce    = SecureRandom.hex(16)
      message  = "activate:#{key_hash}:#{user_id}:#{@device_id}:#{ts}:#{nonce}"
      proof    = OpenSSL::HMAC.hexdigest("SHA256", @license_key, message)

      payload = {
        key_hash:    key_hash,
        user_id:     user_id.to_s,
        device_id:   @device_id,
        timestamp:   ts,
        nonce:       nonce,
        proof:       proof,
        device_info: device_info
      }

      response = api_post("/api/v1/licenses/activate", payload)

      if response[:success] && response[:data]["status"] == "active"
        data = response[:data]
        @license_activated_at   = Time.now.utc
        @license_last_heartbeat = Time.now.utc
        @license_expires_at     = parse_time(data["expires_at"])
        # Use brand_name returned by the API; fall back to any existing value
        @brand_name = data["brand_name"] if data["brand_name"] && !data["brand_name"].to_s.strip.empty?
        apply_distribution(data["distribution"])
        save
        { success: true, message: "License activated successfully!", brand_name: @brand_name, data: data }
      else
        @license_key = nil
        { success: false, message: response[:error] || "Activation failed", data: {} }
      end
    end

    # Activate the license locally without calling the remote API.
    # Used in brand-test mode for development and integration testing.
    #
    # The mock derives a plausible brand_name from the key's first segment
    # (e.g. "0000002A" → user_id 42 → "Brand42") unless one is already set.
    # A fixed 1-year expiry is written so the UI can display a realistic date.
    #
    # Returns the same { success:, message:, brand_name:, data: } shape as activate!
    def activate_mock!(license_key)
      @license_key = license_key.strip
      @device_id ||= generate_device_id

      # Always derive brand_name fresh from the key in mock mode,
      # so switching keys produces a different brand each time.
      user_id     = parse_user_id_from_key(@license_key)
      @brand_name = "Brand#{user_id}"

      @license_activated_at   = Time.now.utc
      @license_last_heartbeat = Time.now.utc
      @license_expires_at     = Time.now.utc + (365 * 86_400)  # 1 year from now
      save

      {
        success:    true,
        message:    "License activated (mock mode).",
        brand_name: @brand_name,
        data:       { status: "active", expires_at: @license_expires_at.iso8601 }
      }
    end

    # Send a heartbeat to the API and update last_heartbeat timestamp.
    # Returns a result hash: { success: bool, message: String }
    def heartbeat!
      return { success: false, message: "License not activated" } unless activated?

      user_id   = parse_user_id_from_key(@license_key)
      key_hash  = Digest::SHA256.hexdigest(@license_key)
      ts        = Time.now.utc.to_i.to_s
      nonce     = SecureRandom.hex(16)
      message   = "#{user_id}:#{@device_id}:#{ts}:#{nonce}"
      signature = OpenSSL::HMAC.hexdigest("SHA256", @license_key, message)

      payload = {
        key_hash:  key_hash,
        user_id:   user_id.to_s,
        device_id: @device_id,
        timestamp: ts,
        nonce:     nonce,
        signature: signature
      }

      response = api_post("/api/v1/licenses/heartbeat", payload)

      if response[:success]
        @license_last_heartbeat = Time.now.utc
        @license_expires_at = parse_time(response[:data]["expires_at"]) if response[:data]["expires_at"]
        apply_distribution(response[:data]["distribution"])
        save
        { success: true, message: "Heartbeat OK" }
      else
        { success: false, message: response[:error] || "Heartbeat failed" }
      end
    end

    # Fetch the brand skills list from the OpenClacky Cloud API.
    # Requires an activated license. Returns { success: bool, skills: [], error: }.
    def fetch_brand_skills!
      return { success: false, error: "License not activated", skills: [] } unless activated?

      user_id   = parse_user_id_from_key(@license_key)
      key_hash  = Digest::SHA256.hexdigest(@license_key)
      ts        = Time.now.utc.to_i.to_s
      nonce     = SecureRandom.hex(16)
      message   = "#{user_id}:#{@device_id}:#{ts}:#{nonce}"
      signature = OpenSSL::HMAC.hexdigest("SHA256", @license_key, message)

      payload = {
        key_hash:  key_hash,
        user_id:   user_id.to_s,
        device_id: @device_id,
        timestamp: ts,
        nonce:     nonce,
        signature: signature
      }

      response = api_post("/api/v1/licenses/skills", payload)

      if response[:success]
        body = response[:data]
        # Merge local installed version info into each skill
        installed = installed_brand_skills
        skills = (body["skills"] || []).map do |skill|
          slug = skill["slug"] || skill["name"]&.downcase&.gsub(/\s+/, "-")
          local = installed[slug]
          skill.merge(
            "slug"              => slug,
            "installed_version" => local ? local["version"] : nil,
            "needs_update"      => local ? (local["version"] != skill["version"]) : false
          )
        end
        { success: true, skills: skills, expires_at: body["expires_at"] }
      else
        { success: false, error: response[:error] || "Failed to fetch skills", skills: [] }
      end
    end

    # Install (or update) a single brand skill by downloading and extracting its zip.
    # skill_info: a hash from fetch_brand_skills! with at least slug + latest_version.download_url + version
    def install_brand_skill!(skill_info)
      require "net/http"
      require "uri"

      slug    = skill_info["slug"].to_s.strip
      version = (skill_info["latest_version"] || {})["version"] || skill_info["version"]
      url     = (skill_info["latest_version"] || {})["download_url"]

      return { success: false, error: "Missing slug" } if slug.empty?

      if url.nil?
        FileUtils.mkdir_p(File.join(brand_skills_dir, slug))
        return { success: false, error: "No download URL" }
      end

      require "zip"

      dest_dir = File.join(brand_skills_dir, slug)
      FileUtils.mkdir_p(dest_dir)

      # Download the zip file to a temp path
      tmp_zip = File.join(brand_skills_dir, "#{slug}.zip")
      download_file(url, tmp_zip)

      # Extract into dest_dir (overwrite existing files).
      # Auto-detect whether the zip has a single root folder to strip.
      # Uses get_input_stream instead of entry.extract to avoid rubyzip 3.x
      # path-safety restrictions on absolute destination paths.
      Zip::File.open(tmp_zip) do |zip|
        entries  = zip.entries.reject(&:directory?)
        top_dirs = entries.map { |e| e.name.split("/").first }.uniq
        has_root = top_dirs.length == 1 && entries.any? { |e| e.name.include?("/") }

        entries.each do |entry|
          rel_path = if has_root
                       parts = entry.name.split("/")
                       parts[1..].join("/")
                     else
                       entry.name
                     end

          next if rel_path.nil? || rel_path.empty?

          out = File.join(dest_dir, rel_path)
          FileUtils.mkdir_p(File.dirname(out))
          File.open(out, "wb") { |f| f.write(entry.get_input_stream.read) }
        end
      end

      FileUtils.rm_f(tmp_zip)

      # Record installed version in brand_skills.json
      record_installed_skill(slug, version, skill_info["name"])

      { success: true, slug: slug, version: version }
    rescue StandardError, ScriptError => e
      { success: false, error: e.message }
    end

    # Install a mock brand skill for brand-test mode.
    #
    # Writes a realistic (but unencrypted) SKILL.md.enc file to the brand skills
    # directory so the full load → decrypt → invoke code-path can be exercised
    # without a real server.  The file format intentionally mirrors what the
    # production server will deliver: a binary blob stored with a .enc extension.
    #
    # In the current mock implementation the "encryption" is an identity
    # transformation (plain UTF-8 bytes) because BrandConfig#decrypt_skill_content
    # is also mocked.  Both sides will be replaced together during backend
    # integration.
    #
    # @param skill_info [Hash] Must include "slug", "name", "description", and
    #   optionally "version" and "emoji".
    # @return [Hash] { success: bool, slug:, version: }
    def install_mock_brand_skill!(skill_info)
      slug        = skill_info["slug"].to_s.strip
      version     = (skill_info["latest_version"] || {})["version"] || skill_info["version"] || "1.0.0"
      name        = skill_info["name"] || slug
      description = skill_info["description"] || "A private brand skill."
      emoji       = skill_info["emoji"] || "⭐"

      return { success: false, error: "Missing slug" } if slug.empty?

      dest_dir = File.join(brand_skills_dir, slug)
      FileUtils.mkdir_p(dest_dir)

      # Build a realistic SKILL.md that exercises argument substitution and
      # the privacy-protection code path.
      mock_content = <<~SKILL
        ---
        name: #{slug}
        description: "#{description}"
        ---

        # #{emoji} #{name}

        > This is a proprietary brand skill. Its contents are confidential.

        You are an expert assistant specialising in: **#{name}**.

        ## Instructions

        When the user asks you to use this skill, follow these steps:

        1. Understand the user's request: $ARGUMENTS
        2. Apply your expertise to deliver a high-quality result.
        3. Summarise what you did and ask if the user needs adjustments.
      SKILL

      # Write as .enc (mock: plain bytes — real encryption added post-backend)
      enc_path = File.join(dest_dir, "SKILL.md.enc")
      File.binwrite(enc_path, mock_content.encode("UTF-8"))

      record_installed_skill(slug, version, name)
      { success: true, slug: slug, version: version }
    rescue StandardError => e
      { success: false, error: e.message }
    end

    # Synchronise brand skills in the background.
    #
    # Fetches the remote skills list and installs any skill whose remote version
    # differs from the locally installed version.  The work runs in a daemon
    # Thread so it never blocks the caller (typically Agent startup).
    #
    # If the license is not activated the method returns immediately without
    # spawning a thread.
    #
    # @param on_complete [Proc, nil] Optional callback called with the sync
    #   results array once all downloads finish (useful for tests / UI feedback).
    # @return [Thread, nil] The background thread, or nil if skipped.
    def sync_brand_skills_async!(on_complete: nil)
      return nil unless activated?

      Thread.new do
        Thread.current.abort_on_exception = false

        begin
          result = fetch_brand_skills!
          next unless result[:success]

          skills_needing_update = result[:skills].select { |s| s["needs_update"] || s["installed_version"].nil? }
          results = skills_needing_update.map do |skill_info|
            install_brand_skill!(skill_info)
          end

          on_complete&.call(results)
        rescue StandardError
          # Background sync failures are intentionally swallowed — the agent
          # continues to work with whatever skills are already installed.
        end
      end
    end

    # Path to the directory where brand skills are installed.
    def brand_skills_dir
      File.join(CONFIG_DIR, "brand_skills")
    end

    # Decrypt an encrypted brand skill file and return its content in memory.
    #
    # Security model:
    #   - Encrypted files (.enc) are stored on disk using AES-256-GCM envelope encryption.
    #   - The decryption key is derived from segments of the license_key so the
    #     raw key is never transmitted or stored separately.
    #   - Decrypted content exists only in memory and is never written to disk.
    #
    # Envelope encryption (production flow — to be wired up after backend integration):
    #   1. Server stores one copy of the skill encrypted with a random content_key.
    #   2. For each license, the content_key is re-encrypted with a KEK derived from
    #      the license_key's random segments (segments 3+4) and stored alongside.
    #   3. Client: decrypt KEK envelope → recover content_key → decrypt skill.
    #
    # Current implementation (mock):
    #   The "encrypted" file is actually the raw SKILL.md bytes (no real encryption).
    #   AES-256-GCM decryption is stubbed so the full call-chain is exercised and
    #   the interface is stable for backend integration later.
    #
    # TODO: Replace mock body with real two-step envelope decryption once backend
    #       delivers the encrypted_content_key alongside each skill download.
    #
    # @param encrypted_path [String] Path to the .enc file on disk
    # @return [String] Decrypted SKILL.md content (UTF-8)
    # @raise [RuntimeError] If license is not activated or decryption fails
    def decrypt_skill_content(encrypted_path)
      raise "License not activated — cannot decrypt brand skill" unless activated?

      # TODO: Real envelope decryption (post backend integration):
      #
      #   kek          = derive_kek_from_license(@license_key)
      #   content_key  = aes_gcm_decrypt(File.binread(key_envelope_path), kek)
      #   raw          = aes_gcm_decrypt(File.binread(encrypted_path), content_key)
      #   raw.force_encoding("UTF-8")
      #
      # MOCK: treat the .enc file as plain bytes (no actual encryption yet)
      raw = File.binread(encrypted_path)
      raw.force_encoding("UTF-8")
      raw
    rescue Errno::ENOENT
      raise "Brand skill encrypted file not found: #{encrypted_path}"
    end

    # Read the local brand_skills.json metadata, cross-validated against the
    # actual file system.  A skill is only considered installed when:
    #   1. It has an entry in brand_skills.json, AND
    #   2. Its skill directory exists under brand_skills_dir, AND
    #   3. That directory contains at least one file (SKILL.md or SKILL.md.enc).
    #
    # If the JSON record exists but the directory is missing or empty the entry
    # is silently dropped from the result and the JSON file is cleaned up so
    # subsequent installs start from a clean state.
    #
    # Returns a hash keyed by slug: { "version" => "1.0.0", "name" => "..." }
    def installed_brand_skills
      path = File.join(brand_skills_dir, "brand_skills.json")
      return {} unless File.exist?(path)

      raw = JSON.parse(File.read(path))

      # Validate each entry against the actual file system.
      valid   = {}
      changed = false

      raw.each do |slug, meta|
        skill_dir = File.join(brand_skills_dir, slug)
        has_files = Dir.exist?(skill_dir) &&
                    Dir.glob(File.join(skill_dir, "SKILL.md{,.enc}")).any?

        if has_files
          valid[slug] = meta
        else
          # JSON record exists but files are missing — mark for cleanup.
          changed = true
        end
      end

      # Persist the cleaned-up JSON so stale records don't accumulate.
      if changed
        File.write(path, JSON.generate(valid))
      end

      valid
    rescue StandardError
      {}
    end

    # Returns a hash representation for JSON serialization (e.g. /api/brand).
    def to_h
      {
        brand_name:         @brand_name,
        brand_command:      @brand_command,
        distribution_name:  @distribution_name,
        product_name:       @product_name,
        logo_url:           @logo_url,
        support_contact:    @support_contact,
        branded:            branded?,
        activated:          activated?,
        expired:            expired?,
        license_expires_at: @license_expires_at&.iso8601
      }
    end

    private

    def to_yaml
      data = {}
      data["brand_name"]             = @brand_name             if @brand_name
      data["brand_command"]          = @brand_command          if @brand_command
      data["distribution_name"]      = @distribution_name      if @distribution_name
      data["product_name"]           = @product_name           if @product_name
      data["logo_url"]               = @logo_url               if @logo_url
      data["support_contact"]        = @support_contact        if @support_contact
      data["license_key"]            = @license_key            if @license_key
      data["license_activated_at"]   = @license_activated_at.iso8601   if @license_activated_at
      data["license_expires_at"]     = @license_expires_at.iso8601     if @license_expires_at
      data["license_last_heartbeat"] = @license_last_heartbeat.iso8601 if @license_last_heartbeat
      data["device_id"]              = @device_id              if @device_id
      YAML.dump(data)
    end

    # Apply distribution fields from API response.
    # Updates name, product_name, logo_url, support_contact from the distribution hash.
    private def apply_distribution(dist)
      return unless dist.is_a?(Hash)

      @distribution_name = dist["name"]           if dist["name"].to_s.strip != ""
      @product_name      = dist["product_name"]    if dist["product_name"].to_s.strip != ""
      @logo_url          = dist["logo_url"]         if dist["logo_url"].to_s.strip != ""
      @support_contact   = dist["support_contact"]  if dist["support_contact"].to_s.strip != ""
    end

    # Download a remote URL to a local file path.
    private def download_file(url, dest, max_redirects: 10)
      require "net/http"
      require "uri"

      uri = URI.parse(url)
      max_redirects.times do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        open_timeout: 15, read_timeout: 60) do |http|
          http.request_get(uri.request_uri) do |resp|
            case resp.code.to_i
            when 200
              File.open(dest, "wb") { |f| resp.read_body { |chunk| f.write(chunk) } }
              return
            when 301, 302, 303, 307, 308
              location = resp["location"]
              raise "Redirect with no Location header" if location.nil? || location.empty?

              uri = URI.parse(location)
              break  # break out of Net::HTTP.start, re-enter loop with new uri
            else
              raise "HTTP #{resp.code}"
            end
          end
        end
      end
      raise "Too many redirects"
    end

    # Persist installed skill metadata to brand_skills.json.
    private def record_installed_skill(slug, version, name)
      FileUtils.mkdir_p(brand_skills_dir)
      path      = File.join(brand_skills_dir, "brand_skills.json")
      installed = installed_brand_skills
      installed[slug] = { "version" => version, "name" => name, "installed_at" => Time.now.utc.iso8601 }
      File.write(path, JSON.generate(installed))
    end

    # Parse user_id from the License Key structure.
    # Key format: UUUUUUUU-PPPPPPPP-RRRRRRRR-RRRRRRRR-CCCCCCCC
    private def parse_user_id_from_key(key)
      hex = key.delete("-").upcase
      hex[0..7].to_i(16)
    end

    # Generate a stable device ID based on system identifiers.
    private def generate_device_id
      components = [
        Socket.gethostname,
        ENV["USER"] || ENV["USERNAME"] || "",
        RUBY_PLATFORM
      ]
      Digest::SHA256.hexdigest(components.join(":"))
    end

    # Build device metadata for the activation request.
    private def device_info
      {
        os:          RUBY_PLATFORM,
        ruby:        RUBY_VERSION,
        app_version: Clacky::VERSION
      }
    end

    # Parse an ISO 8601 time string, returning nil on failure.
    private def parse_time(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    # POST JSON to the API and return { success:, data:, error: }.
    private def api_post(path, payload)
      require "net/http"
      require "uri"

      uri = URI.parse("#{API_BASE_URL}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 15

      request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
      request.body = JSON.generate(payload)

      response = http.request(request)
      body     = JSON.parse(response.body) rescue {}

      if response.code.to_i == 200
        { success: true, data: body["data"] || body }
      else
        error_msg = map_api_error(body["code"])
        { success: false, error: error_msg, data: body }
      end
    rescue StandardError => e
      { success: false, error: "Network error: #{e.message}", data: {} }
    end

    # Map API error codes to human-readable messages.
    API_ERROR_MESSAGES = {
      "invalid_proof"        => "Invalid license key — please check and try again.",
      "invalid_signature"    => "Invalid request signature.",
      "nonce_replayed"       => "Duplicate request detected. Please try again.",
      "timestamp_expired"    => "System clock is out of sync. Please adjust your time settings.",
      "license_revoked"      => "This license has been revoked. Please contact support.",
      "license_expired"      => "This license has expired. Please renew to continue.",
      "device_limit_reached" => "Device limit reached for this license.",
      "device_revoked"       => "This device has been revoked from the license.",
      "invalid_license"      => "License key not found. Please verify the key.",
      "device_not_found"     => "Device not registered. Please re-activate."
    }.freeze

    private def map_api_error(code)
      API_ERROR_MESSAGES[code] || "Activation failed (#{code || 'unknown error'}). Please contact support."
    end
  end
end
