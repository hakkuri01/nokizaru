require "openssl"

# Certificate fields Crystal's OpenSSL::X509::Certificate does not expose
# (issuer, version, serial, validity), read through a small LibCrypto FFI binding
# over the functions the already-linked C library provides. The stdlib covers
# subject, extensions, and the socket's protocol/cipher; this fills the gap the
# sslinfo module needs (design section 5). Pointers returned by the X509_get0_*
# functions are borrowed from the certificate (not freed here); OpenSSL::X509::Name
# dups its argument, so wrapping the borrowed issuer name is safe.
lib LibCrypto
  fun x509_get_issuer_name = X509_get_issuer_name(a : X509) : X509_NAME
  fun x509_get_version = X509_get_version(x : X509) : LibC::Long
  fun x509_get_serial_number = X509_get_serialNumber(x : X509) : ASN1_STRING
  fun x509_get0_not_before = X509_get0_notBefore(x : X509) : ASN1_STRING
  fun x509_get0_not_after = X509_get0_notAfter(x : X509) : ASN1_STRING
  fun asn1_integer_to_bn = ASN1_INTEGER_to_BN(a : ASN1_STRING, bn : Void*) : Void*
  fun bn_bn2dec = BN_bn2dec(a : Void*) : UInt8*
  fun bn_free = BN_free(a : Void*)
  fun openssl_crypto_free = CRYPTO_free(addr : Void*, file : UInt8*, line : LibC::Int)
end

module Nokizaru
  module Http
    module X509Ext
      extend self

      # Issuer distinguished name as ordered {oid, value} pairs, mirroring the
      # stdlib's subject.to_a. Name.new dups the borrowed pointer and owns its
      # copy, so there is no double free with the certificate.
      def issuer(cert : OpenSSL::X509::Certificate) : Array({String, String})
        OpenSSL::X509::Name.new(LibCrypto.x509_get_issuer_name(cert.to_unsafe)).to_a
      end

      # The raw X.509 version number (0-based: v3 certificates report 2), as the
      # Ruby tool exposed it.
      def version(cert : OpenSSL::X509::Certificate) : Int32
        LibCrypto.x509_get_version(cert.to_unsafe).to_i32
      end

      # The serial as a decimal string. Serials can exceed 64 bits, so the
      # ASN1_INTEGER is read through a BIGNUM rather than a machine integer.
      def serial(cert : OpenSSL::X509::Certificate) : String
        bignum = LibCrypto.asn1_integer_to_bn(LibCrypto.x509_get_serial_number(cert.to_unsafe), Pointer(Void).null)
        return "0" if bignum.null?

        begin
          decimal = LibCrypto.bn_bn2dec(bignum)
          return "0" if decimal.null?

          value = String.new(decimal)
          LibCrypto.openssl_crypto_free(decimal.as(Void*), Pointer(UInt8).null, 0)
          value
        ensure
          LibCrypto.bn_free(bignum)
        end
      end

      def not_before(cert : OpenSSL::X509::Certificate) : Time?
        parse_asn1_time(LibCrypto.x509_get0_not_before(cert.to_unsafe))
      end

      def not_after(cert : OpenSSL::X509::Certificate) : Time?
        parse_asn1_time(LibCrypto.x509_get0_not_after(cert.to_unsafe))
      end

      # DNS names from the subjectAltName extension, read from the stdlib
      # extension value ("DNS:a, DNS:b"), as the Ruby tool parsed it.
      def san(cert : OpenSSL::X509::Certificate) : Array(String)
        extension = cert.extensions.find { |ext| ext.oid == "subjectAltName" }
        return [] of String if extension.nil?

        extension.value.split(',').compact_map do |entry|
          trimmed = entry.strip
          trimmed.lchop("DNS:").strip if trimmed.starts_with?("DNS:")
        end
      end

      private def parse_asn1_time(pointer : LibCrypto::ASN1_STRING) : Time?
        length = LibCrypto.asn1_string_length(pointer)
        return nil if length <= 0

        raw = String.new(LibCrypto.asn1_string_get0_data(pointer).as(UInt8*), length)
        parse_time_string(raw)
      end

      # ASN.1 UTCTime (YYMMDDHHMMSSZ, year < 50 => 20xx) or GeneralizedTime
      # (YYYYMMDDHHMMSSZ), the only forms a certificate uses. Parsed to a UTC Time
      # so the module can format it to match the Ruby strftime output.
      private def parse_time_string(raw : String) : Time?
        digits = raw.rchop('Z')
        if digits.size == 12
          short = digits[0, 2].to_i
          year = short < 50 ? 2000 + short : 1900 + short
          rest = digits[2..]
        elsif digits.size == 14
          year = digits[0, 4].to_i
          rest = digits[4..]
        else
          return nil
        end
        Time.utc(year, rest[0, 2].to_i, rest[2, 2].to_i, rest[4, 2].to_i, rest[6, 2].to_i, rest[8, 2].to_i)
      rescue
        nil
      end
    end
  end
end
