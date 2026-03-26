# frozen_string_literal: true

require "openssl"
require "base64"

module Clacky
  # Pure-Ruby AES-256-GCM implementation.
  #
  # Why this exists:
  #   macOS ships Ruby 2.6 linked against LibreSSL 3.3.x which has a known
  #   bug: AES-GCM encrypt/decrypt raises CipherError even for valid inputs.
  #   This implementation uses AES-256-ECB (which LibreSSL supports correctly)
  #   as the single block-cipher primitive and builds GCM on top:
  #
  #     - CTR mode   → keystream for encryption / decryption
  #     - GHASH      → authentication tag
  #
  # The output is 100% compatible with OpenSSL / standard AES-256-GCM:
  #   ciphertext, iv, and auth_tag produced here can be decrypted by OpenSSL
  #   and vice-versa.
  #
  # Reference: NIST SP 800-38D
  #
  # Usage:
  #   ct, tag = AesGcm.encrypt(key, iv, plaintext, aad)
  #   pt      = AesGcm.decrypt(key, iv, ciphertext, tag, aad)
  module AesGcm
    BLOCK_SIZE = 16
    TAG_LENGTH = 16

    # Encrypt plaintext with AES-256-GCM.
    #
    # @param key        [String] 32-byte binary key
    # @param iv         [String] 12-byte binary IV (recommended for GCM)
    # @param plaintext  [String] binary or UTF-8 plaintext
    # @param aad        [String] additional authenticated data (may be empty)
    # @return [Array<String, String>] [ciphertext, auth_tag] both binary strings
    def self.encrypt(key, iv, plaintext, aad = "")
      aes  = aes_ecb(key)
      h    = aes.call("\x00" * BLOCK_SIZE)              # H = E(K, 0^128)
      j0   = build_j0(iv, h)
      ct   = ctr_crypt(aes, inc32(j0), plaintext.b)
      tag  = compute_tag(aes, h, j0, ct, aad.b)
      [ct, tag]
    end

    # Decrypt ciphertext with AES-256-GCM and verify auth tag.
    #
    # @param key        [String] 32-byte binary key
    # @param iv         [String] 12-byte binary IV
    # @param ciphertext [String] binary ciphertext
    # @param tag        [String] 16-byte binary auth tag
    # @param aad        [String] additional authenticated data (may be empty)
    # @return [String] plaintext (UTF-8)
    # @raise  [OpenSSL::Cipher::CipherError] on authentication failure
    def self.decrypt(key, iv, ciphertext, tag, aad = "")
      aes       = aes_ecb(key)
      h         = aes.call("\x00" * BLOCK_SIZE)
      j0        = build_j0(iv, h)
      exp_tag   = compute_tag(aes, h, j0, ciphertext, aad.b)

      unless secure_compare(exp_tag, tag)
        raise OpenSSL::Cipher::CipherError, "bad decrypt (authentication tag mismatch)"
      end

      ctr_crypt(aes, inc32(j0), ciphertext).force_encoding("UTF-8")
    end

    # ── Private helpers ──────────────────────────────────────────────────────

    # Return a lambda: block(16 bytes) → encrypted block(16 bytes)
    private_class_method def self.aes_ecb(key)
      lambda do |block|
        c = OpenSSL::Cipher.new("aes-256-ecb")
        c.encrypt
        c.padding = 0
        c.key     = key
        c.update(block) + c.final
      end
    end

    # Build J0 counter block.
    # For 12-byte IVs (standard): J0 = IV || 0x00000001
    # For other lengths: J0 = GHASH(H, {}, IV)
    private_class_method def self.build_j0(iv, h)
      if iv.bytesize == 12
        iv.b + "\x00\x00\x00\x01"
      else
        ghash(h, "", iv.b)
      end
    end

    # CTR-mode encryption/decryption (symmetric — same operation).
    # Starting counter block is `ctr0` (already incremented to J0+1 by caller).
    private_class_method def self.ctr_crypt(aes, ctr0, data)
      return "".b if data.empty?

      out = "".b
      ctr = ctr0.dup
      pos = 0

      while pos < data.bytesize
        keystream = aes.call(ctr)
        chunk     = data.byteslice(pos, BLOCK_SIZE)
        out << xor_blocks(keystream, chunk)
        ctr = inc32(ctr)
        pos += BLOCK_SIZE
      end

      out
    end

    # Compute GCM auth tag.
    # tag = E(K, J0) XOR GHASH(H, aad, ciphertext)
    private_class_method def self.compute_tag(aes, h, j0, ciphertext, aad)
      s   = ghash(h, aad, ciphertext)
      ej0 = aes.call(j0)
      xor_blocks(ej0, s)
    end

    # GHASH: polynomial hashing over GF(2^128)
    # ghash = Σ (Xi * H^i) where Xi are 128-bit blocks of padded aad + ciphertext + lengths
    private_class_method def self.ghash(h, aad, ciphertext)
      h_int = bytes_to_int(h)
      x     = 0

      # Process AAD blocks
      each_block(aad) { |blk| x = gf128_mul(bytes_to_int(blk) ^ x, h_int) }

      # Process ciphertext blocks
      each_block(ciphertext) { |blk| x = gf128_mul(bytes_to_int(blk) ^ x, h_int) }

      # Final block: len(aad) || len(ciphertext) in bits, each as 64-bit big-endian
      len_block = [aad.bytesize * 8].pack("Q>") + [ciphertext.bytesize * 8].pack("Q>")
      x = gf128_mul(bytes_to_int(len_block) ^ x, h_int)

      int_to_bytes(x)
    end

    # Iterate over 16-byte zero-padded blocks of data, yielding each block.
    private_class_method def self.each_block(data, &block)
      return if data.empty?

      i = 0
      while i < data.bytesize
        chunk = data.byteslice(i, BLOCK_SIZE)
        chunk = chunk.ljust(BLOCK_SIZE, "\x00") if chunk.bytesize < BLOCK_SIZE
        block.call(chunk)
        i += BLOCK_SIZE
      end
    end

    # Galois Field GF(2^128) multiplication.
    # Reduction polynomial: x^128 + x^7 + x^2 + x + 1
    # Uses the reflected bit order per GCM spec.
    R = 0xe1000000000000000000000000000000
    private_class_method def self.gf128_mul(x, y)
      z = 0
      v = x
      128.times do
        z ^= v if y & (1 << 127) != 0
        lsb = v & 1
        v >>= 1
        v ^= R if lsb == 1
        y <<= 1
        y &= (1 << 128) - 1
      end
      z
    end

    # Increment the rightmost 32 bits of a 16-byte counter block (big-endian).
    private_class_method def self.inc32(block)
      prefix  = block.byteslice(0, 12)
      counter = block.byteslice(12, 4).unpack1("N")
      prefix + [(counter + 1) & 0xFFFFFFFF].pack("N")
    end

    # XOR two binary strings, truncated to the shorter length.
    private_class_method def self.xor_blocks(a, b)
      len = [a.bytesize, b.bytesize].min
      len.times.map { |i| (a.getbyte(i) ^ b.getbyte(i)).chr }.join.b
    end

    # Convert a binary string to an unsigned big-endian integer.
    private_class_method def self.bytes_to_int(str)
      str.bytes.inject(0) { |acc, b| (acc << 8) | b }
    end

    # Convert an unsigned integer to a 16-byte big-endian binary string.
    private_class_method def self.int_to_bytes(n)
      bytes = []
      16.times { bytes.unshift(n & 0xFF); n >>= 8 }
      bytes.pack("C*")
    end

    # Constant-time string comparison to prevent timing attacks.
    private_class_method def self.secure_compare(a, b)
      return false if a.bytesize != b.bytesize

      result = 0
      a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
      result == 0
    end
  end
end
