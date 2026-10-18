# frozen_string_literal: true

module Nokizaru
  module TUI
    # Turns raw terminal input bytes into key messages, holding a sequence split across reads
    class Decoder
      ESC = 27
      MAX_SEQUENCE_BYTES = 32
      CONTROL_KEYS = { 3 => 'ctrl+c', 4 => 'ctrl+d', 21 => 'ctrl+u', 9 => 'tab', 13 => 'enter', 10 => 'enter',
                       127 => 'backspace', 8 => 'backspace' }.freeze
      CSI_KEYS = { 'A' => 'up', 'B' => 'down', 'C' => 'right', 'D' => 'left', 'H' => 'home', 'F' => 'end',
                   'Z' => 'shift+tab' }.freeze
      TILDE_KEYS = { '1' => 'home', '7' => 'home', '4' => 'end', '8' => 'end', '5' => 'pgup', '6' => 'pgdn',
                     '3' => 'delete' }.freeze

      def initialize
        @buffer = +''.b
      end

      def pending?
        !@buffer.empty?
      end

      def feed(bytes)
        @buffer << bytes.b
        messages = []
        offset = 0
        while offset < @buffer.bytesize
          message, used = decode_at(offset)
          break if used.zero?

          messages << message if message
          offset += used
        end
        @buffer = @buffer.byteslice(offset..)
        messages
      end

      # A lone ESC is only known after a quiet gap; anything else still pending is a broken sequence
      def flush
        lone = @buffer == "\e"
        @buffer = +''.b
        lone ? [key('esc')] : []
      end

      private

      def decode_at(offset)
        byte = @buffer.getbyte(offset)
        return escape_at(offset) if byte == ESC
        return [key(control_name(byte)), 1] if byte < 32 || byte == 127

        char_at(offset)
      end

      def control_name(byte)
        CONTROL_KEYS.fetch(byte) { "ctrl+#{(byte + 96).chr}" }
      end

      # ESC opens a CSI or SS3 key sequence; before anything else it is a key of its own (nothing binds Alt), so a
      # fast "Esc j" in INSERT leaves INSERT and then moves, as in vim
      def escape_at(offset)
        introducer = @buffer.getbyte(offset + 1)
        return [nil, 0] if introducer.nil?
        return csi_at(offset) if introducer == '['.ord
        return ss3_at(offset) if introducer == 'O'.ord

        [key('esc'), 1]
      end

      def csi_at(offset)
        final_at = ((offset + 2)...@buffer.bytesize).find { |index| @buffer.getbyte(index).between?(0x40, 0x7E) }
        return [nil, incomplete(offset)] if final_at.nil?

        params = @buffer.byteslice(offset + 2, final_at - offset - 2)
        final = @buffer.byteslice(final_at, 1)
        [csi_message(params, final), final_at - offset + 1]
      end

      # Waits for the rest of a sequence, but drops one that grows past any real key sequence
      def incomplete(offset)
        @buffer.bytesize - offset > MAX_SEQUENCE_BYTES ? @buffer.bytesize - offset : 0
      end

      def csi_message(params, final)
        return key(TILDE_KEYS[params.split(';').first]) if final == '~' && TILDE_KEYS.key?(params.split(';').first)

        CSI_KEYS.key?(final) ? key(CSI_KEYS[final]) : nil
      end

      def ss3_at(offset)
        final = @buffer.byteslice(offset + 2, 1)
        return [nil, 0] if final.nil? || final.empty?

        [CSI_KEYS.key?(final) ? key(CSI_KEYS[final]) : nil, 3]
      end

      def char_at(offset)
        length = utf8_length(@buffer.getbyte(offset))
        return [nil, 0] if offset + length > @buffer.bytesize

        char = @buffer.byteslice(offset, length).force_encoding(Encoding::UTF_8)
        [char.valid_encoding? ? key(char) : nil, length]
      end

      def utf8_length(lead)
        return 2 if lead.between?(0xC0, 0xDF)
        return 3 if lead.between?(0xE0, 0xEF)
        return 4 if lead.between?(0xF0, 0xF7)

        1
      end

      def key(name)
        Messages::Key.new(name: name)
      end
    end
  end
end
