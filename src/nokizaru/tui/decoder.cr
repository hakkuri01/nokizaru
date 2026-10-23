require "./messages"

module Nokizaru
  module Tui
    # Turns raw terminal input bytes into key messages, holding a sequence that
    # arrived split across reads until the rest shows up (or a quiet gap proves it
    # was a lone Esc). Byte-oriented: a UTF-8 character or an escape sequence can
    # straddle two reads, so decoding advances only over complete units.
    class Decoder
      ESC                =   27_u8
      CSI                = 0x5B_u8 # '['
      SS3                = 0x4F_u8 # 'O'
      DEL                =  127_u8
      MAX_SEQUENCE_BYTES =      32

      CONTROL_KEYS = {
        3_u8 => "ctrl+c", 4_u8 => "ctrl+d", 21_u8 => "ctrl+u", 9_u8 => "tab",
        13_u8 => "enter", 10_u8 => "enter", 127_u8 => "backspace", 8_u8 => "backspace",
      }
      CSI_KEYS = {
        "A" => "up", "B" => "down", "C" => "right", "D" => "left",
        "H" => "home", "F" => "end", "Z" => "shift+tab",
      }
      TILDE_KEYS = {
        "1" => "home", "7" => "home", "4" => "end", "8" => "end",
        "5" => "pgup", "6" => "pgdn", "3" => "delete",
      }

      def initialize
        @buffer = Bytes.new(0)
      end

      def pending? : Bool
        !@buffer.empty?
      end

      def feed(bytes : Bytes) : Array(Messages::Key)
        @buffer = append(@buffer, bytes)
        messages = [] of Messages::Key
        offset = 0
        while offset < @buffer.size
          message, used = decode_at(offset)
          break if used.zero?

          messages << message if message
          offset += used
        end
        @buffer = @buffer[offset, @buffer.size - offset]
        messages
      end

      # A lone ESC is only known after a quiet gap; anything else still pending is
      # a broken sequence and is dropped.
      def flush : Array(Messages::Key)
        lone = @buffer.size == 1 && @buffer[0] == ESC
        @buffer = Bytes.new(0)
        lone ? [key("esc")] : [] of Messages::Key
      end

      private def append(head : Bytes, tail : Bytes) : Bytes
        combined = Bytes.new(head.size + tail.size)
        head.copy_to(combined[0, head.size]) unless head.empty?
        tail.copy_to(combined[head.size, tail.size]) unless tail.empty?
        combined
      end

      private def decode_at(offset : Int32) : Tuple(Messages::Key?, Int32)
        byte = @buffer[offset]
        return escape_at(offset) if byte == ESC
        return {key(control_name(byte)), 1} if byte < 32 || byte == DEL

        char_at(offset)
      end

      private def control_name(byte : UInt8) : String
        CONTROL_KEYS[byte]? || "ctrl+#{(byte.to_i32 + 96).chr}"
      end

      # ESC opens a CSI or SS3 key sequence; before anything else it is a key of
      # its own (nothing binds Alt), so a fast "Esc j" in INSERT leaves INSERT and
      # then moves, as in vim.
      private def escape_at(offset : Int32) : Tuple(Messages::Key?, Int32)
        introducer = @buffer[offset + 1]?
        return {nil, 0} if introducer.nil?
        return csi_at(offset) if introducer == CSI
        return ss3_at(offset) if introducer == SS3

        {key("esc"), 1}
      end

      private def csi_at(offset : Int32) : Tuple(Messages::Key?, Int32)
        final_at = final_byte_at(offset + 2)
        return {nil, incomplete(offset)} if final_at.nil?

        params = slice_text(offset + 2, final_at - offset - 2)
        final = slice_text(final_at, 1)
        {csi_message(params, final), final_at - offset + 1}
      end

      # Scans for the first final byte (0x40..0x7E) that closes a CSI sequence.
      private def final_byte_at(from : Int32) : Int32?
        index = from
        while index < @buffer.size
          byte = @buffer[index]
          return index if byte >= 0x40 && byte <= 0x7E

          index += 1
        end
        nil
      end

      # Waits for the rest of a sequence, but drops one that grows past any real
      # key sequence.
      private def incomplete(offset : Int32) : Int32
        remaining = @buffer.size - offset
        remaining > MAX_SEQUENCE_BYTES ? remaining : 0
      end

      private def csi_message(params : String, final : String) : Messages::Key?
        head = params.split(';').first? || ""
        if final == "~"
          name = TILDE_KEYS[head]?
          return name ? key(name) : nil
        end
        name = CSI_KEYS[final]?
        name ? key(name) : nil
      end

      private def ss3_at(offset : Int32) : Tuple(Messages::Key?, Int32)
        byte = @buffer[offset + 2]?
        return {nil, 0} if byte.nil?

        name = CSI_KEYS[byte.unsafe_chr.to_s]?
        {name ? key(name) : nil, 3}
      end

      private def char_at(offset : Int32) : Tuple(Messages::Key?, Int32)
        length = utf8_length(@buffer[offset])
        return {nil, 0} if offset + length > @buffer.size

        char = String.new(@buffer[offset, length])
        {char.valid_encoding? ? key(char) : nil, length}
      end

      private def utf8_length(lead : UInt8) : Int32
        return 2 if lead >= 0xC0 && lead <= 0xDF
        return 3 if lead >= 0xE0 && lead <= 0xEF
        return 4 if lead >= 0xF0 && lead <= 0xF7

        1
      end

      private def slice_text(start : Int32, length : Int32) : String
        String.new(@buffer[start, length])
      end

      private def key(name : String) : Messages::Key
        Messages::Key.new(name)
      end
    end
  end
end
