# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "openssl"
require "base64"
require "digest"
require "json"

# Tests for BrandConfig#decrypt_skill_content AES-256-GCM path,
# fetch_decryption_key caching, and all error branches.
#
# These tests use real OpenSSL encryption so they exercise the actual
# crypto path, not just the mock/plain-bytes fallback.

RSpec.describe Clacky::BrandConfig, "#decrypt_skill_content (AES-256-GCM)" do
  # ── Helpers ────────────────────────────────────────────────────────────────

  # A fixed 32-byte key for tests (never changes across runs → deterministic)
  let(:test_key) { OpenSSL::Random.random_bytes(32) }
  let(:test_key_hex) { test_key.unpack1("H*") }

  # Encrypt plaintext with AES-256-GCM; returns { ciphertext, iv_b64, tag_b64, checksum }
  def aes_gcm_encrypt(key, plaintext)
    cipher         = OpenSSL::Cipher.new("aes-256-gcm").encrypt
    cipher.key     = key
    iv             = cipher.random_iv
    cipher.auth_data = ""
    ciphertext     = cipher.update(plaintext) + cipher.final
    tag            = cipher.auth_tag

    {
      ciphertext:  ciphertext,
      iv_b64:      Base64.strict_encode64(iv),
      tag_b64:     Base64.strict_encode64(tag),
      checksum:    Digest::SHA256.hexdigest(plaintext)
    }
  end

  # Build a minimal MANIFEST.enc.json on disk.
  def write_manifest(dir, skill_id:, skill_version_id:, file_path:, iv_b64:, tag_b64:, checksum:)
    manifest = {
      "manifest_version"  => "1",
      "algorithm"         => "aes-256-gcm",
      "skill_id"          => skill_id,
      "skill_version_id"  => skill_version_id,
      "files"             => {
        file_path => {
          "encrypted_path"    => "#{file_path}.enc",
          "iv"                => iv_b64,
          "tag"               => tag_b64,
          "original_checksum" => checksum
        }
      }
    }
    File.write(File.join(dir, "MANIFEST.enc.json"), JSON.generate(manifest))
  end

  # Returns an activated BrandConfig backed by a temp dir.
  def activated_config(config_dir)
    stub_const("Clacky::BrandConfig::CONFIG_DIR", config_dir)
    stub_const("Clacky::BrandConfig::BRAND_FILE",  File.join(config_dir, "brand.yml"))
    Clacky::BrandConfig.new(
      "brand_name"           => "TestBrand",
      "license_key"          => "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4",
      "license_activated_at" => Time.now.utc.iso8601,
      "license_expires_at"   => (Time.now.utc + 86_400).iso8601,
      "device_id"            => "testdevice"
    )
  end

  # Stub api_post so fetch_decryption_key returns the given key without network I/O.
  def stub_key_server(config, key_hex, expires_at: Time.now.utc + 86_400)
    allow(config).to receive(:api_post)
      .with("/api/v1/licenses/skill_keys", anything)
      .and_return({
        success: true,
        data: {
          "decryption_key" => key_hex,
          "algorithm"      => "aes-256-gcm",
          "expires_at"     => expires_at.iso8601,
          "grace_period_hours" => 72
        }
      })
  end

  # ── AES-256-GCM roundtrip ──────────────────────────────────────────────────

  describe "real AES-256-GCM decrypt" do
    it "decrypts SKILL.md.enc produced by AES-256-GCM and returns UTF-8 plaintext" do
      Dir.mktmpdir do |tmp|
        config    = activated_config(tmp)
        plaintext = "---\nname: my-skill\n---\nHello encrypted world!"
        enc       = aes_gcm_encrypt(test_key, plaintext)

        skill_dir = File.join(tmp, "my-skill")
        FileUtils.mkdir_p(skill_dir)
        File.binwrite(File.join(skill_dir, "SKILL.md.enc"), enc[:ciphertext])
        write_manifest(skill_dir,
          skill_id:         42,
          skill_version_id: 7,
          file_path:        "SKILL.md",
          iv_b64:           enc[:iv_b64],
          tag_b64:          enc[:tag_b64],
          checksum:         enc[:checksum])

        stub_key_server(config, test_key_hex)

        result = config.decrypt_skill_content(File.join(skill_dir, "SKILL.md.enc"))

        expect(result).to eq(plaintext)
        expect(result.encoding.name).to eq("UTF-8")
      end
    end

    it "decrypts any binary-safe content (multi-line, special chars)" do
      Dir.mktmpdir do |tmp|
        config    = activated_config(tmp)
        plaintext = "Line 1\nLínea 2\nLine 3 – special: <>&\"'`\n"
        enc       = aes_gcm_encrypt(test_key, plaintext)

        skill_dir = File.join(tmp, "intl-skill")
        FileUtils.mkdir_p(skill_dir)
        File.binwrite(File.join(skill_dir, "SKILL.md.enc"), enc[:ciphertext])
        write_manifest(skill_dir,
          skill_id: 1, skill_version_id: 1,
          file_path: "SKILL.md",
          iv_b64: enc[:iv_b64], tag_b64: enc[:tag_b64], checksum: enc[:checksum])

        stub_key_server(config, test_key_hex)

        result = config.decrypt_skill_content(File.join(skill_dir, "SKILL.md.enc"))
        expect(result).to eq(plaintext)
      end
    end
  end

  # ── MANIFEST error branches ────────────────────────────────────────────────

  describe "MANIFEST validation errors" do
    it "raises when MANIFEST is missing skill_id" do
      Dir.mktmpdir do |tmp|
        config    = activated_config(tmp)
        plaintext = "content"
        enc       = aes_gcm_encrypt(test_key, plaintext)

        skill_dir = File.join(tmp, "bad-skill")
        FileUtils.mkdir_p(skill_dir)
        File.binwrite(File.join(skill_dir, "SKILL.md.enc"), enc[:ciphertext])

        # Manifest with no skill_id
        manifest = {
          "skill_version_id" => 7,
          "files" => { "SKILL.md" => { "iv" => enc[:iv_b64], "tag" => enc[:tag_b64] } }
        }
        File.write(File.join(skill_dir, "MANIFEST.enc.json"), JSON.generate(manifest))

        expect { config.decrypt_skill_content(File.join(skill_dir, "SKILL.md.enc")) }
          .to raise_error(RuntimeError, /missing skill_id/)
      end
    end

    it "raises when MANIFEST is missing skill_version_id" do
      Dir.mktmpdir do |tmp|
        config    = activated_config(tmp)
        plaintext = "content"
        enc       = aes_gcm_encrypt(test_key, plaintext)

        skill_dir = File.join(tmp, "bad-skill2")
        FileUtils.mkdir_p(skill_dir)
        File.binwrite(File.join(skill_dir, "SKILL.md.enc"), enc[:ciphertext])

        manifest = {
          "skill_id" => 42,
          "files" => { "SKILL.md" => { "iv" => enc[:iv_b64], "tag" => enc[:tag_b64] } }
        }
        File.write(File.join(skill_dir, "MANIFEST.enc.json"), JSON.generate(manifest))

        expect { config.decrypt_skill_content(File.join(skill_dir, "SKILL.md.enc")) }
          .to raise_error(RuntimeError, /missing skill_version_id/)
      end
    end

    it "raises when the file path is not listed in MANIFEST files section" do
      Dir.mktmpdir do |tmp|
        config    = activated_config(tmp)
        plaintext = "content"
        enc       = aes_gcm_encrypt(test_key, plaintext)

        skill_dir = File.join(tmp, "bad-skill3")
        FileUtils.mkdir_p(skill_dir)
        File.binwrite(File.join(skill_dir, "SKILL.md.enc"), enc[:ciphertext])

        # MANIFEST lists "OTHER.md" but not "SKILL.md"
        manifest = {
          "skill_id" => 42, "skill_version_id" => 7,
          "files" => { "OTHER.md" => { "iv" => enc[:iv_b64], "tag" => enc[:tag_b64] } }
        }
        File.write(File.join(skill_dir, "MANIFEST.enc.json"), JSON.generate(manifest))

        stub_key_server(config, test_key_hex)

        expect { config.decrypt_skill_content(File.join(skill_dir, "SKILL.md.enc")) }
          .to raise_error(RuntimeError, /not found in MANIFEST/)
      end
    end

    it "raises when MANIFEST.enc.json contains invalid JSON" do
      Dir.mktmpdir do |tmp|
        config    = activated_config(tmp)
        skill_dir = File.join(tmp, "corrupt-skill")
        FileUtils.mkdir_p(skill_dir)
        File.binwrite(File.join(skill_dir, "SKILL.md.enc"), "junk")
        File.write(File.join(skill_dir, "MANIFEST.enc.json"), "{ not valid json }")

        expect { config.decrypt_skill_content(File.join(skill_dir, "SKILL.md.enc")) }
          .to raise_error(RuntimeError, /Invalid MANIFEST/)
      end
    end
  end

  # ── fetch_decryption_key ───────────────────────────────────────────────────

  describe "fetch_decryption_key" do
    def build_encrypted_skill(tmp, key, skill_id: 42, skill_version_id: 7)
      plaintext = "skill body"
      enc       = aes_gcm_encrypt(key, plaintext)
      skill_dir = File.join(tmp, "my-skill")
      FileUtils.mkdir_p(skill_dir)
      File.binwrite(File.join(skill_dir, "SKILL.md.enc"), enc[:ciphertext])
      write_manifest(skill_dir,
        skill_id: skill_id, skill_version_id: skill_version_id,
        file_path: "SKILL.md",
        iv_b64: enc[:iv_b64], tag_b64: enc[:tag_b64], checksum: enc[:checksum])
      { skill_dir: skill_dir, plaintext: plaintext }
    end

    it "returns the decryption key from the server on first call" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_encrypted_skill(tmp, test_key)

        stub_key_server(config, test_key_hex)

        result = config.decrypt_skill_content(File.join(info[:skill_dir], "SKILL.md.enc"))
        expect(result).to eq("skill body")
      end
    end

    it "raises when server returns failure" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_encrypted_skill(tmp, test_key)

        allow(config).to receive(:api_post)
          .with("/api/v1/licenses/skill_keys", anything)
          .and_return({ success: false, error: "rate_limited", data: {} })

        expect { config.decrypt_skill_content(File.join(info[:skill_dir], "SKILL.md.enc")) }
          .to raise_error(RuntimeError, /Failed to fetch decryption key.*rate_limited/)
      end
    end

    it "raises when network is unreachable (api_post returns network error)" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_encrypted_skill(tmp, test_key)

        allow(config).to receive(:api_post)
          .with("/api/v1/licenses/skill_keys", anything)
          .and_return({ success: false, error: "Network error: connection refused", data: {} })

        expect { config.decrypt_skill_content(File.join(info[:skill_dir], "SKILL.md.enc")) }
          .to raise_error(RuntimeError, /Failed to fetch decryption key/)
      end
    end

    it "serves key from cache on second call without hitting the server again" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_encrypted_skill(tmp, test_key)

        # Server should only be called once
        expect(config).to receive(:api_post)
          .with("/api/v1/licenses/skill_keys", anything)
          .once
          .and_return({
            success: true,
            data: {
              "decryption_key" => test_key_hex,
              "expires_at"     => (Time.now.utc + 86_400).iso8601
            }
          })

        enc_path = File.join(info[:skill_dir], "SKILL.md.enc")
        config.decrypt_skill_content(enc_path)  # first call → hits server
        config.decrypt_skill_content(enc_path)  # second call → cache hit
      end
    end

    it "re-fetches key when cached key has expired" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_encrypted_skill(tmp, test_key)

        call_count = 0
        allow(config).to receive(:api_post)
          .with("/api/v1/licenses/skill_keys", anything) do
            call_count += 1
            {
              success: true,
              data: {
                "decryption_key" => test_key_hex,
                # Key expired 1 second ago → cache should be invalidated
                "expires_at" => (Time.now.utc - 1).iso8601
              }
            }
          end

        enc_path = File.join(info[:skill_dir], "SKILL.md.enc")
        config.decrypt_skill_content(enc_path)  # first call
        config.decrypt_skill_content(enc_path)  # second call — key expired, re-fetches

        expect(call_count).to eq(2)
      end
    end

    it "serves from cache within grace period even after last_server_contact is old" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_encrypted_skill(tmp, test_key)

        # First call: server responds, sets last_server_contact_at
        expect(config).to receive(:api_post)
          .with("/api/v1/licenses/skill_keys", anything)
          .once
          .and_return({
            success: true,
            data: {
              "decryption_key" => test_key_hex,
              "expires_at"     => (Time.now.utc + 86_400).iso8601
            }
          })

        enc_path = File.join(info[:skill_dir], "SKILL.md.enc")
        config.decrypt_skill_content(enc_path)  # hits server

        # Simulate last_server_contact_at being 2 days ago (within 3-day grace period)
        config.instance_variable_set(:@last_server_contact_at, Time.now.utc - 2 * 86_400)

        config.decrypt_skill_content(enc_path)  # still within grace period → cache hit
      end
    end

    it "re-fetches key when grace period has elapsed" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_encrypted_skill(tmp, test_key)

        call_count = 0
        allow(config).to receive(:api_post)
          .with("/api/v1/licenses/skill_keys", anything) do
            call_count += 1
            {
              success: true,
              data: {
                "decryption_key" => test_key_hex,
                "expires_at"     => (Time.now.utc + 86_400).iso8601
              }
            }
          end

        enc_path = File.join(info[:skill_dir], "SKILL.md.enc")
        config.decrypt_skill_content(enc_path)  # first call → server

        # Simulate last_server_contact_at 4 days ago (beyond 3-day grace period)
        config.instance_variable_set(:@last_server_contact_at, Time.now.utc - 4 * 86_400)

        config.decrypt_skill_content(enc_path)  # grace period exceeded → re-fetch

        expect(call_count).to eq(2)
      end
    end

    it "keys for different skill versions are cached independently" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)

        key_a = OpenSSL::Random.random_bytes(32)
        key_b = OpenSSL::Random.random_bytes(32)

        plaintext = "skill body"
        enc_a = aes_gcm_encrypt(key_a, plaintext)
        enc_b = aes_gcm_encrypt(key_b, plaintext)

        # Skill version A
        dir_a = File.join(tmp, "skill-v1")
        FileUtils.mkdir_p(dir_a)
        File.binwrite(File.join(dir_a, "SKILL.md.enc"), enc_a[:ciphertext])
        write_manifest(dir_a, skill_id: 10, skill_version_id: 1,
          file_path: "SKILL.md", iv_b64: enc_a[:iv_b64], tag_b64: enc_a[:tag_b64], checksum: enc_a[:checksum])

        # Skill version B
        dir_b = File.join(tmp, "skill-v2")
        FileUtils.mkdir_p(dir_b)
        File.binwrite(File.join(dir_b, "SKILL.md.enc"), enc_b[:ciphertext])
        write_manifest(dir_b, skill_id: 10, skill_version_id: 2,
          file_path: "SKILL.md", iv_b64: enc_b[:iv_b64], tag_b64: enc_b[:tag_b64], checksum: enc_b[:checksum])

        # Server returns different keys per skill_version_id
        allow(config).to receive(:api_post).with("/api/v1/licenses/skill_keys", anything) do |_path, payload|
          key_hex = payload[:skill_version_id] == 1 ? key_a.unpack1("H*") : key_b.unpack1("H*")
          { success: true, data: { "decryption_key" => key_hex, "expires_at" => (Time.now.utc + 86_400).iso8601 } }
        end

        result_a = config.decrypt_skill_content(File.join(dir_a, "SKILL.md.enc"))
        result_b = config.decrypt_skill_content(File.join(dir_b, "SKILL.md.enc"))

        expect(result_a).to eq(plaintext)
        expect(result_b).to eq(plaintext)
      end
    end
  end

  # ── Integrity checks ───────────────────────────────────────────────────────

  describe "integrity validation" do
    def build_skill(tmp, key, plaintext: "original content", skill_dir_name: "my-skill")
      enc       = aes_gcm_encrypt(key, plaintext)
      skill_dir = File.join(tmp, skill_dir_name)
      FileUtils.mkdir_p(skill_dir)
      File.binwrite(File.join(skill_dir, "SKILL.md.enc"), enc[:ciphertext])
      write_manifest(skill_dir,
        skill_id: 1, skill_version_id: 1,
        file_path: "SKILL.md",
        iv_b64: enc[:iv_b64], tag_b64: enc[:tag_b64], checksum: enc[:checksum])
      { skill_dir: skill_dir, enc: enc }
    end

    it "raises when SHA-256 checksum does not match decrypted content" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_skill(tmp, test_key)

        stub_key_server(config, test_key_hex)

        # Tamper the checksum in MANIFEST so it won't match the decrypted content
        manifest_path = File.join(info[:skill_dir], "MANIFEST.enc.json")
        manifest      = JSON.parse(File.read(manifest_path))
        manifest["files"]["SKILL.md"]["original_checksum"] = "a" * 64  # wrong checksum
        File.write(manifest_path, JSON.generate(manifest))

        expect { config.decrypt_skill_content(File.join(info[:skill_dir], "SKILL.md.enc")) }
          .to raise_error(RuntimeError, /Checksum mismatch/)
      end
    end

    it "raises when auth tag is tampered (GCM authentication failure)" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_skill(tmp, test_key, skill_dir_name: "tampered-skill")

        stub_key_server(config, test_key_hex)

        # Replace auth tag with random bytes → GCM will reject it
        manifest_path = File.join(info[:skill_dir], "MANIFEST.enc.json")
        manifest      = JSON.parse(File.read(manifest_path))
        manifest["files"]["SKILL.md"]["tag"] = Base64.strict_encode64(OpenSSL::Random.random_bytes(16))
        File.write(manifest_path, JSON.generate(manifest))

        expect { config.decrypt_skill_content(File.join(info[:skill_dir], "SKILL.md.enc")) }
          .to raise_error(RuntimeError, /AES-256-GCM decryption failed/)
      end
    end

    it "raises when ciphertext is tampered" do
      Dir.mktmpdir do |tmp|
        config = activated_config(tmp)
        info   = build_skill(tmp, test_key, skill_dir_name: "corrupted-skill")

        stub_key_server(config, test_key_hex)

        # Flip a byte in the ciphertext → GCM authentication will fail
        enc_path   = File.join(info[:skill_dir], "SKILL.md.enc")
        ciphertext = File.binread(enc_path)
        ciphertext.setbyte(0, ciphertext.getbyte(0) ^ 0xFF)
        File.binwrite(enc_path, ciphertext)

        expect { config.decrypt_skill_content(enc_path) }
          .to raise_error(RuntimeError, /AES-256-GCM decryption failed/)
      end
    end

    it "raises when a wrong key is used" do
      Dir.mktmpdir do |tmp|
        config    = activated_config(tmp)
        info      = build_skill(tmp, test_key, skill_dir_name: "wrong-key-skill")

        # Server returns a different (wrong) key
        wrong_key = OpenSSL::Random.random_bytes(32)
        stub_key_server(config, wrong_key.unpack1("H*"))

        expect { config.decrypt_skill_content(File.join(info[:skill_dir], "SKILL.md.enc")) }
          .to raise_error(RuntimeError, /AES-256-GCM decryption failed/)
      end
    end

    it "skips checksum validation when original_checksum is absent in MANIFEST" do
      Dir.mktmpdir do |tmp|
        config    = activated_config(tmp)
        plaintext = "no checksum content"
        enc       = aes_gcm_encrypt(test_key, plaintext)

        skill_dir = File.join(tmp, "no-checksum-skill")
        FileUtils.mkdir_p(skill_dir)
        File.binwrite(File.join(skill_dir, "SKILL.md.enc"), enc[:ciphertext])

        # MANIFEST without original_checksum field
        manifest = {
          "skill_id" => 1, "skill_version_id" => 1,
          "files" => {
            "SKILL.md" => { "iv" => enc[:iv_b64], "tag" => enc[:tag_b64] }
            # no "original_checksum"
          }
        }
        File.write(File.join(skill_dir, "MANIFEST.enc.json"), JSON.generate(manifest))

        stub_key_server(config, test_key_hex)

        result = config.decrypt_skill_content(File.join(skill_dir, "SKILL.md.enc"))
        expect(result).to eq(plaintext)
      end
    end
  end

  # ── mock fallback path ─────────────────────────────────────────────────────

  describe "mock/plain fallback (no MANIFEST)" do
    it "returns raw bytes as UTF-8 when no MANIFEST.enc.json exists" do
      Dir.mktmpdir do |tmp|
        config   = activated_config(tmp)
        skill_dir = File.join(tmp, "plain-skill")
        FileUtils.mkdir_p(skill_dir)
        enc_path = File.join(skill_dir, "SKILL.md.enc")
        File.binwrite(enc_path, "plain skill content")

        result = config.decrypt_skill_content(enc_path)
        expect(result).to eq("plain skill content")
        expect(result.encoding.name).to eq("UTF-8")
      end
    end

    it "does NOT call the key server for mock skills" do
      Dir.mktmpdir do |tmp|
        config   = activated_config(tmp)
        skill_dir = File.join(tmp, "plain-skill2")
        FileUtils.mkdir_p(skill_dir)
        File.binwrite(File.join(skill_dir, "SKILL.md.enc"), "plain content")

        expect(config).not_to receive(:api_post)
        config.decrypt_skill_content(File.join(skill_dir, "SKILL.md.enc"))
      end
    end
  end
end
