# frozen_string_literal: true

require "openssl"
require "faraday"
require "uri"

module Clacky
  module Channel
    module Adapters
      module Wecom
        # Downloads and decrypts media files from WeCom message URLs.
        #
        # WeCom long-connection bot messages include a per-resource aeskey.
        # Encryption: AES-256-CBC, key=base64_decode(aeskey), iv=key[0,16], no PKCS7 padding.
        # However some files are sent unencrypted — detect via magic bytes before decrypting.
        module MediaDownloader
          HTTP_TIMEOUT = 30

          # Download and decrypt a WeCom media resource.
          # @param url [String] Signed download URL from the message
          # @param aeskey [String] Per-resource AES key string
          # @return [Hash] { body: String (binary), content_type: String }
          def self.download(url, aeskey)
            response = fetch(url)
            body = response.body.dup.force_encoding("BINARY")

            if aeskey && !aeskey.empty? && !looks_plain?(body)
              body = decrypt(body, aeskey)
            end

            content_type = detect_mime(body)
            filename = extract_filename(response.headers["content-disposition"].to_s)
            { body: body, content_type: content_type, filename: filename }
          end

          def self.extract_filename(content_disposition)
            return nil if content_disposition.empty?
            # filename*=UTF-8''name.ext  or  filename="name.ext"
            if (m = content_disposition.match(/filename\*=UTF-8''([^;\s]+)/i))
              URI.decode_www_form_component(m[1])
            elsif (m = content_disposition.match(/filename="?([^";\s]+)"?/i))
              URI.decode_www_form_component(m[1])
            end
          end

          # --- private ---

          def self.fetch(url)
            conn = Faraday.new do |f|
              f.options.timeout = HTTP_TIMEOUT
              f.options.open_timeout = HTTP_TIMEOUT
              f.ssl.verify = false
              f.adapter Faraday.default_adapter
            end
            response = conn.get(url)
            raise "Failed to download media: HTTP #{response.status}" unless response.success?
            response
          end

          # AES-256-CBC decrypt, no PKCS7 padding.
          # Key = base64_decode(aeskey), IV = first 16 bytes of decoded key.
          def self.decrypt(data, aeskey)
            require "base64"
            padded = aeskey + "=" * ((4 - aeskey.length % 4) % 4)
            key = Base64.decode64(padded)
            iv  = key.byteslice(0, 16)

            cipher = OpenSSL::Cipher.new("AES-256-CBC")
            cipher.decrypt
            cipher.key = key
            cipher.iv  = iv
            cipher.padding = 0
            cipher.update(data) + cipher.final
          rescue OpenSSL::Cipher::CipherError => e
            warn "[WeCom] AES decrypt failed: #{e.message}"
            # Decryption failed — return raw data as-is
            data
          end

          # Check if data looks like a plain (unencrypted) file via magic bytes.
          MAGIC_SIGNATURES = [
            "\xFF\xD8\xFF",         # JPEG
            "\x89PNG\r\n\x1a\n",   # PNG
            "GIF8",                  # GIF
            "%PDF",                  # PDF
            "PK\x03\x04",           # ZIP (docx/xlsx)
            "\xD0\xCF\x11\xE0",    # OLE2 (doc/xls)
            "RIFF",                  # WAV/WebP
          ].map { |s| s.b }.freeze

          def self.looks_plain?(data)
            return false if data.empty?
            MAGIC_SIGNATURES.any? { |sig| data.start_with?(sig) }
          end

          # Detect MIME type from magic bytes
          # @param data [String] Binary data
          # @return [String] MIME type
          def self.detect_mime(data)
            return "application/octet-stream" if data.nil? || data.empty?
            d = data.b
            return "image/jpeg"      if d.start_with?("\xFF\xD8\xFF".b)
            return "image/png"       if d.start_with?("\x89PNG\r\n\x1a\n".b)
            return "image/gif"       if d.start_with?("GIF8".b)
            return "image/webp"      if d.start_with?("RIFF".b) && d.byteslice(8, 4) == "WEBP".b
            return "image/bmp"       if d.start_with?("BM".b)
            "image/jpeg"  # fallback for unknown image formats
          end

          private_class_method :fetch, :decrypt, :looks_plain?, :extract_filename
        end
      end
    end
  end
end
