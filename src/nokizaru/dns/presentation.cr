require "base64"
require "./message"
require "./record_type"
require "./rdata_reader"

module Nokizaru
  module Dns
    # Renders a record's RDATA to its canonical zone-file / dig-style text.
    # The structured types each get an exact formatter; the opaque or
    # un-queryable tail (LOC, NSEC3, HIP, IPSECKEY, APL, DHCID, TKEY, TSIG)
    # falls back to the RFC 3597 generic form `\# <len> <hex>`, which still
    # surfaces the bytes losslessly. Dispatch is a frozen Hash keyed by type
    # code (O(1)), not a case, so adding a type never grows a branch chain.
    # Every formatter reads through RdataReader, so a short or oversized rdata
    # raises and `format` falls back to the generic form rather than propagating.
    #
    # ponytail: LOC, NSEC3, RRSIG timestamps for SIG, and the rest of the
    # generic tail trade an exact decode for the lossless hex form. The owner
    # may promote any of them to an exact formatter later; the bytes are
    # preserved either way, so this is a presentation nicety, not a data loss.
    module Presentation
      extend self

      def format(record : Record) : String
        formatter = FORMATTERS[record.type]?
        return generic(record.rdata) if formatter.nil?

        formatter.call(RdataReader.new(record.message, record.rdata_offset, record.rdata.size))
      rescue MalformedMessage
        generic(record.rdata)
      end

      def a(r : RdataReader) : String
        b = r.take(4)
        "#{b[0]}.#{b[1]}.#{b[2]}.#{b[3]}"
      end

      def aaaa(r : RdataReader) : String
        ipv6(r.take(16)).upcase
      end

      def single_name(r : RdataReader) : String
        r.name
      end

      def pref_name(r : RdataReader) : String
        "#{r.u16} #{r.name}"
      end

      def soa(r : RdataReader) : String
        mname = r.name
        rname = r.name
        serial = r.u32
        refresh = r.u32
        retry_interval = r.u32
        expire = r.u32
        minimum = r.u32
        "#{mname} #{rname} #{serial} #{refresh} #{retry_interval} #{expire} #{minimum}"
      end

      def txt(r : RdataReader) : String
        parts = [] of String
        while r.remaining > 0
          parts << format_char(r.char_string)
        end
        parts.join(" ")
      end

      def srv(r : RdataReader) : String
        priority = r.u16
        weight = r.u16
        port = r.u16
        "#{priority} #{weight} #{port} #{r.name}"
      end

      def caa(r : RdataReader) : String
        flags = r.u8
        tag = r.char_string
        %(#{flags} #{tag} "#{String.new(r.rest)}")
      end

      def naptr(r : RdataReader) : String
        order = r.u16
        pref = r.u16
        flags = r.char_string
        service = r.char_string
        regexp = r.char_string
        %(#{order} #{pref} "#{flags}" "#{service}" "#{regexp}" #{r.name})
      end

      def ds(r : RdataReader) : String
        keytag = r.u16
        algorithm = r.u8
        digest_type = r.u8
        "#{keytag} #{algorithm} #{digest_type} #{format_char(String.new(r.rest))}"
      end

      def dnskey(r : RdataReader) : String
        flags = r.u16
        protocol = r.u8
        algorithm = r.u8
        "#{flags} #{protocol} #{algorithm} #{Base64.strict_encode(r.rest)}"
      end

      def sshfp(r : RdataReader) : String
        algorithm = r.u8
        fptype = r.u8
        "#{algorithm} #{fptype} #{hexup(r.rest)}"
      end

      def tlsa(r : RdataReader) : String
        usage = r.u8
        selector = r.u8
        matching = r.u8
        "#{usage} #{selector} #{matching} #{hexup(r.rest)}"
      end

      def nsec(r : RdataReader) : String
        next_name = r.name
        types = type_bitmap(r.rest)
        types.empty? ? next_name : "#{next_name} #{types.join(" ")}"
      end

      def rrsig(r : RdataReader) : String
        covered = RecordType.name(r.u16)
        algorithm = r.u8
        labels = r.u8
        original_ttl = r.u32
        expiration = timefmt(r.u32)
        inception = timefmt(r.u32)
        keytag = r.u16
        signer = r.name
        "#{covered} #{algorithm} #{labels} #{original_ttl} #{expiration} #{inception} #{keytag} #{signer} #{Base64.strict_encode(r.rest)}"
      end

      def afsdb(r : RdataReader) : String
        "#{r.u16} #{r.name}"
      end

      def rp(r : RdataReader) : String
        mbox = r.name
        "#{mbox} #{r.name}"
      end

      def hinfo(r : RdataReader) : String
        cpu = r.char_string
        %("#{cpu}" "#{r.char_string}")
      end

      def cert(r : RdataReader) : String
        cert_type = r.u16
        keytag = r.u16
        algorithm = r.u8
        "#{cert_type} #{keytag} #{algorithm} #{Base64.strict_encode(r.rest)}"
      end

      def uri(r : RdataReader) : String
        priority = r.u16
        weight = r.u16
        %(#{priority} #{weight} "#{String.new(r.rest)}")
      end

      def nsec3param(r : RdataReader) : String
        hash_alg = r.u8
        flags = r.u8
        iterations = r.u16
        salt_len = r.u8.to_i
        salt = salt_len.zero? ? "-" : hexup(r.take(salt_len))
        "#{hash_alg} #{flags} #{iterations} #{salt}"
      end

      # RFC 3597 §5: the generic form for a type with no exact formatter.
      def generic(rdata : Bytes) : String
        rdata.empty? ? %(\\# 0) : %(\\# #{rdata.size} #{hexup(rdata)})
      end

      # RFC 5952: lowercase hex, the longest run of zero groups collapsed to
      # "::" (leftmost on a tie). O(1) over the fixed 8 groups.
      def ipv6(bytes : Bytes) : String
        groups = Array(Int32).new(8) { |i| (bytes[i * 2].to_i << 8) | bytes[i * 2 + 1].to_i }
        start, len = longest_zero_run(groups)
        return groups.map(&.to_s(16)).join(":") if len < 2

        head = groups[0, start].map(&.to_s(16)).join(":")
        tail = groups[(start + len)..].map(&.to_s(16)).join(":")
        "#{head}::#{tail}"
      end

      private def longest_zero_run(groups : Array(Int32)) : {Int32, Int32}
        best_start = 0
        best_len = 0
        cur_start = 0
        cur_len = 0
        groups.each_with_index do |group, i|
          if group.zero?
            cur_start = i if cur_len.zero?
            cur_len += 1
            best_start, best_len = cur_start, cur_len if cur_len > best_len
          else
            cur_len = 0
          end
        end
        {best_start, best_len}
      end

      # Decodes an NSEC type bitmap (RFC 4034 §4.1.2) to the present type names.
      # O(rdata) over a window/length/bitmap sequence, every offset bounded.
      def type_bitmap(bytes : Bytes) : Array(String)
        types = [] of String
        pos = 0
        while pos + 2 <= bytes.size
          window = bytes[pos].to_i
          len = bytes[pos + 1].to_i
          pos += 2
          break if len.zero? || pos + len > bytes.size

          collect_window_types(bytes, pos, len, window, types)
          pos += len
        end
        types
      end

      private def collect_window_types(bytes : Bytes, pos : Int32, len : Int32, window : Int32, types : Array(String)) : Nil
        len.times do |byte_index|
          octet = bytes[pos + byte_index].to_i
          8.times do |bit|
            next if (octet & (0x80 >> bit)).zero?

            types << RecordType.name((window * 256 + byte_index * 8 + bit).to_u16)
          end
        end
      end

      private def timefmt(value : UInt32) : String
        Time.unix(value.to_i64).to_utc.to_s("%Y%m%d%H%M%S")
      end

      # A <character-string> value is binary when it holds a non-printable byte;
      # such values are base64-encoded, matching the Ruby format_rdata.
      private def format_char(value : String) : String
        binary?(value) ? Base64.strict_encode(value) : value
      end

      private def binary?(value : String) : Bool
        value.each_byte.any? { |byte| byte < 32 || byte > 126 }
      end

      private def hexup(bytes : Bytes) : String
        bytes.hexstring.upcase
      end

      BY_NAME = {
        "A"          => ->(r : RdataReader) { a(r) },
        "AAAA"       => ->(r : RdataReader) { aaaa(r) },
        "NS"         => ->(r : RdataReader) { single_name(r) },
        "CNAME"      => ->(r : RdataReader) { single_name(r) },
        "PTR"        => ->(r : RdataReader) { single_name(r) },
        "DNAME"      => ->(r : RdataReader) { single_name(r) },
        "MX"         => ->(r : RdataReader) { pref_name(r) },
        "KX"         => ->(r : RdataReader) { pref_name(r) },
        "SOA"        => ->(r : RdataReader) { soa(r) },
        "TXT"        => ->(r : RdataReader) { txt(r) },
        "SRV"        => ->(r : RdataReader) { srv(r) },
        "CAA"        => ->(r : RdataReader) { caa(r) },
        "NAPTR"      => ->(r : RdataReader) { naptr(r) },
        "DS"         => ->(r : RdataReader) { ds(r) },
        "CDS"        => ->(r : RdataReader) { ds(r) },
        "DLV"        => ->(r : RdataReader) { ds(r) },
        "DNSKEY"     => ->(r : RdataReader) { dnskey(r) },
        "CDNSKEY"    => ->(r : RdataReader) { dnskey(r) },
        "KEY"        => ->(r : RdataReader) { dnskey(r) },
        "SSHFP"      => ->(r : RdataReader) { sshfp(r) },
        "TLSA"       => ->(r : RdataReader) { tlsa(r) },
        "NSEC"       => ->(r : RdataReader) { nsec(r) },
        "RRSIG"      => ->(r : RdataReader) { rrsig(r) },
        "SIG"        => ->(r : RdataReader) { rrsig(r) },
        "AFSDB"      => ->(r : RdataReader) { afsdb(r) },
        "RP"         => ->(r : RdataReader) { rp(r) },
        "HINFO"      => ->(r : RdataReader) { hinfo(r) },
        "CERT"       => ->(r : RdataReader) { cert(r) },
        "URI"        => ->(r : RdataReader) { uri(r) },
        "NSEC3PARAM" => ->(r : RdataReader) { nsec3param(r) },
      }

      FORMATTERS = BY_NAME.each_with_object({} of UInt16 => Proc(RdataReader, String)) do |(name, fn), table|
        if code = RecordType.code(name)
          table[code] = fn
        end
      end
    end
  end
end
