#!/usr/bin/env ruby
# frozen_string_literal: true
#
# End-to-end smoke test for brand skill decryption.
#
# Uses keys derived directly from the server (via rails runner on openclacky-platform)
# to validate AES-256-GCM decryption of the real encrypted files in
# ~/.clacky/brand_skills/ without hitting the /skill_keys API endpoint.
#
# Usage:
#   ruby scripts/smoke_decrypt.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "openssl"
require "base64"
require "digest"
require "json"

PASS = "✓ PASS"
FAIL = "✗ FAIL"
INFO = "→"

# Keys derived from server via SkillEncryptionService.derive_key(skill_id, version_id)
KNOWN_KEYS = {
  # skill_id=33, skill_version_id=48
  "33:48" => "8cda46b8c6ffe57c967e3099efbe4277b657c7ad5fc14daea9d4c4d08effa215",
  # skill_id=34, skill_version_id=51
  "34:51" => "cc3b2425770c0ee4eaacaba9765cee8a4aa9de1f8d2579509bacb8d53b230194"
}.freeze

def aes_gcm_decrypt(key_hex, ciphertext, iv_b64, tag_b64)
  key = [key_hex].pack("H*")
  cipher          = OpenSSL::Cipher.new("aes-256-gcm").decrypt
  cipher.key      = key
  cipher.iv       = Base64.strict_decode64(iv_b64)
  cipher.auth_tag = Base64.strict_decode64(tag_b64)
  (cipher.update(ciphertext) + cipher.final).force_encoding("UTF-8")
rescue OpenSSL::Cipher::CipherError => e
  raise "AES-256-GCM decryption failed: #{e.message}"
end

brand_dir = File.expand_path("~/.clacky/brand_skills")
total  = 0
passed = 0
failed = 0

Dir.glob("#{brand_dir}/*/MANIFEST.enc.json").sort.each do |manifest_path|
  skill_dir = File.dirname(manifest_path)
  slug      = File.basename(skill_dir)
  manifest  = JSON.parse(File.read(manifest_path))

  skill_id         = manifest["skill_id"]
  skill_version_id = manifest["skill_version_id"]
  cache_key        = "#{skill_id}:#{skill_version_id}"
  key_hex          = KNOWN_KEYS[cache_key]

  puts "┌─ #{slug}  (skill_id=#{skill_id}, version_id=#{skill_version_id})"

  unless key_hex
    puts "│  #{FAIL} no known key for #{cache_key} — add it to KNOWN_KEYS"
    puts "└─"
    puts
    next
  end

  (manifest["files"] || {}).each do |file_path, meta|
    enc_path = File.join(skill_dir, meta["encrypted_path"] || "#{file_path}.enc")
    total += 1

    unless File.exist?(enc_path)
      puts "│  #{FAIL} #{file_path} — .enc file missing"
      failed += 1
      next
    end

    begin
      ciphertext = File.binread(enc_path)
      plaintext  = aes_gcm_decrypt(key_hex, ciphertext, meta["iv"], meta["tag"])

      errors = []
      # Empty plaintext is valid (e.g. __init__.py with original_size: 0)
      errors << "invalid UTF-8"  unless plaintext.valid_encoding?

      if (expected = meta["original_checksum"])
        actual = Digest::SHA256.hexdigest(plaintext)
        errors << "checksum mismatch (got #{actual[0..7]}…, want #{expected[0..7]}…)" if actual != expected
      end

      if errors.empty?
        size_kb = (plaintext.bytesize / 1024.0).round(1)
        puts "│  #{PASS} #{file_path} (#{size_kb} KB)"
        passed += 1
      else
        puts "│  #{FAIL} #{file_path} — #{errors.join(", ")}"
        failed += 1
      end
    rescue => e
      puts "│  #{FAIL} #{file_path} — #{e.message}"
      failed += 1
    end
  end

  puts "└─"
  puts
end

puts "─" * 50
puts "Result: #{passed}/#{total} passed, #{failed} failed"
exit(failed > 0 ? 1 : 0)
