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
  # polluting the main config.yml. When no product_name is configured, the
  # gem behaves exactly like the standard OpenClacky experience.
  #
  # brand.yml structure:
  #   product_name: "JohnAI"
  #   package_name: "johnai"
  #   logo_url: "https://example.com/logo.png"
  #   support_contact: "support@johnai.com"
  #   support_qr_url: "https://example.com/qr.png"
  #   theme_color: "#3B82F6"
  #   homepage_url: "https://johnai.com"
  #   license_key: "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4"
  #   license_activated_at: "2025-03-01T00:00:00Z"
  #   license_expires_at: "2026-03-01T00:00:00Z"
  #   license_last_heartbeat: "2025-03-05T00:00:00Z"
  #   device_id: "abc123def456..."
  class BrandConfig
    CONFIG_DIR  = File.join(Dir.home, ".clacky")
    BRAND_FILE  = File.join(CONFIG_DIR, "brand.yml")

    # How often to send a heartbeat (seconds) — once per day
    HEARTBEAT_INTERVAL = 86_400

    # Grace period for offline heartbeat failures (3 days)
    HEARTBEAT_GRACE_PERIOD = 3 * 86_400

    attr_reader :product_name, :package_name, :license_key, :license_activated_at,
                :license_expires_at, :license_last_heartbeat, :device_id,
                :logo_url, :support_contact, :license_user_id,
                :support_qr_url, :theme_color, :homepage_url

    def initialize(attrs = {})
      @product_name            = attrs["product_name"]
      @package_name            = attrs["package_name"]
      @logo_url                = attrs["logo_url"]
      @support_contact         = attrs["support_contact"]
      @support_qr_url          = attrs["support_qr_url"]
      @theme_color             = attrs["theme_color"]
      @homepage_url            = attrs["homepage_url"]
      @license_key             = attrs["license_key"]
      @license_activated_at    = parse_time(attrs["license_activated_at"])
      @license_expires_at      = parse_time(attrs["license_expires_at"])
      @license_last_heartbeat  = parse_time(attrs["license_last_heartbeat"])
      @device_id               = attrs["device_id"]
      # user_id returned by the license server when the license is bound to a specific user
      @license_user_id         = attrs["license_user_id"]

      # In-memory decryption key cache: "skill_id:skill_version_id" => { key:, expires_at: }
      # Never persisted to disk. Survives across multiple skill invocations within one session.
      @decryption_keys         = {}
      # Timestamp of last successful server contact (for grace period calculation)
      @last_server_contact_at  = nil
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

    # Returns true when this installation has a product name configured.
    def branded?
      !@product_name.nil? && !@product_name.strip.empty?
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
      if @license_last_heartbeat.nil?
        Clacky::Logger.debug("[Brand] heartbeat_due? => true (never sent)")
        return true
      end

      elapsed = Time.now.utc - @license_last_heartbeat
      due = elapsed >= HEARTBEAT_INTERVAL
      Clacky::Logger.debug("[Brand] heartbeat_due? elapsed=#{elapsed.to_i}s interval=#{HEARTBEAT_INTERVAL}s => #{due}")
      due
    end

    # Returns true when the grace period for missed heartbeats has expired.
    def grace_period_exceeded?
      if @license_last_heartbeat.nil?
        Clacky::Logger.debug("[Brand] grace_period_exceeded? => false (no heartbeat recorded)")
        return false
      end

      elapsed = Time.now.utc - @license_last_heartbeat
      exceeded = elapsed >= HEARTBEAT_GRACE_PERIOD
      Clacky::Logger.debug("[Brand] grace_period_exceeded? elapsed=#{elapsed.to_i}s grace=#{HEARTBEAT_GRACE_PERIOD}s => #{exceeded}")
      exceeded
    end

    # Returns true when the license is bound to a specific user (user_id present).
    # User-licensed installations gain additional capabilities such as the ability
    # to upload custom skills via the web UI.
    def user_licensed?
      activated? && !@license_user_id.nil? && !@license_user_id.to_s.strip.empty?
    end

    # Save current state to ~/.clacky/brand.yml
    def save
      FileUtils.mkdir_p(CONFIG_DIR)
      File.write(BRAND_FILE, to_yaml)
      FileUtils.chmod(0o600, BRAND_FILE)
    end

    # Remove the local license binding and wipe all brand-related fields from disk.
    # Brand skills installed from this license are also cleared.
    # Returns { success: true }.
    def deactivate!
      clear_brand_skills!
      FileUtils.rm_f(BRAND_FILE)
      # Reset all in-memory state so this instance is clean after the call.
      @product_name           = nil
      @package_name           = nil
      @logo_url               = nil
      @support_contact        = nil
      @support_qr_url         = nil
      @theme_color            = nil
      @homepage_url           = nil
      @license_key            = nil
      @license_activated_at   = nil
      @license_expires_at     = nil
      @license_last_heartbeat = nil
      @license_user_id        = nil
      @device_id              = nil
      { success: true }
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
        server_device_id = data["device_id"].to_s.strip
        @device_id = server_device_id unless server_device_id.empty?
        # Clear ALL stale fields first, then apply fresh values from the new key.
        # Order matters: reset everything before re-assigning so no old value lingers.
        @product_name    = nil
        @package_name    = nil
        @logo_url        = nil
        @support_contact = nil
        @support_qr_url  = nil
        @theme_color     = nil
        @homepage_url    = nil
        @license_user_id = nil
        # Re-apply owner_user_id from the new activation response.
        # Only system (creator) licenses return a non-nil owner_user_id.
        # Brand-consumer keys return nil → @license_user_id stays nil → user_licensed? = false.
        owner_uid = data["owner_user_id"]
        @license_user_id = owner_uid.to_s.strip if owner_uid && !owner_uid.to_s.strip.empty?
        apply_distribution(data["distribution"])
        # Clear previously installed brand skills before saving the new license.
        # Skills from the old brand are encrypted with that brand's keys — they
        # cannot be decrypted with the new license and must be re-downloaded.
        clear_brand_skills!
        save
        { success: true, message: "License activated successfully!", product_name: @product_name,
          user_id: @license_user_id, data: data }
      else
        @license_key = nil
        { success: false, message: response[:error] || "Activation failed", data: {} }
      end
    end

    # Activate the license locally without calling the remote API.
    # Used in brand-test mode for development and integration testing.
    #
    # The mock derives a plausible product_name from the key's first segment
    # (e.g. "0000002A" → user_id 42 → "Brand42") unless one is already set.
    # A fixed 1-year expiry is written so the UI can display a realistic date.
    #
    # Returns the same { success:, message:, product_name:, data: } shape as activate!
    def activate_mock!(license_key)
      @license_key = license_key.strip
      # Pin a stable device_id for this activation. Once set (from a prior load or
      # a previous call), never regenerate — the same rule as activate!.
      @device_id ||= generate_device_id

      # Always derive product_name fresh from the key in mock mode,
      # so switching keys produces a different brand each time.
      user_id       = parse_user_id_from_key(@license_key)
      @product_name = "Brand#{user_id}"

      @license_activated_at   = Time.now.utc
      @license_last_heartbeat = Time.now.utc
      @license_expires_at     = Time.now.utc + (365 * 86_400)  # 1 year from now
      # Clear old brand skills so stale encrypted files from a previous brand don't linger
      clear_brand_skills!
      save

      {
        success:      true,
        message:      "License activated (mock mode).",
        product_name: @product_name,
        data:         { status: "active", expires_at: @license_expires_at.iso8601 }
      }
    end

    # Send a heartbeat to the API and update last_heartbeat timestamp.
    # Returns a result hash: { success: bool, message: String }
    def heartbeat!
      unless activated?
        Clacky::Logger.debug("[Brand] heartbeat! skipped — license not activated")
        return { success: false, message: "License not activated" }
      end

      Clacky::Logger.info("[Brand] heartbeat! sending — last_heartbeat=#{@license_last_heartbeat&.iso8601 || "nil"} expires_at=#{@license_expires_at&.iso8601 || "nil"}")

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
        Clacky::Logger.info("[Brand] heartbeat! success — expires_at=#{@license_expires_at&.iso8601} last_heartbeat=#{@license_last_heartbeat.iso8601}")
        { success: true, message: "Heartbeat OK" }
      else
        Clacky::Logger.warn("[Brand] heartbeat! failed — #{response[:error]}")
        { success: false, message: response[:error] || "Heartbeat failed" }
      end
    end

    # Upload (publish) a custom skill ZIP to the OpenClacky Cloud API.
    # Calls POST /api/v1/client/skills (system-license endpoint).
    # zip_data is the raw binary content of the ZIP file.
    # Returns { success: bool, error: String }.
    # Upload a skill ZIP to the OpenClacky cloud.
    # skill_name: skill name string (slug format)
    # zip_data:   binary ZIP content
    # force:      when true, use PATCH to overwrite an existing skill instead of POST
    #
    # Returns { success: true, skill: {...} } or { success: false, error: "...", already_exists: true/false }
    def upload_skill!(skill_name, zip_data, force: false, version_override: nil)
      return { success: false, error: "License not activated" } unless activated?
      return { success: false, error: "User license required to upload skills" } unless user_licensed?

      # The client skills API uses @license_user_id (the platform owner user id),
      # NOT the user_id embedded in the license key structure.
      user_id   = @license_user_id.to_s
      key_hash  = Digest::SHA256.hexdigest(@license_key)
      ts        = Time.now.utc.to_i.to_s
      nonce     = SecureRandom.hex(16)
      message   = "#{user_id}:#{@device_id}:#{ts}:#{nonce}"
      signature = OpenSSL::HMAC.hexdigest("SHA256", @license_key, message)

      # POST /api/v1/client/skills         → create (first upload)
      # PATCH /api/v1/client/skills/:name → update (force overwrite)
      path = if force
               "/api/v1/client/skills/#{URI.encode_www_form_component(skill_name)}"
             else
               "/api/v1/client/skills"
             end

      boundary = "----ClackySkillUpload#{SecureRandom.hex(8)}"
      crlf     = "\r\n"

      # Build multipart body as a binary string so that null bytes in the ZIP
      # data are preserved. All parts are joined as binary before sending.
      parts = []
      fields = {
        "key_hash"  => key_hash,
        "user_id"   => user_id,
        "device_id" => @device_id,
        "timestamp" => ts,
        "nonce"     => nonce,
        "signature" => signature,
        "name"      => skill_name.to_s
      }
      # Include version override when bumping an existing skill version
      fields["version"] = version_override.to_s if version_override

      fields.each do |field, value|
        parts << "--#{boundary}#{crlf}"
        parts << "Content-Disposition: form-data; name=\"#{field}\"#{crlf}#{crlf}"
        parts << value.to_s
        parts << crlf
      end
      # Binary file part
      parts << "--#{boundary}#{crlf}"
      parts << "Content-Disposition: form-data; name=\"skill_zip\"; filename=\"#{skill_name}.zip\"#{crlf}"
      parts << "Content-Type: application/zip#{crlf}#{crlf}"
      parts << zip_data.b
      parts << "#{crlf}--#{boundary}--#{crlf}"

      body_bytes = parts.map(&:b).join

      # Delegate sending (with retry + failover) to PlatformHttpClient.
      # Uploads can be slow so we allow a generous 60-second read timeout.
      result = if force
                 platform_client.multipart_patch(path, body_bytes, boundary, read_timeout: 60)
               else
                 platform_client.multipart_post(path, body_bytes, boundary, read_timeout: 60)
               end

      if result[:success]
        parsed = result[:data]
        { success: true, skill: parsed["skill"] }
      else
        # Propagate structured error from PlatformHttpClient
        body   = result[:data] || {}
        code   = body["code"] || body["error"]
        errors = body["errors"]&.join(", ")
        msg    = result[:error] || [code, errors].compact.join(": ")
        msg    = "Upload failed" if msg.to_s.strip.empty?

        # Detect "already exists" conflicts so the caller can offer an overwrite option.
        already_exists = body["code"].to_s.include?("name_taken") ||
                         body["code"].to_s.include?("already") ||
                         result[:error].to_s.include?("HTTP 409")
        { success: false, error: msg, already_exists: already_exists }
      end
    rescue StandardError => e
      { success: false, error: "Network error: #{e.message}" }
    end

    # Fetch the public store skills list from the OpenClacky Cloud API.
    # Requires an activated license for HMAC authentication.
    # Passes scope: "store" to retrieve platform-wide published public skills
    # (not filtered by the authenticated user's own skills).
    # Returns { success: bool, skills: [], error: }.
    #
    # Fetch the creator's own published skills from the platform API.
    # Uses GET /api/v1/client/skills (HMAC-signed, system license only).
    # Returns { success: bool, skills: [], error: }.
    def fetch_my_skills!
      return { success: false, error: "License not activated", skills: [] } unless activated?
      return { success: false, error: "User license required", skills: [] } unless user_licensed?

      user_id   = @license_user_id.to_s
      key_hash  = Digest::SHA256.hexdigest(@license_key)
      ts        = Time.now.utc.to_i.to_s
      nonce     = SecureRandom.hex(16)
      message   = "#{user_id}:#{@device_id}:#{ts}:#{nonce}"
      signature = OpenSSL::HMAC.hexdigest("SHA256", @license_key, message)

      query = URI.encode_www_form(
        key_hash:  key_hash,
        user_id:   user_id,
        device_id: @device_id,
        timestamp: ts,
        nonce:     nonce,
        signature: signature
      )

      response = platform_client.get("/api/v1/client/skills?#{query}")

      if response[:success]
        skills = response[:data]["skills"] || []
        { success: true, skills: skills }
      else
        { success: false, error: response[:error] || "Failed to fetch skills", skills: [] }
      end
    rescue StandardError => e
      { success: false, error: "Network error: #{e.message}", skills: [] }
    end

    # Each skill in the returned array is a hash with at minimum:
    #   "name", "description", "icon", "repo"
    def fetch_store_skills!
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
        signature: signature,
        scope:     "store"
      }

      response = api_post("/api/v1/licenses/skills", payload)

      if response[:success]
        body   = response[:data]
        skills = body["skills"] || []
        { success: true, skills: skills }
      else
        { success: false, error: response[:error] || "Failed to fetch store skills", skills: [] }
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
          # Normalize name to valid skill name format; prefer the matching local installed dir name
          normalized   = skill["name"].to_s.downcase.gsub(/[\s_]+/, "-").gsub(/[^a-z0-9-]/, "").gsub(/-+/, "-")
          name         = installed.keys.find { |k| k == normalized } || normalized
          local        = installed[name]
          # The authoritative "latest" version lives in latest_version.version when present,
          # falling back to the top-level version field for older API responses.
          latest_ver   = (skill["latest_version"] || {})["version"] || skill["version"]
          # Only flag needs_update when the server has a strictly newer version than local.
          # If local >= latest (e.g. a dev build), suppress the update badge.
          needs_update = local ? version_older?(local["version"], latest_ver) : false
          skill.merge(
            "name"              => name,
            "installed_version" => local ? local["version"] : nil,
            "needs_update"      => needs_update
          )
        end
        { success: true, skills: skills, expires_at: body["expires_at"] }
      else
        { success: false, error: response[:error] || "Failed to fetch skills", skills: [] }
      end
    end

    # Install (or update) a single brand skill by downloading and extracting its zip.
    # skill_info: a hash from fetch_brand_skills! with at least name + latest_version.download_url + version
    def install_brand_skill!(skill_info)
      require "net/http"
      require "uri"

      slug    = skill_info["name"].to_s.strip
      version = (skill_info["latest_version"] || {})["version"] || skill_info["version"]
      url     = (skill_info["latest_version"] || {})["download_url"]

      return { success: false, error: "Missing skill name" } if slug.empty?

      if url.nil?
        FileUtils.mkdir_p(File.join(brand_skills_dir, slug))
        return { success: false, error: "No download URL" }
      end

      require "zip"

      dest_dir = File.join(brand_skills_dir, slug)
      FileUtils.mkdir_p(dest_dir)

      # Download the zip file to a temp path via PlatformHttpClient so the
      # primary → fallback host failover applies uniformly to every download.
      tmp_zip = File.join(brand_skills_dir, "#{slug}.zip")
      dl = platform_client.download_file(url, tmp_zip)
      raise dl[:error].to_s unless dl[:success]

      # Extract into dest_dir (overwrite existing files).
      # Auto-detect whether the zip has a single root folder to strip.
      # Uses get_input_stream instead of entry.extract to avoid rubyzip 3.x
      # path-safety restrictions on absolute destination paths.
      # Uses chunked read + size verification for robustness.
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

          # Chunked copy with size verification
          written = 0
          File.open(out, "wb") do |f|
            entry.get_input_stream do |input|
              while (chunk = input.read(65536))
                f.write(chunk)
                written += chunk.bytesize
              end
            end
          end

          # Verify file size matches ZIP entry declaration
          if written != entry.size
            raise "Size mismatch for #{entry.name}: expected #{entry.size}, got #{written}"
          end
        end
      end

      FileUtils.rm_f(tmp_zip)

      # Record installed version in brand_skills.json (including description for
      # offline display when the remote API is unreachable).
      # encrypted: true because the ZIP contains MANIFEST.enc.json + AES-256-GCM encrypted files.
      record_installed_skill(slug, version, skill_info["description"], encrypted: true, description_zh: skill_info["description_zh"], name_zh: skill_info["name_zh"])

      { success: true, name: slug, version: version }
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
    # @param skill_info [Hash] Must include "name", "description", and
    #   optionally "version" and "emoji".
    # @return [Hash] { success: bool, name:, version: }
    def install_mock_brand_skill!(skill_info)
      slug           = skill_info["name"].to_s.strip
      version        = (skill_info["latest_version"] || {})["version"] || skill_info["version"] || "1.0.0"
      name           = slug
      description    = skill_info["description"] || "A private brand skill."
      description_zh = skill_info["description_zh"] || "私有品牌技能。"
      emoji          = skill_info["emoji"] || "⭐"

      return { success: false, error: "Missing skill name" } if slug.empty?

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

      # encrypted: false — mock skills store plain bytes in .enc, no MANIFEST needed.
      record_installed_skill(slug, version, description, encrypted: false, description_zh: description_zh, name_zh: skill_info["name_zh"])
      { success: true, name: slug, version: version }
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
      return nil if ENV["CLACKY_TEST"] == "1"

      Thread.new do
        Thread.current.abort_on_exception = false

        begin
          result = fetch_brand_skills!
          next unless result[:success]

          # Remove locally installed skills that have been deleted on the remote.
          # Compare the set of remote skill names against what is installed locally
          # and delete any skill that no longer exists in the remote catalogue.
          remote_skill_names = result[:skills].map { |s| s["name"] }
          installed_brand_skills.each_key do |local_name|
            delete_brand_skill!(local_name) unless remote_skill_names.include?(local_name)
          end

          # Auto-sync is intentionally limited to skills the user has already
          # installed and that have a newer version available.
          # New skills are never auto-installed — the user must click Install/Update
          # explicitly from the Brand Skills panel.
          installed = installed_brand_skills
          skills_needing_update = result[:skills].select { |s| s["needs_update"] }
          results = skills_needing_update.map do |skill_info|
            install_brand_skill!(skill_info)
          end

          # Even when the version hasn't changed, display metadata (name_zh,
          # description_zh, description) may have been updated on the platform.
          # Patch brand_skills.json in-place without re-downloading the ZIP.
          result[:skills].each do |skill_info|
            name = skill_info["name"]
            next unless installed.key?(name)
            next if skill_info["needs_update"] # already being reinstalled above

            local = installed[name]
            next if local["name_zh"]        == skill_info["name_zh"].to_s &&
                    local["description_zh"] == skill_info["description_zh"].to_s &&
                    local["description"]    == skill_info["description"].to_s

            # Metadata changed — update brand_skills.json without reinstalling.
            record_installed_skill(
              name,
              local["version"],
              skill_info["description"].to_s,
              encrypted:      local["encrypted"] != false,
              description_zh: skill_info["description_zh"].to_s,
              name_zh:        skill_info["name_zh"].to_s
            )
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

    # Remove all locally installed brand skills (encrypted files + metadata).
    # Called on license activation so stale skills from a previous brand cannot
    # linger — they are encrypted with that brand's keys and are inaccessible
    # under the new license anyway.
    def clear_brand_skills!
      dir = brand_skills_dir
      return unless Dir.exist?(dir)

      FileUtils.rm_rf(dir)
      # Also clear in-memory decryption key cache so no stale keys survive
      @decryption_keys.clear if @decryption_keys
    end

    # Remove a single locally installed brand skill by name.
    #
    # Deletes the skill's directory from disk and removes its entry from
    # brand_skills.json.  Also evicts any cached decryption key for that skill
    # so no stale key survives in memory.
    #
    # This is called during background sync when a skill that was previously
    # installed is no longer present in the remote catalogue (i.e. the brand
    # administrator deleted it on the platform side).
    #
    # @param skill_name [String] The slug/name of the skill to remove.
    # @return [void]
    private def delete_brand_skill!(skill_name)
      # Remove files from disk.
      skill_dir = File.join(brand_skills_dir, skill_name)
      FileUtils.rm_rf(skill_dir) if Dir.exist?(skill_dir)

      # Remove entry from brand_skills.json.
      json_path = File.join(brand_skills_dir, "brand_skills.json")
      if File.exist?(json_path)
        registry = JSON.parse(File.read(json_path))
        registry.delete(skill_name)
        File.write(json_path, JSON.generate(registry))
      end

      # Evict cached decryption key (keyed by skill_version_id strings).
      # We don't know the exact version id here, but we can drop any key whose
      # associated manifest lives inside the now-deleted directory (they are
      # already gone from disk).  The simplest safe approach: clear the whole
      # in-memory cache — keys will be re-fetched on next access for surviving
      # skills.
      @decryption_keys&.clear
    rescue StandardError
      # Deletion errors are non-fatal — a stale skill directory is harmless
      # compared to aborting the entire sync operation.
    end

    # Decrypt an encrypted brand skill file and return its content in memory.
    #
    # Security model:
    #   - Skill files are AES-256-GCM encrypted. Each skill directory contains a
    #     MANIFEST.enc.json that stores per-file IV, auth tag, checksum, and the
    #     skill_version_id needed to request the decryption key from the server.
    #   - Decryption keys are requested from the server once and cached in memory
    #     (never written to disk). Subsequent calls for the same skill version are
    #     served entirely from cache without network I/O.
    #   - Decrypted content exists only in memory and is never written to disk.
    #
    # Fallback for mock/plain skills:
    #   When no MANIFEST.enc.json exists in the skill directory, the method falls
    #   back to reading the .enc file as raw UTF-8 bytes (mock/dev mode).
    #
    # @param encrypted_path [String] Path to the .enc file on disk (e.g. ".../name/SKILL.md.enc")
    # @return [String] Decrypted file content (UTF-8)
    # @raise [RuntimeError] If license is not activated or decryption fails
    def decrypt_skill_content(encrypted_path)
      raise "License not activated — cannot decrypt brand skill" unless activated?

      skill_dir    = File.dirname(encrypted_path)
      manifest_path = File.join(skill_dir, "MANIFEST.enc.json")

      # Fall back to plain-bytes mode when no MANIFEST present (mock skills).
      unless File.exist?(manifest_path)
        raw = File.binread(encrypted_path)
        return raw.force_encoding("UTF-8")
      end

      # Read and parse the manifest
      manifest = JSON.parse(File.read(manifest_path))

      skill_id         = manifest["skill_id"]
      skill_version_id = manifest["skill_version_id"]

      raise "MANIFEST.enc.json missing skill_id"         unless skill_id
      raise "MANIFEST.enc.json missing skill_version_id" unless skill_version_id

      # Derive the relative file path (e.g. "SKILL.md") from the .enc filename
      enc_basename = File.basename(encrypted_path)                 # "SKILL.md.enc"
      file_path    = enc_basename.sub(/\.enc\z/, "")               # "SKILL.md"

      file_meta = manifest["files"] && manifest["files"][file_path]
      raise "File '#{file_path}' not found in MANIFEST.enc.json" unless file_meta

      # Fetch decryption key — served from in-memory cache when available
      key = fetch_decryption_key(skill_id: skill_id, skill_version_id: skill_version_id)

      # Decrypt using AES-256-GCM
      ciphertext = File.binread(encrypted_path)
      plaintext  = aes_gcm_decrypt(key, ciphertext, file_meta["iv"], file_meta["tag"])

      # Integrity check
      actual   = Digest::SHA256.hexdigest(plaintext)
      expected = file_meta["original_checksum"]
      if expected && actual != expected
        raise "Checksum mismatch for #{file_path}: " \
              "expected #{expected}, got #{actual}"
      end

      plaintext
    rescue Errno::ENOENT => e
      raise "Brand skill file not found: #{e.message}"
    rescue JSON::ParserError => e
      raise "Invalid MANIFEST.enc.json: #{e.message}"
    end

    # Decrypt all supporting script files for a skill into a temporary directory.
    #
    # Scans `skill_dir` recursively for `*.enc` files, skipping SKILL.md.enc and
    # MANIFEST.enc.json.  Each file is decrypted in memory and written to the
    # corresponding relative path under `dest_dir`.  The decryption key is fetched
    # once (cached) for all files belonging to the same skill version.
    #
    # For mock/plain skills (no MANIFEST.enc.json) the raw bytes are used as-is.
    #
    # @param skill_dir [String] Absolute path to the installed brand skill directory
    # @param dest_dir  [String] Absolute path to the destination directory (tmpdir)
    # @return [Array<String>] Relative paths of all files written to dest_dir
    # @raise [RuntimeError] If license is not activated or decryption fails
    def decrypt_all_scripts(skill_dir, dest_dir)
      raise "License not activated — cannot decrypt brand skill" unless activated?

      manifest_path = File.join(skill_dir, "MANIFEST.enc.json")
      manifest      = File.exist?(manifest_path) ? JSON.parse(File.read(manifest_path)) : nil

      written = []

      # Find all .enc files that are not SKILL.md.enc or the manifest itself
      Dir.glob(File.join(skill_dir, "**", "*.enc")).each do |enc_path|
        basename = File.basename(enc_path)
        next if basename == "SKILL.md.enc"
        next if basename == "MANIFEST.enc.json"

        # Relative path from skill_dir, stripping the .enc suffix
        rel_enc  = enc_path.sub("#{skill_dir}/", "")  # e.g. "scripts/analyze.rb.enc"
        rel_plain = rel_enc.sub(/\.enc\z/, "")          # e.g. "scripts/analyze.rb"

        plaintext = if manifest
          # Read manifest entry using the relative plain path
          file_meta = manifest["files"] && manifest["files"][rel_plain]
          raise "File '#{rel_plain}' not found in MANIFEST.enc.json" unless file_meta

          skill_id         = manifest["skill_id"]
          skill_version_id = manifest["skill_version_id"]
          key = fetch_decryption_key(skill_id: skill_id, skill_version_id: skill_version_id)

          ciphertext = File.binread(enc_path)
          pt         = aes_gcm_decrypt(key, ciphertext, file_meta["iv"], file_meta["tag"])

          # Integrity check
          actual   = Digest::SHA256.hexdigest(pt)
          expected = file_meta["original_checksum"]
          if expected && actual != expected
            raise "Checksum mismatch for #{rel_plain}: expected #{expected}, got #{actual}"
          end

          pt
        else
          # Mock/plain skill: raw bytes
          File.binread(enc_path).force_encoding("UTF-8")
        end

        out_path = File.join(dest_dir, rel_plain)
        FileUtils.mkdir_p(File.dirname(out_path))
        File.write(out_path, plaintext)
        # Preserve executable permission hint from extension
        File.chmod(0o700, out_path)
        written << rel_plain
      end

      written
    rescue Errno::ENOENT => e
      raise "Brand skill file not found: #{e.message}"
    rescue JSON::ParserError => e
      raise "Invalid MANIFEST.enc.json: #{e.message}"
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
    # Returns a hash keyed by name: { "version" => "1.0.0", "name" => "..." }
    def installed_brand_skills
      path = File.join(brand_skills_dir, "brand_skills.json")
      return {} unless File.exist?(path)

      raw = JSON.parse(File.read(path))

      # Validate each entry against the actual file system.
      valid   = {}
      changed = false

      raw.each do |name, meta|
        skill_dir = File.join(brand_skills_dir, name)
        has_files = Dir.exist?(skill_dir) &&
                    Dir.glob(File.join(skill_dir, "SKILL.md{,.enc}")).any?

        if has_files
          valid[name] = meta
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

    # Path to the upload_meta.json file that tracks which local skills have been
    # published to the platform and what version they were uploaded as.
    #
    # Format:
    #   {
    #     "commit"     => { "platform_version" => "1.2.0", "uploaded_at" => "2026-04-09T..." },
    #     "nss-upload" => { "platform_version" => "1.0.0", "uploaded_at" => "..." }
    #   }
    UPLOAD_META_FILE = File.join(Dir.home, ".clacky", "skills", "upload_meta.json").freeze

    # Load upload metadata for all published local skills.
    # @return [Hash{String => Hash}]
    def self.load_upload_meta
      return {} unless File.exist?(UPLOAD_META_FILE)

      JSON.parse(File.read(UPLOAD_META_FILE))
    rescue StandardError
      {}
    end

    # Persist a single skill's upload record.
    # @param skill_name [String]
    # @param platform_version [String]
    def self.record_upload!(skill_name, platform_version)
      meta = load_upload_meta
      meta[skill_name] = {
        "platform_version" => platform_version,
        "uploaded_at"      => Time.now.utc.iso8601
      }
      dir = File.dirname(UPLOAD_META_FILE)
      FileUtils.mkdir_p(dir)
      File.write(UPLOAD_META_FILE, JSON.generate(meta))
    rescue StandardError
      # Non-fatal — metadata write failure should not break the upload flow
    end

    # Returns a hash representation for JSON serialization (e.g. /api/brand).
    def to_h
      {
        product_name:       @product_name,
        package_name:       @package_name,
        logo_url:           @logo_url,
        support_contact:    @support_contact,
        support_qr_url:     @support_qr_url,
        theme_color:        @theme_color,
        homepage_url:       @homepage_url,
        branded:            branded?,
        activated:          activated?,
        expired:            expired?,
        license_expires_at: @license_expires_at&.iso8601,
        user_licensed:      user_licensed?,
        license_user_id:    @license_user_id
      }
    end


    def to_yaml
      data = {}
      data["product_name"]           = @product_name           if @product_name
      data["package_name"]           = @package_name           if @package_name
      data["logo_url"]               = @logo_url               if @logo_url
      data["support_contact"]        = @support_contact        if @support_contact
      data["support_qr_url"]         = @support_qr_url         if @support_qr_url
      data["theme_color"]            = @theme_color            if @theme_color
      data["homepage_url"]           = @homepage_url           if @homepage_url
      data["license_key"]            = @license_key            if @license_key
      data["license_activated_at"]   = @license_activated_at.iso8601   if @license_activated_at
      data["license_expires_at"]     = @license_expires_at.iso8601     if @license_expires_at
      data["license_last_heartbeat"] = @license_last_heartbeat.iso8601 if @license_last_heartbeat
      data["device_id"]              = @device_id              if @device_id
      # Persist user_id so user-licensed features remain available across restarts
      data["license_user_id"]        = @license_user_id        if @license_user_id && !@license_user_id.strip.empty?
      YAML.dump(data)
    end

    # Compare two semver strings. Returns true when `installed` is strictly
    # older than `latest` (i.e. the server has a newer version available).
    # Returns false when installed >= latest, or when either version is blank/nil,
    # so a local dev build never shows a spurious "Update" badge.
    def self.version_older?(installed, latest)
      return false if installed.to_s.strip.empty? || latest.to_s.strip.empty?

      Gem::Version.new(installed.to_s.strip) < Gem::Version.new(latest.to_s.strip)
    rescue ArgumentError
      # Unparseable version strings — treat as "not older" to avoid false positives
      false
    end

    # Instance-level delegate so fetch_brand_skills! can call version_older? directly.
    private def version_older?(installed, latest)
      self.class.version_older?(installed, latest)
    end

    # Apply distribution fields from API response.
    # Updates product_name, package_name, logo_url, support_contact, support_qr_url,
    # theme_color, and homepage_url from the distribution hash.
    private def apply_distribution(dist)
      return unless dist.is_a?(Hash)

      @product_name    = dist["product_name"]   if dist["product_name"].to_s.strip != ""
      @package_name    = dist["package_name"]   if dist["package_name"].to_s.strip != ""
      @logo_url        = dist["logo_url"]        if dist["logo_url"].to_s.strip != ""
      @support_contact = dist["support_contact"] if dist["support_contact"].to_s.strip != ""
      @support_qr_url  = dist["support_qr_url"]  if dist.key?("support_qr_url")
      @theme_color     = dist["theme_color"]      if dist.key?("theme_color")
      @homepage_url    = dist["homepage_url"]     if dist.key?("homepage_url")
    end

    # Download a remote URL to a local file path.
    #
    # Deprecated: this method now delegates to
    # Clacky::PlatformHttpClient#download_file so that every brand-skill download
    # benefits from primary → fallback host failover. Kept as a thin wrapper
    # so existing callers / tests that stub it continue to work.
    private def download_file(url, dest, max_redirects: 10)
      result = platform_client.download_file(url, dest)
      raise result[:error].to_s unless result[:success]
    end

    # Persist installed skill metadata to brand_skills.json.
    #
    # encrypted: true  → skill files are AES-256-GCM encrypted; MANIFEST.enc.json
    #                    is present in the skill directory and must be used for decryption.
    # encrypted: false → mock/plain skill; SKILL.md.enc contains raw UTF-8 bytes.
    #
    # description is stored so it can be shown locally even when the remote API
    # is unreachable (e.g. offline or license server down).
    #
    # The stored `name` must be a valid skill name (lowercase letters, numbers,
    # hyphens only; no leading/trailing hyphens) because it is used as the
    # slash command identifier (/name).  We sanitize aggressively here so that
    # bad data from the platform never reaches the local registry:
    #
    #   1. name already valid            → use name as-is
    #   2. name invalid — sanitize       → downcase, spaces→hyphens, strip illegal chars
    #   3. still invalid after sanitize  → raise, caller gets { success: false }
    private def record_installed_skill(name, version, description = nil, encrypted: true, description_zh: nil, name_zh: nil)
      safe_name = sanitize_skill_name(name)

      FileUtils.mkdir_p(brand_skills_dir)
      path      = File.join(brand_skills_dir, "brand_skills.json")
      installed = installed_brand_skills
      installed[safe_name] = {
        "version"        => version,
        "name"           => safe_name,
        "name_zh"        => name_zh.to_s,
        "description"    => description.to_s,
        "description_zh" => description_zh.to_s,
        "encrypted"      => encrypted,
        "installed_at"   => Time.now.utc.iso8601
      }
      File.write(path, JSON.generate(installed))
    end

    # Normalize a skill name to a valid identifier (lowercase letters, numbers, hyphens).
    # @param name [String, nil] Raw name from platform
    # @return [String] A valid skill name
    # @raise [RuntimeError] When sanitization still yields an invalid name
    private def sanitize_skill_name(name)
      valid_name = ->(s) { s.to_s.match?(/\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/) || s.to_s.match?(/\A[a-z0-9]\z/) }

      # 1. name already valid
      return name if valid_name.call(name)

      # 2. name invalid — sanitize: downcase, spaces/underscores → hyphens, strip illegal chars
      sanitized = name.to_s
        .downcase
        .gsub(/[\s_]+/, "-")
        .gsub(/[^a-z0-9-]/, "")
        .gsub(/-+/, "-")
        .gsub(/\A-+|-+\z/, "")

      if valid_name.call(sanitized)
        Clacky::Logger.warn(
          "Brand skill name '#{name}' is not a valid name; sanitized to '#{sanitized}'."
        )
        return sanitized
      end

      # 3. still invalid — refuse to write garbage into the registry
      raise "Cannot derive a valid skill name from '#{name}'. " \
            "Expected lowercase letters, numbers, and hyphens (e.g. 'my-skill')."
    end

    # Fetch the AES-256-GCM decryption key for a skill version from the server.
    #
    # Keys are cached in memory by "skill_id:skill_version_id" for the duration
    # of the process lifetime.  The cache is never written to disk.
    #
    # Cache validity:
    #   - Served from cache when key has not expired AND last server contact was
    #     within HEARTBEAT_GRACE_PERIOD (3 days).  This lets skills work offline
    #     for up to 3 days after the last successful heartbeat.
    #
    # @param skill_id         [Integer]
    # @param skill_version_id [Integer]
    # @return [String] 32-byte binary decryption key
    # @raise [RuntimeError] on network or auth failure
    private def fetch_decryption_key(skill_id:, skill_version_id:)
      cache_key = "#{skill_id}:#{skill_version_id}"
      cached    = @decryption_keys[cache_key]

      # Serve from cache when key is still valid and we're within the grace period
      if cached
        within_grace = @last_server_contact_at &&
                       (Time.now.utc - @last_server_contact_at) < HEARTBEAT_GRACE_PERIOD
        key_valid    = Time.now.utc < cached[:expires_at]

        return cached[:key] if key_valid && within_grace
      end

      # Guard: @device_id must match the value recorded in activated_devices on the
      # server.  If it is nil (e.g. loaded from a brand.yml that predates the
      # device_id field), reload from disk as a last-chance recovery — the file
      # may have been written by a concurrent process or a newer gem version.
      # If still nil after reload, raise an actionable error rather than sending
      # an empty device_id that will always be rejected by the server.
      if @device_id.nil? || @device_id.strip.empty?
        reloaded = BrandConfig.load
        @device_id = reloaded.device_id if reloaded.device_id && !reloaded.device_id.strip.empty?
      end
      raise "Device ID is missing. Please re-activate your license with `clacky license activate`." \
        if @device_id.nil? || @device_id.strip.empty?

      # Build signed request payload
      user_id   = parse_user_id_from_key(@license_key)
      key_hash  = Digest::SHA256.hexdigest(@license_key)
      ts        = Time.now.utc.to_i.to_s
      nonce     = SecureRandom.hex(16)
      message   = "#{user_id}:#{@device_id}:#{ts}:#{nonce}"
      signature = OpenSSL::HMAC.hexdigest("SHA256", @license_key, message)

      payload = {
        key_hash:         key_hash,
        user_id:          user_id.to_s,
        device_id:        @device_id,
        timestamp:        ts,
        nonce:            nonce,
        signature:        signature,
        skill_id:         skill_id,
        skill_version_id: skill_version_id
      }

      response = api_post("/api/v1/licenses/skill_keys", payload)
      raise "Brand skill decrypt failed: #{response[:error]}" unless response[:success]

      data       = response[:data]
      key_bytes  = [data["decryption_key"]].pack("H*")
      expires_at = data["expires_at"] ? parse_time(data["expires_at"]) : Time.now.utc + 365 * 86_400

      @decryption_keys[cache_key] = { key: key_bytes, expires_at: expires_at }
      @last_server_contact_at = Time.now.utc

      key_bytes
    end

    # Decrypt ciphertext using AES-256-GCM.
    # @param key        [String] 32-byte binary key
    # @param ciphertext [String] Encrypted binary data
    # @param iv_b64     [String] Base64-encoded 12-byte IV
    # @param tag_b64    [String] Base64-encoded 16-byte auth tag
    # @return [String] Decrypted plaintext (UTF-8)
    # @raise [RuntimeError] on decryption failure (wrong key, tampered data)
    private def aes_gcm_decrypt(key, ciphertext, iv_b64, tag_b64)
      require "base64"
      require_relative "aes_gcm"

      iv  = Base64.strict_decode64(iv_b64)
      tag = Base64.strict_decode64(tag_b64)

      # Try native OpenSSL AES-GCM first (fastest path; works on real OpenSSL).
      # LibreSSL 3.3.x has a known bug where AES-GCM raises CipherError even
      # for valid inputs, so we fall back to the pure-Ruby implementation.
      begin
        cipher          = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key      = key
        cipher.iv       = iv
        cipher.auth_tag = tag
        (cipher.update(ciphertext) + cipher.final).force_encoding("UTF-8")
      rescue OpenSSL::Cipher::CipherError
        # Native GCM failed — use pure-Ruby fallback (LibreSSL-safe)
        Clacky::AesGcm.decrypt(key, iv, ciphertext, tag)
      end
    rescue OpenSSL::Cipher::CipherError => e
      raise "Decryption failed: #{e.message}. " \
            "The file may be corrupted or the license key is incorrect."
    end

    # Parse user_id from the License Key structure.
    # Key format: UUUUUUUU-PPPPPPPP-RRRRRRRR-RRRRRRRR-CCCCCCCC
    private def parse_user_id_from_key(key)
      hex = key.delete("-").upcase
      hex[0..7].to_i(16)
    end

    # Generate a one-time stable device ID based on system identifiers.
    #
    # IMPORTANT: This method MUST only be called once — during the very first
    # activation — via `@device_id ||= generate_device_id`.  The result is
    # immediately persisted to brand.yml by `save`.  All subsequent calls
    # (heartbeat, skill_keys, etc.) must read @device_id from memory (which was
    # populated by `initialize` from the stored brand.yml), never call this
    # method again.
    #
    # The generated ID is deterministic for the same environment, but can change
    # if the hostname, user, or platform changes (e.g. inside a Docker container
    # with a random hostname).  That is why we pin it to disk immediately and
    # never regenerate once saved.
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

    # POST JSON to the platform API with automatic retry and domain failover.
    # Returns { success:, data:, error: }.
    private def api_post(path, payload)
      platform_client.post(path, payload)
    end

    # Lazy-initialised PlatformHttpClient. Host selection is automatic.
    private def platform_client
      @platform_client ||= Clacky::PlatformHttpClient.new
    end
  end
end
