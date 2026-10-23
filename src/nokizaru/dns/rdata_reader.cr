require "./message"

module Nokizaru
  module Dns
    # A sequential, bounds-checked cursor over one record's RDATA. Every read is
    # confined to the [start, start + length) rdata window, so a short or
    # oversized rdata raises MalformedMessage rather than reading into the next
    # record; the one exception is a domain name, which may legally use a
    # compression pointer into the rest of the message (read via the message's
    # loop-safe decoder) but whose sequential bytes must still fit the window.
    # A class, not a struct, so the cursor position survives being passed to a
    # formatter helper.
    class RdataReader
      def initialize(@message : Bytes, @start : Int32, @length : Int32)
        @pos = @start
      end

      def remaining : Int32
        @start + @length - @pos
      end

      def u8 : UInt8
        require!(1)
        value = @message[@pos]
        @pos += 1
        value
      end

      def u16 : UInt16
        require!(2)
        value = (@message[@pos].to_u16 << 8) | @message[@pos + 1].to_u16
        @pos += 2
        value
      end

      def u32 : UInt32
        require!(4)
        value = (@message[@pos].to_u32 << 24) | (@message[@pos + 1].to_u32 << 16) |
                (@message[@pos + 2].to_u32 << 8) | @message[@pos + 3].to_u32
        @pos += 4
        value
      end

      def take(count : Int32) : Bytes
        require!(count)
        slice = @message[@pos, count]
        @pos += count
        slice
      end

      def rest : Bytes
        take(remaining)
      end

      # A length-prefixed <character-string> (RFC 1035 §3.3): a one-byte length
      # then that many octets.
      def char_string : String
        String.new(take(u8.to_i))
      end

      # A domain name. It may compress via a pointer into the message, so decode
      # against the whole buffer; the sequential bytes it consumes must stay
      # inside the rdata window.
      def name : String
        decoded, consumed = Message.read_name(@message, @pos)
        raise MalformedMessage.new("name overruns rdata") if consumed > remaining
        @pos += consumed
        decoded
      end

      private def require!(count : Int32) : Nil
        raise MalformedMessage.new("rdata read out of range") if count < 0 || count > remaining
      end
    end
  end
end
