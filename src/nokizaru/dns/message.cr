module Nokizaru
  module Dns
    # A malformed or hostile DNS message. The parser raises this instead of
    # trusting attacker-controlled lengths and offsets from the wire.
    class MalformedMessage < Exception
    end

    # One answer resource record, kept with its rdata still raw. Dns::Presentation
    # decodes rdata per type; the types whose rdata embeds a domain name
    # (NS, CNAME, SOA, MX, ...) decompress it against `message` starting at
    # `rdata_offset`, so the whole message buffer travels with the record. The
    # owner name, class, and TTL are parsed to advance the cursor but not kept:
    # the Ruby tool rendered only the rdata, so nothing downstream reads them.
    struct Record
      getter type : UInt16
      getter rdata : Bytes
      getter message : Bytes
      getter rdata_offset : Int32

      def initialize(@type : UInt16, @rdata : Bytes, @message : Bytes, @rdata_offset : Int32)
      end
    end

    # DNS wire-format message encode/decode (RFC 1035 §4), hand-rolled
    # (no shard). Builds a query and parses a response down to its answer
    # section, which is all enumeration reads (the Ruby dnsruby path used
    # `response.answer`). Every length and offset off the wire is bounds-checked
    # before use, and name decompression bounds its pointer chases, so a crafted
    # response cannot read out of range or loop forever.
    struct Message
      # A DNS message caps at the 16-bit TCP length prefix; never read past it.
      MAX_MESSAGE = 65_535
      # RFC 1035 §2.3.4: a name is at most 255 octets; §2.3.1: a label 63.
      MAX_NAME  = 255
      MAX_LABEL =  63
      # A hard bound on compression-pointer chases per name, so a pointer loop
      # or a pointer chain is rejected instead of spinning.
      MAX_POINTER_JUMPS = 128
      # The DNS header is a fixed 12 octets; the question/answer sections follow.
      HEADER_SIZE = 12
      # TC (truncation) bit in the flags word: the answer did not fit the
      # datagram, so the caller must retry over TCP.
      TRUNCATED_BIT = 0x0200_u16

      getter id : UInt16
      getter answers : Array(Record)

      def initialize(@id : UInt16, @flags : UInt16, @answers : Array(Record))
      end

      def truncated? : Bool
        (@flags & TRUNCATED_BIT) != 0
      end

      # The low four bits of the flags word (RFC 1035 §4.1.1): 0 is NOERROR,
      # 3 is NXDOMAIN, which the dns module reads to tell "no such name" from
      # "no records of this type".
      def rcode : UInt8
        (@flags & 0x000F_u16).to_u8
      end

      # Builds a standard recursive query (RD=1) for one (name, qtype) in class
      # IN, tagged with `id` so the response can be matched. Complexity: one
      # O(name length) pass encoding the labels.
      def self.build_query(name : String, qtype : UInt16, id : UInt16) : Bytes
        io = IO::Memory.new
        write_u16(io, id)
        write_u16(io, 0x0100_u16) # QR=0, Opcode=QUERY, RD=1
        write_u16(io, 1_u16)      # QDCOUNT
        write_u16(io, 0_u16)      # ANCOUNT
        write_u16(io, 0_u16)      # NSCOUNT
        write_u16(io, 0_u16)      # ARCOUNT
        encode_name(io, name)
        write_u16(io, qtype)
        write_u16(io, 1_u16) # QCLASS = IN
        io.to_slice
      end

      # Parses a response into its id, flags, and answer records. Complexity:
      # one pass bounded by the message size (itself capped at MAX_MESSAGE).
      # ANCOUNT is attacker-controlled, so the answer array is never preallocated
      # from it: a huge count with no bytes behind it raises on the first
      # overrun rather than allocating, and real records are bounded by the
      # buffer. Each name decode is bounded by MAX_NAME octets and
      # MAX_POINTER_JUMPS chases.
      def self.parse(buf : Bytes) : Message
        raise MalformedMessage.new("message shorter than a header") if buf.size < HEADER_SIZE
        raise MalformedMessage.new("message exceeds the size cap") if buf.size > MAX_MESSAGE

        id = read_u16(buf, 0)
        flags = read_u16(buf, 2)
        qdcount = read_u16(buf, 4).to_i
        ancount = read_u16(buf, 6).to_i

        offset = HEADER_SIZE
        qdcount.times do
          offset += read_name(buf, offset)[1] + 4 # name + QTYPE + QCLASS
          raise MalformedMessage.new("question section overruns message") if offset > buf.size
        end

        answers = [] of Record
        ancount.times do
          record, offset = read_record(buf, offset)
          answers << record
        end

        Message.new(id, flags, answers)
      end

      # Decodes a (possibly compressed) domain name starting at `start`,
      # returning the DNS-escaped dotted name and bytes consumed in the sequential
      # stream at `start` (a compression pointer ends that read after its two
      # bytes). Pointer chases are counted and capped so a loop is rejected, and
      # the assembled name is capped at MAX_NAME octets.
      def self.read_name(buf : Bytes, start : Int32) : {String, Int32}
        labels = [] of String
        offset = start
        consumed = 0
        jumped = false
        jumps = 0
        total = 0

        loop do
          len = label_length(buf, offset)
          if (len & 0xC0) == 0xC0
            jumps += 1
            offset = follow_pointer(buf, offset, jumps)
            consumed += 2 unless jumped
            jumped = true
          elsif len.zero?
            consumed += 1 unless jumped
            break
          else
            offset, total = append_label(buf, offset, len, labels, total)
            consumed += len + 1 unless jumped
          end
        end

        {labels.join("."), consumed}
      end

      private def self.label_length(buf : Bytes, offset : Int32) : Int32
        raise MalformedMessage.new("name offset out of range") if offset < 0 || offset >= buf.size
        buf[offset].to_i
      end

      private def self.follow_pointer(buf : Bytes, offset : Int32, jumps : Int32) : Int32
        raise MalformedMessage.new("truncated compression pointer") if offset + 1 >= buf.size
        raise MalformedMessage.new("compression pointer loop") if jumps > MAX_POINTER_JUMPS
        ((buf[offset].to_i & 0x3F) << 8) | buf[offset + 1].to_i
      end

      private def self.append_label(buf : Bytes, offset : Int32, len : Int32, labels : Array(String), total : Int32) : {Int32, Int32}
        raise MalformedMessage.new("reserved label type") if (len & 0xC0) != 0

        label_start = offset + 1
        raise MalformedMessage.new("label overruns message") if label_start + len > buf.size
        total += len + 1
        raise MalformedMessage.new("name exceeds 255 octets") if total > MAX_NAME
        labels << present_label(buf[label_start, len])
        {label_start + len, total}
      end

      # Escape wire octets, not Unicode characters, matching dnsruby Name.decode
      private def self.present_label(bytes : Bytes) : String
        String.build do |io|
          bytes.each do |byte|
            if byte < 33 || byte > 126
              io << '\\' << (byte // 100) << ((byte // 10) % 10) << (byte % 10)
            else
              case byte
              when 34, 36, 40, 41, 59, 64, 92, 46
                io << '\\'
              end
              io.write_byte(byte)
            end
          end
        end
      end

      private def self.read_record(buf : Bytes, offset : Int32) : {Record, Int32}
        pos = offset + read_name(buf, offset)[1] # skip the owner name
        raise MalformedMessage.new("record header overruns message") if pos + 10 > buf.size
        type = read_u16(buf, pos)
        # pos+2 class and pos+4..7 ttl are skipped: the output renders neither.
        rdlength = read_u16(buf, pos + 8).to_i
        rdata_offset = pos + 10
        raise MalformedMessage.new("rdata overruns message") if rdata_offset + rdlength > buf.size
        rdata = buf[rdata_offset, rdlength]
        {Record.new(type, rdata, buf, rdata_offset), rdata_offset + rdlength}
      end

      private def self.encode_name(io : IO, name : String) : Nil
        name.split('.') do |label|
          next if label.empty?

          bytes = label.to_slice
          raise MalformedMessage.new("label exceeds 63 octets") if bytes.size > MAX_LABEL
          io.write_byte(bytes.size.to_u8)
          io.write(bytes)
        end
        io.write_byte(0_u8)
      end

      private def self.write_u16(io : IO, value : UInt16) : Nil
        io.write_byte((value >> 8).to_u8!)
        io.write_byte((value & 0xFF).to_u8!)
      end

      private def self.read_u16(buf : Bytes, offset : Int32) : UInt16
        raise MalformedMessage.new("u16 read out of range") if offset < 0 || offset + 2 > buf.size
        (buf[offset].to_u16 << 8) | buf[offset + 1].to_u16
      end
    end
  end
end
