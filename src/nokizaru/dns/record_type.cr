module Nokizaru
  module Dns
    # The DNS record types Nokizaru enumerates, with their RFC-assigned numeric
    # codes. CODES is written in the Ruby DNS_RECORDS order, which Crystal's Hash
    # preserves, so both the enumeration (E2) and the sorted presentation follow
    # it without a separate sort. name<->code lookups go through frozen hashes,
    # so each is O(1).
    module RecordType
      CODES = {
        "A" => 1_u16, "AAAA" => 28_u16, "AFSDB" => 18_u16, "APL" => 42_u16,
        "CAA" => 257_u16, "CDNSKEY" => 60_u16, "CDS" => 59_u16, "CERT" => 37_u16,
        "CNAME" => 5_u16, "DHCID" => 49_u16, "DLV" => 32769_u16, "DNAME" => 39_u16,
        "DNSKEY" => 48_u16, "DS" => 43_u16, "HINFO" => 13_u16, "HIP" => 55_u16,
        "IPSECKEY" => 45_u16, "KEY" => 25_u16, "KX" => 36_u16, "LOC" => 29_u16,
        "MX" => 15_u16, "NAPTR" => 35_u16, "NS" => 2_u16, "NSEC" => 47_u16,
        "NSEC3" => 50_u16, "NSEC3PARAM" => 51_u16, "PTR" => 12_u16, "RP" => 17_u16,
        "RRSIG" => 46_u16, "SIG" => 24_u16, "SOA" => 6_u16, "SRV" => 33_u16,
        "SSHFP" => 44_u16, "TKEY" => 249_u16, "TLSA" => 52_u16, "TSIG" => 250_u16,
        "TXT" => 16_u16, "URI" => 256_u16,
      }

      # The enumeration order: the CODES keys, which are the Ruby DNS_RECORDS.
      NAMES = CODES.keys

      # code => name, for labeling a parsed answer and the types inside an NSEC
      # bitmap or an RRSIG "type covered" field.
      NAMES_BY_CODE = CODES.invert

      def self.code(name : String) : UInt16?
        CODES[name]?
      end

      # The presentation name for a type code: the mnemonic when known, else the
      # RFC 3597 generic form TYPE<n> for a code outside the enumerated set.
      def self.name(code : UInt16) : String
        NAMES_BY_CODE[code]? || "TYPE#{code}"
      end
    end
  end
end
