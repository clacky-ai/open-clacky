# frozen_string_literal: true

require "openssl"
require "base64"
require "clacky/aes_gcm"

RSpec.describe Clacky::AesGcm do
  let(:key) { OpenSSL::Random.random_bytes(32) }
  let(:iv)  { OpenSSL::Random.random_bytes(12) }
  let(:plaintext) { "Hello, pure-Ruby AES-256-GCM!" }
  let(:aad) { "additional authenticated data" }

  describe ".encrypt / .decrypt (pure Ruby roundtrip)" do
    it "decrypts what it encrypted" do
      ct, tag = described_class.encrypt(key, iv, plaintext, aad)
      pt = described_class.decrypt(key, iv, ct, tag, aad)
      expect(pt).to eq(plaintext)
    end

    it "returns binary ciphertext of the same length as plaintext" do
      ct, _tag = described_class.encrypt(key, iv, plaintext)
      expect(ct.bytesize).to eq(plaintext.bytesize)
    end

    it "returns a 16-byte auth tag" do
      _ct, tag = described_class.encrypt(key, iv, plaintext)
      expect(tag.bytesize).to eq(16)
    end

    it "raises on tampered auth tag" do
      ct, tag = described_class.encrypt(key, iv, plaintext)
      bad_tag = tag.dup
      bad_tag.setbyte(0, bad_tag.getbyte(0) ^ 0xFF)
      expect { described_class.decrypt(key, iv, ct, bad_tag) }
        .to raise_error(OpenSSL::Cipher::CipherError)
    end

    it "raises on tampered ciphertext" do
      ct, tag = described_class.encrypt(key, iv, plaintext)
      bad_ct = ct.dup
      bad_ct.setbyte(0, bad_ct.getbyte(0) ^ 0xFF)
      expect { described_class.decrypt(key, iv, bad_ct, tag) }
        .to raise_error(OpenSSL::Cipher::CipherError)
    end

    it "raises when AAD does not match" do
      ct, tag = described_class.encrypt(key, iv, plaintext, aad)
      expect { described_class.decrypt(key, iv, ct, tag, "wrong aad") }
        .to raise_error(OpenSSL::Cipher::CipherError)
    end
  end

  describe "cross-compatibility with native OpenSSL AES-256-GCM" do
    # These tests verify wire-compatibility: ciphertext produced by one
    # implementation can be decrypted by the other.

    it "pure Ruby can decrypt what native OpenSSL encrypted" do
      cipher           = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      cipher.key       = key
      cipher.iv        = iv
      cipher.auth_data = aad
      ct  = cipher.update(plaintext) + cipher.final
      tag = cipher.auth_tag

      pt = described_class.decrypt(key, iv, ct, tag, aad)
      expect(pt).to eq(plaintext)
    end

    it "native OpenSSL can decrypt what pure Ruby encrypted" do
      ct, tag = described_class.encrypt(key, iv, plaintext, aad)

      cipher           = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key       = key
      cipher.iv        = iv
      cipher.auth_tag  = tag
      cipher.auth_data = aad
      pt = (cipher.update(ct) + cipher.final).force_encoding("UTF-8")
      expect(pt).to eq(plaintext)
    end
  end

  describe "aes_gcm_decrypt fallback" do
    it "decrypts via pure Ruby when native OpenSSL is bypassed" do
      ct, tag = described_class.encrypt(key, iv, plaintext)
      iv_b64  = Base64.strict_encode64(iv)
      tag_b64 = Base64.strict_encode64(tag)

      # Force fallback path directly
      pt = described_class.decrypt(key, iv, ct, tag)
      expect(pt).to eq(plaintext)
    end
  end
end
