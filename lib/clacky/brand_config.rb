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

    # OpenClacky Cloud API base URL
    API_BASE_URL = "https://www.openclacky.com"

    # How often to send a heartbeat (seconds) — once per day
    HEARTBEAT_INTERVAL = 86_400

    # Grace period for offline heartbeat failures (3 days)
    HEARTBEAT_GRACE_PERIOD = 3 * 86_400

    attr_reader :brand_name, :license_key, :license_activated_at,
                :license_expires_at, :license_last_heartbeat, :device_id,
                :brand_command, :distribution_name, :product_name,
                :logo_url, :support_contact, :license_user_id,
                :support_qr_url, :theme_color, :homepage_url

    def initialize(attrs = {})
      @brand_name              = attrs["brand_name"]
      @brand_command           = attrs["brand_command"]
      @distribution_name       = attrs["distribution_name"]
      @product_name            = attrs["product_name"]
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
        # Save owner_user_id returned by the server when the license is bound to a specific user.
        # Server returns "owner_user_id" for system licenses; plan-based licenses return nil.
        owner_uid = data["owner_user_id"]
        @license_user_id = owner_uid.to_s.strip if owner_uid && !owner_uid.to_s.strip.empty?
        # Pin the device_id used in this activation request so that future API calls
        # (e.g. skill_keys, heartbeat) always send the exact same device_id that was
        # recorded in activated_devices on the server side.
        # If the server echoes back device_id in the response, prefer that value;
        # otherwise keep the one we just sent (@device_id is already set above).
        server_device_id = data["device_id"].to_s.strip
        @device_id = server_device_id unless server_device_id.empty?
        apply_distribution(data["distribution"])
        save
        { success: true, message: "License activated successfully!", brand_name: @brand_name,
          user_id: @license_user_id, data: data }
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
      # Pin a stable device_id for this activation. Once set (from a prior load or
      # a previous call), never regenerate — the same rule as activate!.
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

    # Upload (publish) a custom skill ZIP to the OpenClacky Cloud API.
    # Calls POST /api/v1/client/skills (system-license endpoint).
    # zip_data is the raw binary content of the ZIP file.
    # Returns { success: bool, error: String }.
    # Upload a skill ZIP to the OpenClacky cloud.
    # skill_name: slug string
    # zip_data:   binary ZIP content
    # force:      when true, use PATCH to overwrite an existing skill instead of POST
    #
    # Returns { success: true, skill: {...} } or { success: false, error: "...", already_exists: true/false }
    def upload_skill!(skill_name, zip_data, force: false, version_override: nil)
      return { success: false, error: "License not activated" } unless activated?
      return { success: false, error: "User license required to upload skills" } unless user_licensed?

      require "net/http"
      require "uri"

      # The client skills API uses @license_user_id (the platform owner user id),
      # NOT the user_id embedded in the license key structure.
      user_id   = @license_user_id.to_s
      key_hash  = Digest::SHA256.hexdigest(@license_key)
      ts        = Time.now.utc.to_i.to_s
      nonce     = SecureRandom.hex(16)
      message   = "#{user_id}:#{@device_id}:#{ts}:#{nonce}"
      signature = OpenSSL::HMAC.hexdigest("SHA256", @license_key, message)

      # POST /api/v1/client/skills        → create (first upload)
      # PATCH /api/v1/client/skills/:slug → update (force overwrite)
      if force
        uri = URI.parse("#{API_BASE_URL}/api/v1/client/skills/#{URI.encode_www_form_component(skill_name)}")
      else
        uri = URI.parse("#{API_BASE_URL}/api/v1/client/skills")
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl       = uri.scheme == "https"
      http.open_timeout  = 15
      http.read_timeout  = 60

      boundary = "----ClackySkillUpload#{SecureRandom.hex(8)}"
      crlf     = "\r\n"

      # Build multipart body as a binary string using Array#pack so that null bytes
      # in the ZIP data are preserved. Net::HTTP's body= raises on null bytes in
      # the body string — avoid by writing all parts as binary and using body_stream.
      parts = []
      fields = {
        "key_hash"  => key_hash,
        "user_id"   => user_id,
        "device_id" => @device_id,
        "timestamp" => ts,
        "nonce"     => nonce,
        "signature" => signature,
        "slug"      => skill_name.to_s
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
      # zip_data is binary — keep as-is
      parts << zip_data.b
      parts << "#{crlf}--#{boundary}--#{crlf}"

      # Concatenate all parts as a single binary string
      body_bytes = parts.map { |p| p.b }.join

      request = force ? Net::HTTP::Patch.new(uri.path) : Net::HTTP::Post.new(uri.path)
      request["Content-Type"]   = "multipart/form-data; boundary=#{boundary}"
      request["Content-Length"] = body_bytes.bytesize.to_s
      request.body_stream = StringIO.new(body_bytes)

      response = http.request(request)
      parsed   = JSON.parse(response.body) rescue {}

      code_i = response.code.to_i
      if code_i == 200 || code_i == 201
        { success: true, skill: parsed["skill"] }
      else
        # Server returns { status: "error", code: "...", errors: [...] }
        code   = parsed["code"] || parsed["error"]
        errors = parsed["errors"]&.join(", ")
        msg    = [code, errors].compact.join(": ")
        msg    = "Upload failed (HTTP #{response.code})" if msg.empty?

        # Detect "already exists" conflicts (HTTP 409 or slug_taken error code)
        # so the caller can offer the user an overwrite option.
        already_exists = code_i == 409 || code.to_s.include?("slug_taken") || code.to_s.include?("already")
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
    # Each skill in the returned array is a hash with at minimum:
    #   "slug", "name", "description", "icon", "repo"
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
          slug         = skill["slug"] || skill["name"]&.downcase&.gsub(/\s+/, "-")
          local        = installed[slug]
          # The authoritative "latest" version lives in latest_version.version when present,
          # falling back to the top-level version field for older API responses.
          latest_ver   = (skill["latest_version"] || {})["version"] || skill["version"]
          # Only flag needs_update when the server has a strictly newer version than local.
          # If local >= latest (e.g. a dev build), suppress the update badge.
          needs_update = local ? version_older?(local["version"], latest_ver) : false
          skill.merge(
            "slug"              => slug,
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

      # Record installed version in brand_skills.json (including description for
      # offline display when the remote API is unreachable).
      # encrypted: true because the ZIP contains MANIFEST.enc.json + AES-256-GCM encrypted files.
      record_installed_skill(slug, version, skill_info["name"], skill_info["description"], encrypted: true)

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

      # encrypted: false — mock skills store plain bytes in .enc, no MANIFEST needed.
      record_installed_skill(slug, version, name, description, encrypted: false)
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
      return nil if ENV["CLACKY_TEST"] == "1"

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
    # @param encrypted_path [String] Path to the .enc file on disk (e.g. ".../slug/SKILL.md.enc")
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

    private

    def to_yaml
      data = {}
      data["brand_name"]             = @brand_name             if @brand_name
      data["brand_command"]          = @brand_command          if @brand_command
      data["distribution_name"]      = @distribution_name      if @distribution_name
      data["product_name"]           = @product_name           if @product_name
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
    # Updates name, product_name, logo_url, support_contact, support_qr_url,
    # theme_color, and homepage_url from the distribution hash.
    private def apply_distribution(dist)
      return unless dist.is_a?(Hash)

      @distribution_name = dist["name"]            if dist["name"].to_s.strip != ""
      @product_name      = dist["product_name"]    if dist["product_name"].to_s.strip != ""
      @logo_url          = dist["logo_url"]         if dist["logo_url"].to_s.strip != ""
      @support_contact   = dist["support_contact"]  if dist["support_contact"].to_s.strip != ""
      # New branding fields returned by the API (logo, QR code, theme, homepage)
      @support_qr_url    = dist["support_qr_url"]   if dist.key?("support_qr_url")
      @theme_color       = dist["theme_color"]       if dist.key?("theme_color")
      @homepage_url      = dist["homepage_url"]      if dist.key?("homepage_url")
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
    #
    # encrypted: true  → skill files are AES-256-GCM encrypted; MANIFEST.enc.json
    #                    is present in the skill directory and must be used for decryption.
    # encrypted: false → mock/plain skill; SKILL.md.enc contains raw UTF-8 bytes.
    #
    # description is stored so it can be shown locally even when the remote API
    # is unreachable (e.g. offline or license server down).
    private def record_installed_skill(slug, version, name, description = nil, encrypted: true)
      FileUtils.mkdir_p(brand_skills_dir)
      path      = File.join(brand_skills_dir, "brand_skills.json")
      installed = installed_brand_skills
      installed[slug] = {
        "version"      => version,
        "name"         => name,
        "description"  => description.to_s,
        "encrypted"    => encrypted,
        "installed_at" => Time.now.utc.iso8601
      }
      File.write(path, JSON.generate(installed))
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
      raise "Failed to fetch decryption key: #{response[:error]}" unless response[:success]

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
      cipher          = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key      = key
      cipher.iv       = Base64.strict_decode64(iv_b64)
      cipher.auth_tag = Base64.strict_decode64(tag_b64)
      (cipher.update(ciphertext) + cipher.final).force_encoding("UTF-8")
    rescue OpenSSL::Cipher::CipherError => e
      raise "AES-256-GCM decryption failed: #{e.message}. " \
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
